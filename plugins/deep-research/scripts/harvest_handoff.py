"""Harvest handoff: closed-schema WIP → compact manifest + evidence ledger.

stdlib-only. Does not import harvest. Callers pass already-loaded structures.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path
from typing import Any, Iterable, Mapping


class HandoffError(ValueError):
    """Closed-schema / coverage / publish failure with a stable message."""


SCHEMA_WIP = "harvest-handoff-wip"
SCHEMA_MANIFEST = "harvest-handoff-manifest"
HANDOFF_VERSION = 1
EXCERPT_VERIFICATION = "url_fetched_only"

WIP_TOP_KEYS = frozenset({
    "schema",
    "handoff_version",
    "clusters",
    "coverage_gaps",
    "blind_spots",
    "contradictions",
    "unique_insights",
    "unclustered_claim_ids",
    "unclustered_claims",
})
WIP_CLUSTER_KEYS = frozenset({"cluster_id", "summary", "relation", "claims"})
CLAIM_KEYS = frozenset({
    "id", "claim", "excerpt", "url", "language", "credibility", "source_model",
})
MANIFEST_TOP_KEYS = frozenset({
    "schema",
    "handoff_version",
    "goal_file_sha256",
    "raw_merged_sha256",
    "evidence_sha256",
    "alive_models",
    "claim_count",
    "cluster_count",
    "clusters",
    "coverage_gaps",
    "blind_spots",
    "contradictions",
    "unique_insight_ids",
    "unclustered_claim_ids",
})
MANIFEST_CLUSTER_KEYS = frozenset({
    "cluster_id",
    "summary",
    "relation",
    "supporting_models",
    "consensus",
    "presentation",
    "expansion_reasons",
    "representative_claim_id",
    "claim_ids",
    "evidence_offset",
    "evidence_limit",
})
EVIDENCE_KEYS = frozenset({
    "cluster_id",
    "id",
    "claim",
    "excerpt",
    "url",
    "language",
    "credibility",
    "source_model",
    "excerpt_verification",
})
REQUIRED_WIP_LISTS = (
    "coverage_gaps",
    "blind_spots",
    "contradictions",
    "unique_insights",
    "unclustered_claim_ids",
)


def canonical_dumps(obj: Any) -> str:
    """UTF-8 JSON with frozen key order so hashes do not depend on dict insert order."""
    return json.dumps(
        obj,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )


def canonical_bytes(obj: Any) -> bytes:
    return canonical_dumps(obj).encode("utf-8")


def semantic_hash(obj: Any) -> str:
    """sha256 hex of canonical JSON bytes."""
    return hashlib.sha256(canonical_bytes(obj)).hexdigest()


def file_sha256(path: str | os.PathLike[str]) -> str:
    """sha256 hex of the file's on-disk bytes."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _closed(obj: Mapping[str, Any], allowed: frozenset[str], label: str) -> None:
    extra = sorted(set(obj) - allowed)
    if extra:
        raise HandoffError(f"{label}: unknown keys {extra}")


def _require_keys(obj: Mapping[str, Any], required: Iterable[str], label: str) -> None:
    missing = sorted(set(required) - set(obj))
    if missing:
        raise HandoffError(f"{label}: missing keys {missing}")


def _as_str_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise HandoffError(f"{label} must be a list of strings")
    return list(value)


def _as_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise HandoffError(f"{label} must be an int")
    return value


def validate_claim(claim: Any, label: str) -> dict[str, Any]:
    if not isinstance(claim, dict):
        raise HandoffError(f"{label} must be an object")
    _require_keys(claim, CLAIM_KEYS, label)
    _closed(claim, CLAIM_KEYS, label)
    for key in ("id", "claim", "excerpt", "url", "language", "source_model"):
        if not isinstance(claim[key], str) or not claim[key] and key == "id":
            raise HandoffError(f"{label}.{key} must be a non-empty string" if key == "id"
                               else f"{label}.{key} must be a string")
        if key != "id" and not isinstance(claim[key], str):
            raise HandoffError(f"{label}.{key} must be a string")
    if not claim["id"]:
        raise HandoffError(f"{label}.id must be a non-empty string")
    _as_int(claim["credibility"], f"{label}.credibility")
    return claim


