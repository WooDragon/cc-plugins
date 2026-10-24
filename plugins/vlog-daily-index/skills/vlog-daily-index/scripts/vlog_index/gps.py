"""Read-only FIT ingestion and conservative WGS84 time association.

FIT parsing belongs to Garmin's SDK; stops and interpolation belong to
MovingPandas. This module supplies source provenance and safety boundaries.
"""
from __future__ import annotations

from bisect import bisect_left
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone as dt_timezone
from hashlib import sha256
from importlib.metadata import version
import json
import math
from pathlib import Path
import statistics
from zoneinfo import ZoneInfo

UTC = dt_timezone.utc
MAX_GAP_SECONDS = 120
STOP_DIAMETER_METERS = 100
STOP_DURATION_SECONDS = 120
MAX_PLAUSIBLE_SPEED_MPS = 100


def _utc(value):
    if isinstance(value, str):
        value = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("A timezone-aware timestamp is required")
    return value.astimezone(UTC)


def _iso(value):
    return _utc(value).isoformat().replace("+00:00", "Z")


def _valid_coordinates(latitude, longitude):
    return (isinstance(latitude, (int, float)) and not isinstance(latitude, bool)
            and isinstance(longitude, (int, float)) and not isinstance(longitude, bool)
            and math.isfinite(latitude) and math.isfinite(longitude)
            and -90 <= latitude <= 90 and -180 <= longitude <= 180)


def _distance(a, b):
    from geopy.distance import geodesic
    return geodesic((a["latitude"], a["longitude"]),
                    (b["latitude"], b["longitude"])).meters


def _trajectory(points, trajectory_id):
    import pandas as pd
    import movingpandas as mpd
    # MovingPandas normalizes its index to UTC-naive internally. Supply a
    # UTC-naive adapter explicitly, and restore UTC on every exported value.
    rows = [{"t": _utc(p["timestamp_utc"]).replace(tzinfo=None),
             "x": p["longitude"], "y": p["latitude"]} for p in points]
    return mpd.Trajectory(pd.DataFrame(rows), trajectory_id, t="t", x="x", y="y", crs="EPSG:4326")


def _mpd_utc(value):
    value = value.to_pydatetime() if hasattr(value, "to_pydatetime") else value
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def _decode_fit(path, display_timezone):
    from garmin_fit_sdk import Decoder, Stream, Profile
    source = {"path": str(path.resolve()), "name": path.name,
              "status": "error",
              "integrity_ok": False, "decode_errors": [], "record_count": 0}
    points, issues = [], []
    try:
        before = path.stat()
        payload = bytearray(path.read_bytes())
        source.update(size_bytes=before.st_size, mtime_ns=before.st_mtime_ns,
                      sha256=sha256(payload).hexdigest())
        source["integrity_ok"] = bool(Decoder(Stream.from_byte_array(payload)).check_integrity())
        messages, errors = Decoder(Stream.from_byte_array(payload)).read(enable_crc_check=True)
        source["decode_errors"] = [str(e) for e in errors]
        records = messages.get("record_mesgs", [])
        source["record_count"] = len(records)
        if not source["integrity_ok"] or errors:
            source["decode_errors"] += ([] if source["integrity_ok"] else ["FIT integrity/CRC check failed"])
            return points, source, issues
        fields = Profile["messages"][20]["fields"]
        if fields[0]["units"] != "semicircles" or fields[1]["units"] != "semicircles":
            raise ValueError("Unexpected official FIT position units")
        times = []
        for index, record in enumerate(records):
            try:
                timestamp = _utc(record.get("timestamp"))
                times.append(timestamp)
            except (TypeError, ValueError):
                issues.append({"record_index": index, "reason": "missing_or_unknown_time"})
                continue
            raw_lat, raw_lon = record.get("position_lat"), record.get("position_long")
            if not isinstance(raw_lat, (int, float)) or not isinstance(raw_lon, (int, float)):
                issues.append({"record_index": index, "timestamp_utc": _iso(timestamp), "reason": "missing_coordinates"})
                continue
            latitude, longitude = raw_lat * 180 / 2**31, raw_lon * 180 / 2**31
            if raw_lat == 0x7FFFFFFF or raw_lon == 0x7FFFFFFF or not _valid_coordinates(latitude, longitude):
                issues.append({"record_index": index, "timestamp_utc": _iso(timestamp), "reason": "invalid_coordinates"})
                continue
            point = {"timestamp_utc": _iso(timestamp), "latitude": latitude,
                     "longitude": longitude, "crs": "EPSG:4326", "source": "garmin_fit",
                     "source_file": str(path.resolve()), "record_index": index,
                     "raw_position_lat": raw_lat, "raw_position_long": raw_lon,
                     "raw_position_units": "semicircles"}
            for field in ("enhanced_altitude", "enhanced_speed", "gps_accuracy"):
                value = record.get(field)
                if isinstance(value, (int, float)) and math.isfinite(value):
                    point[field] = value
            points.append(point)
        source["timestamp_start_utc"] = _iso(min(times)) if times else None
        source["timestamp_end_utc"] = _iso(max(times)) if times else None
        source["record_dates_local"] = dict(sorted(Counter(t.astimezone(display_timezone).date().isoformat() for t in times).items()))
        source["valid_coordinate_count"] = len(points)
        source["valid_coordinate_dates_local"] = dict(sorted(Counter(
            _utc(p["timestamp_utc"]).astimezone(display_timezone).date().isoformat() for p in points).items()))
        source["issue_counts"] = dict(Counter(issue["reason"] for issue in issues))
        after = path.stat()
        source["unchanged"] = before.st_size == after.st_size and before.st_mtime_ns == after.st_mtime_ns
        if not source["unchanged"]:
            source["decode_errors"].append("Source changed while decoding")
            return [], source, issues
        source["status"] = "ok"
    except Exception as error:
        source["decode_errors"].append(f"{type(error).__name__}: {error}")
        points = []
    return points, source, issues


