"""GPS boundaries using invented dates/coordinates and Garmin's synthetic FIT encoder."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from vlog_index.gps import build_gps, locate, locate_media, _segment_source, _stops_for_segments

BASE = datetime(2030, 1, 1, 16, tzinfo=timezone.utc)


def point(seconds, latitude=1.0, longitude=2.0):
    return {"timestamp_utc": (BASE + timedelta(seconds=seconds)).isoformat(),
            "latitude": latitude, "longitude": longitude, "source_file": "test.fit",
            "segment_id": "test:0"}


class GPSBoundaries(unittest.TestCase):
    def test_srt_zero_zero_placeholder_is_rejected_but_single_zero_coordinate_is_valid(self):
        base = {'start_seconds': 0, 'end_seconds': 1, 'trusted': True, 'crs': 'EPSG:4326'}
        self.assertIsNone(locate_media({}, drone_srt_points=[{**base, 'latitude': 0, 'longitude': 0}], video_seconds=0.5))
        self.assertIsNotNone(locate_media({}, drone_srt_points=[{**base, 'latitude': 0, 'longitude': 2}], video_seconds=0.5))
        self.assertIsNotNone(locate_media({}, drone_srt_points=[{**base, 'latitude': 1, 'longitude': 0}], video_seconds=0.5))
        # The DJI placeholder rule does not invalidate a genuine Garmin sample at the origin.
        self.assertIsNotNone(locate({'points': [point(0, latitude=0, longitude=0)]}, point(0)['timestamp_utc']))
        from vlog_index import media
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / 'camera.mp4'; source.touch()
            source.with_suffix('.srt').write_text(
                '1\n00:00:00,000 --> 00:00:01,000\n[latitude: 0] [longitude: 0]\n\n'
                '2\n00:00:01,000 --> 00:00:02,000\n[latitude: 1] [longitude: 2]\n', encoding='utf-8')
            points = media.metadata(source)['location_points']
            self.assertEqual(len(points), 1)
            self.assertEqual(points[0]['latitude'], 1)

    def test_120_second_limit_and_no_extrapolation(self):
        data = {"points": [point(0), point(120, longitude=2.001), point(241)]}
        found = locate(data, point(60)["timestamp_utc"])
        self.assertAlmostEqual(found["longitude"], 2.0005)
        self.assertEqual(found["precision"], "interpolated_estimate")
        self.assertIsNone(locate(data, point(180)["timestamp_utc"]))
        self.assertIsNone(locate(data, point(-1)["timestamp_utc"]))

    def test_stop_detection_never_bridges_a_gap(self):
        parts, gaps, _ = _segment_source([point(0), point(60), point(120), point(300), point(360)], "test.fit")
        stops = _stops_for_segments(parts)
        self.assertEqual(len(stops), 1)
        self.assertEqual(stops[0]["duration_seconds"], 120)
        self.assertEqual(len(gaps), 1)
        self.assertEqual(gaps[0]["duration_seconds"], 180)

    def test_uncertain_capture_time_and_drone_source_priority(self):
        data = {"points": [point(0), point(60)]}
        self.assertIsNone(locate_media(data, point(30)["timestamp_utc"]))
        self.assertIsNone(locate_media(data, point(30)["timestamp_utc"],
                                      time_mapping_verified=True, device_with_garmin=True))
        self.assertIsNotNone(locate_media(data, point(30)["timestamp_utc"],
                                          time_mapping_verified=True, playback_rate_verified=True,
                                          device_with_garmin=True))
        cue = {"start_seconds": 0, "end_seconds": 1, "latitude": 3, "longitude": 4,
               "trusted": True, "crs": "EPSG:4326"}
        found = locate_media(data, drone_srt_points=[cue], video_seconds=0.5)
        self.assertEqual(found["source"], "drone_srt")
        self.assertEqual(found["latitude"], 3)
        self.assertIsNone(locate_media(data, drone_srt_points=[cue], video_seconds=2))

    def test_official_sdk_date_filter_crc_and_source_unchanged(self):
        from garmin_fit_sdk import Encoder, Profile
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "source"
            source.mkdir()
            encoder = Encoder()
            encoder.on_mesg(Profile["mesg_num"]["FILE_ID"], {"manufacturer": "development", "product": 1,
                            "time_created": BASE, "type": "activity"})
            for seconds in (-1, 0, 60, 120):
                encoder.on_mesg(Profile["mesg_num"]["RECORD"], {
                    "timestamp": BASE + timedelta(seconds=seconds),
                    "position_lat": round(1 * 2**31 / 180),
                    "position_long": round(2 * 2**31 / 180)})
            fit = source / "arbitrary-name.fit"
            fit.write_bytes(encoder.close())
            before = fit.read_bytes(), fit.stat().st_mtime_ns
            from test_fixed_workflow import invoke
            from vlog_index.store import read
            invoke('gps-build', '--state', root / 'state', '--fit-dir', source,
                   '--output', root / 'gps.json', '--date', '2030-01-02', '--timezone', 'Asia/Shanghai')
            result = read(root / 'gps.json')
            self.assertEqual(result["quality"]["point_count"], 3)
            self.assertTrue(result["sources"][0]["integrity_ok"])
            self.assertEqual((fit.read_bytes(), fit.stat().st_mtime_ns), before)
            (source / "broken.fit").write_bytes(b"not a FIT file")
            result = build_gps(str(source), str(root / "partial.json"), date="2030-01-02")
            self.assertEqual(result["quality"]["decoded_file_count"], 1)
            self.assertEqual(result["quality"]["decode_status"], "partial")
            self.assertTrue(next(s for s in result["sources"] if s["name"] == "broken.fit")["decode_errors"])


if __name__ == "__main__":
    unittest.main()