def validate_wip(wip: Any) -> dict[str, Any]:
    if not isinstance(wip, dict):
        raise HandoffError("wip must be an object")
    _require_keys(wip, WIP_TOP_KEYS, "wip")
    _closed(wip, WIP_TOP_KEYS, "wip")
    if wip.get("schema") != SCHEMA_WIP:
        raise HandoffError(f"wip.schema must be {SCHEMA_WIP}")
    if wip.get("handoff_version") != HANDOFF_VERSION:
        raise HandoffError("wip.handoff_version must be 1")
    if not isinstance(wip.get("clusters"), list):
        raise HandoffError("wip.clusters must be a list")
    for name in REQUIRED_WIP_LISTS:
        _as_str_list(wip[name], f"wip.{name}")
    for index, cluster in enumerate(wip["clusters"]):
        label = f"wip.clusters[{index}]"
        if not isinstance(cluster, dict):
            raise HandoffError(f"{label} must be an object")
        _require_keys(cluster, WIP_CLUSTER_KEYS, label)
        _closed(cluster, WIP_CLUSTER_KEYS, label)
        if not isinstance(cluster["cluster_id"], str) or not cluster["cluster_id"]:
            raise HandoffError(f"{label}.cluster_id must be a non-empty string")
        if not isinstance(cluster["summary"], str):
            raise HandoffError(f"{label}.summary must be a string")
        if not isinstance(cluster["relation"], str) or not cluster["relation"]:
            raise HandoffError(f"{label}.relation must be a non-empty string")
        if not isinstance(cluster["claims"], list) or not cluster["claims"]:
            raise HandoffError(f"{label}.claims must be a non-empty list")
        for cidx, claim in enumerate(cluster["claims"]):
            validate_claim(claim, f"{label}.claims[{cidx}]")
    extras = wip["unclustered_claims"]
    if not isinstance(extras, list):
        raise HandoffError("wip.unclustered_claims must be a list")
    for cidx, claim in enumerate(extras):
        validate_claim(claim, f"wip.unclustered_claims[{cidx}]")
    return wip