def _segment_source(points, source_name, max_gap_seconds=MAX_GAP_SECONDS):
    """Quality rejection and segment boundaries, not a stop detector."""
    by_time = defaultdict(list)
    for point in points:
        by_time[point["timestamp_utc"]].append(point)
    unique, issues, blocked = [], [], []
    for timestamp, group in sorted(by_time.items(), key=lambda item: _utc(item[0])):
        coordinates = {(p["latitude"], p["longitude"]) for p in group}
        if len(coordinates) > 1:
            blocked.append(_utc(timestamp))
            issues.append({"timestamp_utc": timestamp, "reason": "conflicting_duplicate_timestamp", "count": len(group)})
        else:
            unique.append(group[0])
            if len(group) > 1:
                issues.append({"timestamp_utc": timestamp, "reason": "identical_duplicate_timestamp", "count": len(group)-1})
    segments, gaps, current = [], [], []
    for point in unique:
        if current:
            previous = current[-1]
            left, right = _utc(previous["timestamp_utc"]), _utc(point["timestamp_utc"])
            seconds = (right-left).total_seconds()
            if seconds <= max_gap_seconds and _distance(previous, point)/seconds > MAX_PLAUSIBLE_SPEED_MPS:
                issues.append({"timestamp_utc": point["timestamp_utc"], "reason": "implausible_speed_rejected",
                               "record_index": point.get("record_index")})
                blocked.append(right)
                continue
            reason = "sampling_gap" if seconds > max_gap_seconds else (
                "quality_rejection" if any(left < t < right for t in blocked) else None)
            if reason:
                gaps.append({"start_utc": _iso(left), "end_utc": _iso(right),
                             "duration_seconds": seconds, "source_file": source_name, "reason": reason})
                segments.append(current)
                current = []
        current.append(point)
    if current:
        segments.append(current)
    for number, segment in enumerate(segments):
        segment_id = f"{source_name}:{number}"
        for point in segment:
            point["segment_id"] = segment_id
    return segments, gaps, issues