def _raw_claim_index(raw: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    index: dict[str, dict[str, Any]] = {}

    def _add(claim: Mapping[str, Any], label: str) -> None:
        validated = validate_claim(claim, label)
        cid = validated["id"]
        if cid in index:
            raise HandoffError(f"duplicate claim: {cid}")
        index[cid] = validated

    clusters = raw.get("clusters")
    if not isinstance(clusters, list):
        raise HandoffError("raw.clusters must be a list")
    for index_i, cluster in enumerate(clusters):
        if not isinstance(cluster, dict):
            raise HandoffError(f"raw.clusters[{index_i}] must be an object")
        claims = cluster.get("claims")
        if not isinstance(claims, list):
            raise HandoffError(f"raw.clusters[{index_i}].claims must be a list")
        for cidx, claim in enumerate(claims):
            if not isinstance(claim, dict):
                raise HandoffError(f"raw.clusters[{index_i}].claims[{cidx}] must be an object")
            _add(claim, f"raw.clusters[{index_i}].claims[{cidx}]")
    extras = raw.get("unclustered_claims", [])
    if extras:
        if not isinstance(extras, list):
            raise HandoffError("raw.unclustered_claims must be a list")
        for cidx, claim in enumerate(extras):
            if not isinstance(claim, dict):
                raise HandoffError(f"raw.unclustered_claims[{cidx}] must be an object")
            _add(claim, f"raw.unclustered_claims[{cidx}]")
    return index


def _norm_str_list(values: Iterable[str]) -> list[str]:
    return sorted(values)


def check_coverage(wip: Mapping[str, Any], raw: Mapping[str, Any]) -> None:
    """WIP must cover each accepted raw claim exactly once; cluster ids must match."""
    validate_wip(wip)
    raw_index = _raw_claim_index(raw)
    raw_clusters = raw.get("clusters") or []
    raw_cluster_ids = []
    raw_cluster_claim_ids: dict[str, list[str]] = {}
    for cluster in raw_clusters:
        cid = cluster.get("cluster_id")
        if not isinstance(cid, str) or not cid:
            raise HandoffError("raw cluster missing cluster_id")
        raw_cluster_ids.append(cid)
        raw_cluster_claim_ids[cid] = [claim["id"] for claim in cluster.get("claims") or []]

    seen: dict[str, str] = {}
    wip_cluster_ids = []
    for cluster in wip["clusters"]:
        cid = cluster["cluster_id"]
        wip_cluster_ids.append(cid)
        if cid not in raw_cluster_claim_ids:
            raise HandoffError(f"unknown cluster: {cid}")
        wip_ids = [claim["id"] for claim in cluster["claims"]]
        for claim_id in wip_ids:
            if claim_id in seen:
                raise HandoffError(f"duplicate claim: {claim_id}")
            if claim_id not in raw_index:
                raise HandoffError(f"unknown claim: {claim_id}")
            seen[claim_id] = cid
        if sorted(wip_ids) != sorted(raw_cluster_claim_ids[cid]):
            raise HandoffError(f"cluster membership incomplete: {cid}")

    if sorted(wip_cluster_ids) != sorted(raw_cluster_ids):
        raise HandoffError("cluster membership incomplete: missing raw cluster")

    raw_unclustered = _as_str_list(
        raw.get("unclustered_claim_ids", []), "raw.unclustered_claim_ids",
    )
    wip_unclustered = list(wip["unclustered_claim_ids"])
    if len(wip_unclustered) != len(set(wip_unclustered)):
        dup = next(cid for cid in wip_unclustered if wip_unclustered.count(cid) > 1)
        raise HandoffError(f"duplicate claim: {dup}")
    if sorted(wip_unclustered) != sorted(raw_unclustered):
        raise HandoffError("unclustered_claim_ids mismatch")
    body_ids = [claim["id"] for claim in wip["unclustered_claims"]]
    if len(body_ids) != len(set(body_ids)):
        dup = next(cid for cid in body_ids if body_ids.count(cid) > 1)
        raise HandoffError(f"duplicate claim: {dup}")
    if sorted(body_ids) != sorted(wip_unclustered):
        raise HandoffError("unclustered_claims id mismatch")
    for claim_id in wip_unclustered:
        if claim_id in seen:
            raise HandoffError(f"duplicate claim: {claim_id}")
        if claim_id not in raw_index:
            raise HandoffError(f"unknown claim: {claim_id}")
        seen[claim_id] = ""

    expected = set(raw_index)
    if set(seen) != expected:
        missing = sorted(expected - set(seen))
        extra = sorted(set(seen) - expected)
        if extra:
            raise HandoffError(f"unknown claim: {extra[0]}")
        raise HandoffError(f"missing claim: {missing[0]}")

    for field in ("coverage_gaps", "blind_spots", "unique_insights"):
        raw_vals = _as_str_list(raw.get(field, []), f"raw.{field}")
        if sorted(wip[field]) != sorted(raw_vals):
            raise HandoffError(f"{field} coverage mismatch")


def supporting_models(claims: Iterable[Mapping[str, Any]]) -> list[str]:
    return sorted({claim["source_model"] for claim in claims})


def classify_consensus(relation: str, models: list[str]) -> str:
    """Navigation label only — not a truth claim."""
    if relation == "contradict":
        return "disputed"
    if len(models) >= 2:
        return "corroborated"
    return "single-model"


def expansion_reasons(
    *,
    consensus: str,
    claim_ids: list[str],
    claims: list[Mapping[str, Any]],
    unique_insight_ids: set[str],
    unclustered: bool,
) -> list[str]:
    reasons: list[str] = []
    if consensus == "disputed":
        reasons.append("disputed")
    if consensus == "single-model":
        reasons.append("single-model")
    if any(cid in unique_insight_ids for cid in claim_ids):
        reasons.append("unique-insight")
    if any(int(claim["credibility"]) < 3 for claim in claims):
        reasons.append("low-credibility")
    if unclustered:
        reasons.append("unclustered")
    return sorted(reasons)


def pick_representative(claims: list[Mapping[str, Any]]) -> str:
    """Highest credibility; ties broken by claim id ascending."""
    ordered = sorted(claims, key=lambda c: (-int(c["credibility"]), c["id"]))
    return ordered[0]["id"]


def _evidence_sort_key(row: Mapping[str, Any]) -> tuple[bool, str, str]:
    # Empty cluster_id (unclustered) sorts after named clusters.
    cid = row["cluster_id"]
    return (cid == "", cid, row["id"])


def _evidence_row(cluster_id: str, claim: Mapping[str, Any]) -> dict[str, Any]:
    """Ledger line from a validated WIP claim. cluster_id is navigation only."""
    return {
        "cluster_id": cluster_id,
        "id": claim["id"],
        "claim": claim["claim"],
        "excerpt": claim["excerpt"],
        "url": claim["url"],
        "language": claim["language"],
        "credibility": claim["credibility"],
        "source_model": claim["source_model"],
        "excerpt_verification": EXCERPT_VERIFICATION,
    }


def build_evidence_rows(wip: Mapping[str, Any], raw: Mapping[str, Any]) -> list[dict[str, Any]]:
    # Coverage is ID-aligned against raw; sanitized bodies come from WIP.
    raw_index = _raw_claim_index(raw)
    rows: list[dict[str, Any]] = []
    for cluster in wip["clusters"]:
        for claim in cluster["claims"]:
            if claim["id"] not in raw_index:
                raise HandoffError(f"unknown claim: {claim['id']}")
            rows.append(_evidence_row(cluster["cluster_id"], claim))
    for claim in wip["unclustered_claims"]:
        if claim["id"] not in raw_index:
            raise HandoffError(f"unknown claim: {claim['id']}")
        rows.append(_evidence_row("", claim))
    rows.sort(key=_evidence_sort_key)
    return rows


def evidence_jsonl(rows: list[Mapping[str, Any]]) -> str:
    lines = []
    for row in rows:
        _closed(row, EVIDENCE_KEYS, "evidence")
        if row.get("excerpt_verification") != EXCERPT_VERIFICATION:
            raise HandoffError("excerpt_verification must be url_fetched_only")
        lines.append(canonical_dumps(row))
    return "".join(line + "\n" for line in lines)


def _cluster_window(rows: list[Mapping[str, Any]], cluster_id: str) -> tuple[int, int]:
    indices = [i for i, row in enumerate(rows) if row["cluster_id"] == cluster_id]
    if not indices:
        return 0, 0
    start = indices[0]
    return start, len(indices)


def build_manifest(
    wip: Mapping[str, Any],
    raw: Mapping[str, Any],
    *,
    goal_file_sha256: str,
    raw_merged_sha256: str,
    evidence_sha256: str,
    alive_models: list[str],
) -> dict[str, Any]:
    check_coverage(wip, raw)
    rows = build_evidence_rows(wip, raw)
    unique_ids = set(wip["unique_insights"])
    clusters_out: list[dict[str, Any]] = []
    for cluster in wip["clusters"]:
        claims = list(cluster["claims"])
        models = supporting_models(claims)
        consensus = classify_consensus(cluster["relation"], models)
        reasons = expansion_reasons(
            consensus=consensus,
            claim_ids=[c["id"] for c in claims],
            claims=claims,
            unique_insight_ids=unique_ids,
            unclustered=False,
        )
        presentation = "compressed" if (consensus == "corroborated" and not reasons) else "expanded"
        offset, limit = _cluster_window(rows, cluster["cluster_id"])
        clusters_out.append({
            "cluster_id": cluster["cluster_id"],
            "summary": cluster["summary"],
            "relation": cluster["relation"],
            "supporting_models": models,
            "consensus": consensus,
            "presentation": presentation,
            "expansion_reasons": reasons,
            "representative_claim_id": pick_representative(claims),
            "claim_ids": [c["id"] for c in claims],
            "evidence_offset": offset,
            "evidence_limit": limit,
        })

    unclustered_ids = list(wip["unclustered_claim_ids"])
    if unclustered_ids:
        claims = list(wip["unclustered_claims"])
        models = supporting_models(claims)
        consensus = classify_consensus("agree", models)
        reasons = expansion_reasons(
            consensus=consensus,
            claim_ids=unclustered_ids,
            claims=claims,
            unique_insight_ids=unique_ids,
            unclustered=True,
        )
        # Unclustered rows are addressable but stay out of clusters[];
        # R5 requires them fully expanded at the id list, not as compressed clusters.
        if "unclustered" not in reasons:
            reasons = sorted(reasons + ["unclustered"])

    manifest = {
        "schema": SCHEMA_MANIFEST,
        "handoff_version": HANDOFF_VERSION,
        "goal_file_sha256": goal_file_sha256,
        "raw_merged_sha256": raw_merged_sha256,
        "evidence_sha256": evidence_sha256,
        "alive_models": sorted(alive_models),
        "claim_count": len(rows),
        "cluster_count": len(clusters_out),
        "clusters": clusters_out,
        "coverage_gaps": list(wip["coverage_gaps"]),
        "blind_spots": list(wip["blind_spots"]),
        "contradictions": list(wip["contradictions"]),
        "unique_insight_ids": list(wip["unique_insights"]),
        "unclustered_claim_ids": unclustered_ids,
    }
    validate_manifest(manifest)
    return manifest


def validate_manifest(manifest: Any) -> dict[str, Any]:
    if not isinstance(manifest, dict):
        raise HandoffError("manifest must be an object")
    _require_keys(manifest, MANIFEST_TOP_KEYS, "manifest")
    _closed(manifest, MANIFEST_TOP_KEYS, "manifest")
    if manifest.get("schema") != SCHEMA_MANIFEST:
        raise HandoffError(f"manifest.schema must be {SCHEMA_MANIFEST}")
    if manifest.get("handoff_version") != HANDOFF_VERSION:
        raise HandoffError("manifest.handoff_version must be 1")
    for key in ("goal_file_sha256", "raw_merged_sha256", "evidence_sha256"):
        if not isinstance(manifest[key], str) or len(manifest[key]) != 64:
            raise HandoffError(f"manifest.{key} must be a sha256 hex")
    if not isinstance(manifest["alive_models"], list):
        raise HandoffError("manifest.alive_models must be a list")
    _as_int(manifest["claim_count"], "manifest.claim_count")
    _as_int(manifest["cluster_count"], "manifest.cluster_count")
    if not isinstance(manifest["clusters"], list):
        raise HandoffError("manifest.clusters must be a list")
    for index, cluster in enumerate(manifest["clusters"]):
        label = f"manifest.clusters[{index}]"
        if not isinstance(cluster, dict):
            raise HandoffError(f"{label} must be an object")
        _require_keys(cluster, MANIFEST_CLUSTER_KEYS, label)
        _closed(cluster, MANIFEST_CLUSTER_KEYS, label)
        if cluster["presentation"] not in ("expanded", "compressed"):
            raise HandoffError(f"{label}.presentation invalid")
        if cluster["consensus"] not in ("disputed", "corroborated", "single-model"):
            raise HandoffError(f"{label}.consensus invalid")
        if not isinstance(cluster["expansion_reasons"], list):
            raise HandoffError(f"{label}.expansion_reasons must be a list")
        if cluster["expansion_reasons"] != sorted(cluster["expansion_reasons"]):
            raise HandoffError(f"{label}.expansion_reasons must be sorted")
        _as_int(cluster["evidence_offset"], f"{label}.evidence_offset")
        _as_int(cluster["evidence_limit"], f"{label}.evidence_limit")
    for name in ("coverage_gaps", "blind_spots", "contradictions",
                 "unique_insight_ids", "unclustered_claim_ids"):
        _as_str_list(manifest[name], f"manifest.{name}")
    return manifest


def validate_evidence_line(row: Any) -> dict[str, Any]:
    if not isinstance(row, dict):
        raise HandoffError("evidence line must be an object")
    _require_keys(row, EVIDENCE_KEYS, "evidence")
    _closed(row, EVIDENCE_KEYS, "evidence")
    if row.get("excerpt_verification") != EXCERPT_VERIFICATION:
        raise HandoffError("excerpt_verification must be url_fetched_only")
    if "verified" in str(row.get("excerpt_verification", "")).lower() and \
            row["excerpt_verification"] != EXCERPT_VERIFICATION:
        raise HandoffError("verified-excerpt claim forbidden")
    return row


def parse_evidence_jsonl(text: str) -> list[dict[str, Any]]:
    rows = []
    for line_no, line in enumerate(text.splitlines()):
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise HandoffError(f"evidence line {line_no} is not JSON") from exc
        rows.append(validate_evidence_line(row))
    return rows


def validate_published(
    manifest: Mapping[str, Any],
    evidence_text: str,
    raw: Mapping[str, Any],
    wip: Mapping[str, Any] | None = None,
) -> None:
    validate_manifest(manifest)
    rows = parse_evidence_jsonl(evidence_text)
    expected_hash = hashlib.sha256(evidence_text.encode("utf-8")).hexdigest()
    if manifest["evidence_sha256"] != expected_hash:
        raise HandoffError("evidence_sha256 mismatch")
    if any(row["excerpt_verification"] != EXCERPT_VERIFICATION for row in rows):
        raise HandoffError("excerpt_verification must be url_fetched_only")
    if "verified-excerpt" in evidence_text:
        raise HandoffError("verified-excerpt claim forbidden")
    if len(rows) != manifest["claim_count"]:
        raise HandoffError("claim_count mismatch")
    if wip is not None:
        check_coverage(wip, raw)
        rebuilt = build_evidence_rows(wip, raw)
        if [semantic_hash(r) for r in rebuilt] != [semantic_hash(r) for r in rows]:
            raise HandoffError("evidence rows do not match wip/raw")


def atomic_write(path: Path, data: bytes) -> None:
    """Write via a unique same-dir temp file, then replace.

    A pre-existing sibling `{name}.tmp` (including a symlink planted
    there) must not be opened or truncated. mkstemp creates a new
    exclusive name; os.replace then swaps onto the target.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent),
    )
    tmp = Path(tmp_name)
    try:
        try:
            view = memoryview(data)
            written = 0
            while written < len(data):
                n = os.write(fd, view[written:])
                if n <= 0:
                    raise OSError("short write produced no progress")
                written += n
            os.fsync(fd)
        finally:
            os.close(fd)
            fd = -1
        os.replace(tmp, path)
    except Exception:
        if fd >= 0:
            os.close(fd)
        try:
            tmp.unlink()
        except OSError:
            pass
        raise


def artifact_names(track_name: str | None = None) -> dict[str, str]:
    if track_name:
        stem = f"track_{track_name}-"
    else:
        stem = ""
    return {
        "manifest": f"{stem}harvest-manifest.json",
        "evidence": f"{stem}harvest-evidence.jsonl",
        "wip": f"{stem}harvest-handoff.wip.json",
    }


def publish_handoff(
    cleaned_dir: str | os.PathLike[str],
    wip: Mapping[str, Any],
    raw: Mapping[str, Any],
    *,
    goal_file_sha256: str,
    raw_merged_sha256: str,
    alive_models: list[str],
    track_name: str | None = None,
) -> dict[str, Any]:
    """Validate in memory, then replace evidence first and manifest second."""
    check_coverage(wip, raw)
    rows = build_evidence_rows(wip, raw)
    evidence_text = evidence_jsonl(rows)
    evidence_hash = hashlib.sha256(evidence_text.encode("utf-8")).hexdigest()
    manifest = build_manifest(
        wip,
        raw,
        goal_file_sha256=goal_file_sha256,
        raw_merged_sha256=raw_merged_sha256,
        evidence_sha256=evidence_hash,
        alive_models=alive_models,
    )
    names = artifact_names(track_name)
    cleaned = Path(cleaned_dir)
    evidence_path = cleaned / names["evidence"]
    manifest_path = cleaned / names["manifest"]
    atomic_write(evidence_path, evidence_text.encode("utf-8"))
    atomic_write(manifest_path, canonical_bytes(manifest))
    validate_published(manifest, evidence_text, raw, wip)
    return manifest


def check_ready_payloads(
    *,
    verify: Mapping[str, Any],
    raw: Mapping[str, Any],
    manifest: Mapping[str, Any],
    evidence_text: str,
    goal_sha256: str,
    raw_sha256: str,
    manifest_sha256: str,
    evidence_sha256: str,
) -> None:
    """Invariants for a READY verify record. Raises HandoffError on any mismatch."""
    if verify.get("handoff_version") != HANDOFF_VERSION:
        raise HandoffError("handoff_version must be 1")
    if verify.get("handoff_required") is not True:
        raise HandoffError("handoff_required must be true")
    if verify.get("handoff_status") != "READY":
        raise HandoffError("handoff_status must be READY")
    validate_published(manifest, evidence_text, raw)
    if verify.get("manifest_sha256") != manifest_sha256:
        raise HandoffError("manifest_sha256 mismatch")
    if verify.get("evidence_sha256") != evidence_sha256:
        raise HandoffError("evidence_sha256 mismatch")
    if verify.get("raw_merged_sha256") != raw_sha256:
        raise HandoffError("raw_merged_sha256 mismatch")
    if verify.get("goal_file_sha256") and verify["goal_file_sha256"] != goal_sha256:
        raise HandoffError("goal_file_sha256 mismatch")
    if manifest.get("raw_merged_sha256") != raw_sha256:
        raise HandoffError("manifest raw_merged_sha256 mismatch")
    if manifest.get("evidence_sha256") != evidence_sha256:
        raise HandoffError("manifest evidence_sha256 mismatch")
    if manifest.get("goal_file_sha256") != goal_sha256:
        raise HandoffError("manifest goal_file_sha256 mismatch")


def check_published_against_raw(raw, manifest, evidence_text):
    """READY-path invariants: published set must still cover raw merged claims."""
    validate_published(manifest, evidence_text, raw)
    rows = parse_evidence_jsonl(evidence_text)
    raw_index = _raw_claim_index(raw)
    ev_ids = [row["id"] for row in rows]
    if sorted(ev_ids) != sorted(raw_index):
        raise HandoffError("evidence claim set mismatch")
    raw_clusters = {
        cluster["cluster_id"]: [claim["id"] for claim in cluster.get("claims") or []]
        for cluster in raw.get("clusters") or []
    }
    man_clusters = {
        cluster["cluster_id"]: list(cluster["claim_ids"])
        for cluster in manifest["clusters"]
    }
    if sorted(raw_clusters) != sorted(man_clusters):
        raise HandoffError("cluster membership incomplete: missing raw cluster")
    for cid, ids in raw_clusters.items():
        if sorted(ids) != sorted(man_clusters[cid]):
            raise HandoffError(f"cluster membership incomplete: {cid}")
    raw_un = raw.get("unclustered_claim_ids", [])
    if sorted(raw_un) != sorted(manifest["unclustered_claim_ids"]):
        raise HandoffError("unclustered_claim_ids mismatch")
    pairs = (
        ("coverage_gaps", "coverage_gaps"),
        ("blind_spots", "blind_spots"),
        ("unique_insights", "unique_insight_ids"),
    )
    for raw_field, man_field in pairs:
        if sorted(raw.get(raw_field, [])) != sorted(manifest.get(man_field, [])):
            raise HandoffError(f"{raw_field} coverage mismatch")


def check_ready_invariants(raw, manifest, evidence_text):
    """Published-artifact invariants used by check_project READY path."""
    check_published_against_raw(raw, manifest, evidence_text)