def _stops_for_segments(segments):
    import movingpandas as mpd
    stops = []
    for segment in segments:
        if len(segment) < 2:
            continue
        trajectory = _trajectory(segment, segment[0]["segment_id"])
        detected = mpd.TrajectoryStopDetector(trajectory).get_stop_points(
            max_diameter=STOP_DIAMETER_METERS,
            min_duration=timedelta(seconds=STOP_DURATION_SECONDS))
        for stop_id, row in detected.iterrows():
            start, end = _mpd_utc(row["start_time"]), _mpd_utc(row["end_time"])
            stops.append({"stop_id": str(stop_id), "start_utc": _iso(start), "end_utc": _iso(end),
                          "duration_seconds": (end-start).total_seconds(),
                          "latitude": float(row.geometry.y), "longitude": float(row.geometry.x),
                          "source": "garmin_fit", "source_file": segment[0]["source_file"],
                          "segment_id": segment[0]["segment_id"], "crs": "EPSG:4326",
                          "meaning": "spatial_stop_only_purpose_unknown"})
    return stops


def build_gps(fit_dir: str, output_path: str, timezone="Asia/Shanghai", date=None) -> dict:
    """Decode every FIT; optionally select points by trusted local record date.

    Corrupt files are explicitly reported and contribute no positioning data.
    The output must be outside the read-only FIT source tree.
    """
    source_dir, output = Path(fit_dir).resolve(), Path(output_path).resolve()
    if not source_dir.is_dir():
        raise FileNotFoundError(f"FIT source directory unavailable: {source_dir}")
    if output == source_dir or source_dir in output.parents:
        raise ValueError("GPS output must be outside the read-only FIT source tree")
    display_timezone = ZoneInfo(timezone)
    selected_date = datetime.strptime(str(date), "%Y-%m-%d").date() if date else None
    files = sorted(p for p in source_dir.iterdir() if p.is_file() and p.suffix.lower() == ".fit")
    segments, gaps, sources, issues = [], [], [], []
    for path in files:
        points, source, source_issues = _decode_fit(path, display_timezone)
        for issue in source_issues:
            if not selected_date or not issue.get("timestamp_utc") or _utc(issue["timestamp_utc"]).astimezone(display_timezone).date() == selected_date:
                issues.append({"source_file": str(path.resolve()), **issue})
        if selected_date:
            points = [p for p in points if _utc(p["timestamp_utc"]).astimezone(display_timezone).date() == selected_date]
        parts, source_gaps, source_issues = _segment_source(points, str(path.resolve()))
        source["selected_point_count"] = sum(map(len, parts))
        sources.append(source)
        segments.extend(parts)
        gaps.extend(source_gaps)
        issues.extend({"source_file": str(path.resolve()), **issue} for issue in source_issues)
    points = sorted((p for part in segments for p in part), key=lambda p: (_utc(p["timestamp_utc"]), p["source_file"]))
    stops = _stops_for_segments(segments)
    intervals = [( _utc(part[i]["timestamp_utc"])-_utc(part[i-1]["timestamp_utc"])).total_seconds()
                 for part in segments for i in range(1, len(part))]
    result = {"schema_version": 1, "timezone": timezone, "date": str(date) if date else None,
              "crs": "EPSG:4326", "coordinate_meaning": "garmin_recorder_position_not_visible_subject",
              "parameters": {"max_gap_seconds": MAX_GAP_SECONDS, "stop_diameter_meters": STOP_DIAMETER_METERS,
                             "stop_duration_seconds": STOP_DURATION_SECONDS,
                             "max_plausible_speed_mps": MAX_PLAUSIBLE_SPEED_MPS},
              "versions": {package: version(package) for package in ("garmin-fit-sdk", "movingpandas", "geopandas", "pandas", "shapely")},
              "points": points, "stops": stops, "gaps": gaps, "sources": sources,
              "quality": {"status": "ok" if files and not gaps and not issues and all(s["status"] == "ok" for s in sources) else "partial",
                          "decode_status": "ok" if files and all(s["status"] == "ok" for s in sources) else "partial",
                          "fit_file_count": len(files), "decoded_file_count": sum(s["status"] == "ok" for s in sources),
                          "point_count": len(points), "stop_count": len(stops), "segment_count": len(segments),
                          "sampling_median_seconds": statistics.median(intervals) if intervals else None,
                          "sampling_max_seconds_within_segments": max(intervals) if intervals else None,
                          "coverage_start_utc": points[0]["timestamp_utc"] if points else None,
                          "coverage_end_utc": points[-1]["timestamp_utc"] if points else None,
                          "interpolation_eligible_seconds": sum(intervals),
                          "coverage_windows": [{"start_utc": part[0]["timestamp_utc"], "end_utc": part[-1]["timestamp_utc"],
                                                "point_count": len(part), "segment_id": part[0]["segment_id"]} for part in segments],
                          "issue_counts": dict(Counter(issue["reason"] for issue in issues)),
                          "issues": issues}}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
    return result


def locate(gps_data: dict, timestamp_utc: str, max_gap_seconds=120) -> dict | None:
    """Locate a verified capture timestamp; never extrapolate or cross a gap."""
    if max_gap_seconds <= 0 or max_gap_seconds > MAX_GAP_SECONDS:
        raise ValueError("max_gap_seconds must be >0 and <=120")
    target = _utc(timestamp_utc)
    by_segment = defaultdict(list)
    for point in gps_data.get("points", []):
        if _valid_coordinates(point.get("latitude"), point.get("longitude")):
            # Source grouping also prevents interpolation across separate FITs.
            key = (point.get("source_file"), point.get("segment_id", point.get("source_file", "default")))
            by_segment[key].append(point)
    candidates = []
    for segment in by_segment.values():
        segment = sorted(segment, key=lambda p: _utc(p["timestamp_utc"]))
        times = [_utc(p["timestamp_utc"]) for p in segment]
        index = bisect_left(times, target)
        if index < len(times) and times[index] == target:
            point, precision, span = segment[index], "recorded_sample", 0.0
            latitude, longitude = point["latitude"], point["longitude"]
        elif index == 0 or index == len(times):
            continue
        else:
            left, right = segment[index-1], segment[index]
            span = (times[index]-times[index-1]).total_seconds()
            if span > max_gap_seconds:
                continue
            if any(_utc(g["start_utc"]) < target < _utc(g["end_utc"])
                   and g.get("source_file") in (None, left.get("source_file")) for g in gps_data.get("gaps", [])):
                continue
            geometry = _trajectory([left, right], "query").get_position_at(target.replace(tzinfo=None))
            latitude, longitude = float(geometry.y), float(geometry.x)
            point, precision = left, "interpolated_estimate"
        candidates.append({"latitude": latitude, "longitude": longitude,
                           "timestamp_utc": _iso(target), "source": "garmin_fit",
                           "source_file": point.get("source_file"), "precision": precision,
                           "bracket_seconds": span, "crs": "EPSG:4326",
                           "coordinate_meaning": "garmin_recorder_position_not_visible_subject"})
    if not candidates or any(_distance(candidates[0], c) > STOP_DIAMETER_METERS for c in candidates[1:]):
        return None
    return min(candidates, key=lambda p: p["bracket_seconds"])


def locate_media(gps_data, timestamp_utc=None, *, time_mapping_verified=False,
                 playback_rate_verified=False, device_with_garmin=False,
                 drone_srt_points=None, video_seconds=None):
    """Source priority and explicit capture-time gates for media callers.

    drone_srt_points use trusted SRT-relative video_seconds, so the drone's own
    position stays separate from Garmin and needs no guessed UTC mapping.
    """
    if drone_srt_points is not None:
        if video_seconds is None:
            return None
        # Use the containing subtitle interval; no guessed interpolation or
        # nearest-neighbour extrapolation outside the recorded cue interval.
        matches = [p for p in drone_srt_points
                   if p.get("trusted") is True and p.get("crs") == "EPSG:4326"
                   and p["start_seconds"] <= video_seconds < p["end_seconds"]
                   and not (p.get("latitude") == 0 and p.get("longitude") == 0)
                   and _valid_coordinates(p.get("latitude"), p.get("longitude"))]
        if len(matches) != 1:
            return None
        point = matches[0]
        return {"latitude": point["latitude"], "longitude": point["longitude"],
                "source": "drone_srt", "precision": "subtitle_interval", "crs": "EPSG:4326",
                "coordinate_meaning": "drone_camera_position_not_visible_subject",
                "source_file": point.get("source_file"), "video_seconds": video_seconds}
    if not (time_mapping_verified and playback_rate_verified and device_with_garmin and timestamp_utc):
        return None
    return locate(gps_data, timestamp_utc)
