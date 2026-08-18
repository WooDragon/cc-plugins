"""Harvest handoff closed-schema / publish / consensus tests.

Imports harvest_handoff only — never harvest.py — so CLI side effects stay out.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


HANDOFF_PATH = Path(__file__).resolve().parents[1] / "scripts" / "harvest_handoff.py"


def _load_handoff():
    spec = importlib.util.spec_from_file_location("harvest_handoff", HANDOFF_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules["harvest_handoff"] = module
    spec.loader.exec_module(module)
    return module


hh = _load_handoff()


def _claim(cid, model="gpt", cred=4, claim="c", excerpt="e", url="https://ex.test/a"):
    return {
        "id": cid,
        "claim": claim,
        "excerpt": excerpt,
        "url": url,
        "language": "en",
        "credibility": cred,
        "source_model": model,
    }


def _cluster(cid, claims, relation="agree", summary="s"):
    return {
        "cluster_id": cid,
        "summary": summary,
        "relation": relation,
        "claims": claims,
    }


def _raw_and_wip(clusters, *, gaps=None, blinds=None, insights=None,
                 unclustered=None, contradictions=None):
    unclustered = unclustered or []
    raw = {
        "clusters": [
            {
                "cluster_id": c["cluster_id"],
                "summary": c["summary"],
                "relation": c["relation"],
                "claims": list(c["claims"]),
            }
            for c in clusters
        ],
        "coverage_gaps": list(gaps or []),
        "blind_spots": list(blinds or []),
        "contradictions": list(contradictions or []),
        "unique_insights": list(insights or []),
        "unclustered_claim_ids": [c["id"] for c in unclustered],
        "unclustered_claims": list(unclustered),
    }
    wip = {
        "schema": "harvest-handoff-wip",
        "handoff_version": 1,
        "clusters": [
            {
                "cluster_id": c["cluster_id"],
                "summary": c["summary"],
                "relation": c["relation"],
                "claims": list(c["claims"]),
            }
            for c in clusters
        ],
        "coverage_gaps": list(gaps or []),
        "blind_spots": list(blinds or []),
        "contradictions": list(contradictions or []),
        "unique_insights": list(insights or []),
        "unclustered_claim_ids": [c["id"] for c in unclustered],
        "unclustered_claims": list(unclustered),
    }
    return raw, wip


def _goal_hash():
    return hashlib.sha256(b"goal").hexdigest()


def _raw_hash(raw):
    return hh.semantic_hash(raw)


class TestH2PublishAndHash(unittest.TestCase):
    def test_h2_valid_wip_publishes_manifest_and_ledger_with_recomputable_hash(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1", "gpt"), _claim("gem-1", "gemini")]),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            cleaned = Path(tmp)
            manifest = hh.publish_handoff(
                cleaned, wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "gemini"],
            )
            man_path = cleaned / "harvest-manifest.json"
            ev_path = cleaned / "harvest-evidence.jsonl"
            self.assertTrue(man_path.is_file())
            self.assertTrue(ev_path.is_file())
            on_disk = json.loads(man_path.read_text(encoding="utf-8"))
            self.assertEqual(on_disk, manifest)
            evidence_text = ev_path.read_text(encoding="utf-8")
            self.assertEqual(
                hashlib.sha256(evidence_text.encode("utf-8")).hexdigest(),
                manifest["evidence_sha256"],
            )
            self.assertEqual(hh.file_sha256(ev_path), manifest["evidence_sha256"])
            self.assertEqual(hh.semantic_hash(on_disk), hh.semantic_hash(manifest))
            hh.validate_published(on_disk, evidence_text, raw, wip)


class TestH5CanonicalStability(unittest.TestCase):
    def test_h5_key_order_and_republish_are_byte_identical(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1", "gpt"), _claim("gem-1", "gemini")]),
        ])
        shuffled_wip = json.loads(json.dumps(wip))
        shuffled_wip["clusters"][0] = {
            "relation": shuffled_wip["clusters"][0]["relation"],
            "summary": shuffled_wip["clusters"][0]["summary"],
            "cluster_id": shuffled_wip["clusters"][0]["cluster_id"],
            "claims": shuffled_wip["clusters"][0]["claims"],
        }
        with tempfile.TemporaryDirectory() as tmp:
            cleaned = Path(tmp)
            kwargs = dict(
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "gemini"],
            )
            hh.publish_handoff(cleaned, wip, raw, **kwargs)
            first_man = (cleaned / "harvest-manifest.json").read_bytes()
            first_ev = (cleaned / "harvest-evidence.jsonl").read_bytes()
            hh.publish_handoff(cleaned, shuffled_wip, raw, **kwargs)
            self.assertEqual((cleaned / "harvest-manifest.json").read_bytes(), first_man)
            self.assertEqual((cleaned / "harvest-evidence.jsonl").read_bytes(), first_ev)
            self.assertEqual(hh.file_sha256(cleaned / "harvest-manifest.json"),
                             hashlib.sha256(first_man).hexdigest())


class TestS1CoverageRejects(unittest.TestCase):
    def test_s1_missing_claim_rejected(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1"), _claim("gem-1", "gemini")]),
        ])
        wip["clusters"][0]["claims"] = [wip["clusters"][0]["claims"][0]]
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.check_coverage(wip, raw)
        self.assertIn("cluster membership incomplete", str(ctx.exception))

    def test_s1_duplicate_claim_rejected(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1"), _claim("gem-1", "gemini")]),
            _cluster("c002", [_claim("gpt-2")]),
        ])
        wip["clusters"][1]["claims"] = [dict(wip["clusters"][0]["claims"][0])]
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.check_coverage(wip, raw)
        self.assertIn("duplicate claim", str(ctx.exception))

    def test_s1_unknown_claim_rejected(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1"), _claim("gem-1", "gemini")]),
        ])
        wip["clusters"][0]["claims"][1] = _claim("stranger")
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.check_coverage(wip, raw)
        self.assertRegex(str(ctx.exception), r"unknown claim|cluster membership")

    def test_s1_missing_raw_cluster_rejected(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1")]),
            _cluster("c002", [_claim("gem-1", "gemini")]),
        ])
        wip["clusters"] = [wip["clusters"][0]]
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.check_coverage(wip, raw)
        self.assertIn("cluster membership incomplete", str(ctx.exception))


class TestGapBlindCountOnly(unittest.TestCase):
    def test_sanitized_gap_text_same_count_publishes_wip_text(self):
        raw, wip = _raw_and_wip(
            [_cluster("c001", [_claim("gpt-1"), _claim("gem-1", "gemini")])],
            gaps=["email alice@example.com missing share"],
            blinds=["phone 13800138000 no primary"],
        )
        wip["coverage_gaps"] = ["email [REDACTED] missing share"]
        wip["blind_spots"] = ["phone [REDACTED] no primary"]
        with tempfile.TemporaryDirectory() as tmp:
            manifest = hh.publish_handoff(
                Path(tmp), wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "gemini"],
            )
            evidence_text = (Path(tmp) / "harvest-evidence.jsonl").read_text(encoding="utf-8")
        self.assertEqual(manifest["coverage_gaps"], ["email [REDACTED] missing share"])
        self.assertEqual(manifest["blind_spots"], ["phone [REDACTED] no primary"])
        hh.check_published_against_raw(raw, manifest, evidence_text)
        hh.check_ready_invariants(raw, manifest, evidence_text)

    def test_gap_count_mismatch_rejected(self):
        raw, wip = _raw_and_wip(
            [_cluster("c001", [_claim("gpt-1")])],
            gaps=["one", "two"],
        )
        wip["coverage_gaps"] = ["only-one"]
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.check_coverage(wip, raw)
        self.assertIn("coverage_gaps coverage mismatch", str(ctx.exception))

    def test_insight_set_mismatch_still_rejected(self):
        raw, wip = _raw_and_wip(
            [_cluster("c001", [_claim("gpt-1"), _claim("gem-1", "gemini")])],
            insights=["gpt-1"],
        )
        wip["unique_insights"] = ["gem-1"]
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.check_coverage(wip, raw)
        self.assertIn("unique_insights coverage mismatch", str(ctx.exception))


class TestRelationClosedSet(unittest.TestCase):
    def test_unknown_relation_wip_rejected(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1")], relation="maybe"),
        ])
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.validate_wip(wip)
        self.assertIn("relation", str(ctx.exception))
        with self.assertRaises(hh.HandoffError):
            hh.check_coverage(wip, raw)

    def test_wip_flipping_raw_contradict_to_agree_is_rejected(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1"), _claim("gem-1", "gemini")], relation="contradict"),
        ])
        wip["clusters"][0]["relation"] = "agree"
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.check_coverage(wip, raw)
        self.assertIn("relation", str(ctx.exception))
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(hh.HandoffError) as pub_ctx:
                hh.publish_handoff(
                    Path(tmp), wip, raw,
                    goal_file_sha256=_goal_hash(),
                    raw_merged_sha256=_raw_hash(raw),
                    alive_models=["gpt", "gemini"],
                )
            self.assertIn("relation", str(pub_ctx.exception))

    def test_published_manifest_relation_flip_fails_raw_check(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1"), _claim("gem-1", "gemini")], relation="contradict"),
        ], contradictions=["c001"])
        with tempfile.TemporaryDirectory() as tmp:
            manifest = hh.publish_handoff(
                Path(tmp), wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "gemini"],
            )
            evidence_text = (Path(tmp) / "harvest-evidence.jsonl").read_text(encoding="utf-8")
        hh.check_published_against_raw(raw, manifest, evidence_text)
        flipped = json.loads(json.dumps(manifest))
        flipped["clusters"][0]["relation"] = "agree"
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.check_published_against_raw(raw, flipped, evidence_text)
        self.assertIn("relation", str(ctx.exception))

    def test_raw_missing_relation_defaults_to_agree(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1")]),
        ])
        del raw["clusters"][0]["relation"]
        hh.check_coverage(wip, raw)

    def test_classify_consensus_unknown_relation_is_disputed(self):
        self.assertEqual(hh.classify_consensus("weird", ["a", "b"]), "disputed")
        self.assertEqual(hh.classify_consensus("contradict", ["a", "b"]), "disputed")
        self.assertEqual(hh.classify_consensus("agree", ["a", "b"]), "corroborated")


class TestArtifactNamesTrack(unittest.TestCase):
    def test_empty_track_name_rejected(self):
        with self.assertRaises(hh.HandoffError):
            hh.artifact_names("")
        with self.assertRaises(hh.HandoffError):
            hh.artifact_names(".")
        with self.assertRaises(hh.HandoffError):
            hh.artifact_names("..")
        self.assertEqual(hh.artifact_names(None)["manifest"], "harvest-manifest.json")
        self.assertEqual(
            hh.artifact_names("gap_A")["manifest"],
            "track_gap_A-harvest-manifest.json",
        )


class TestR1CorroboratedCompressed(unittest.TestCase):
    def test_r1_agree_two_models_no_anomaly_is_corroborated_compressed(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [
                _claim("b-1", "gpt", cred=4),
                _claim("a-1", "gemini", cred=4),
            ]),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            manifest = hh.publish_handoff(
                Path(tmp), wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "gemini"],
            )
        cluster = manifest["clusters"][0]
        self.assertEqual(cluster["consensus"], "corroborated")
        self.assertEqual(cluster["presentation"], "compressed")
        self.assertEqual(cluster["expansion_reasons"], [])
        # credibility tie → claim id ascending
        self.assertEqual(cluster["representative_claim_id"], "a-1")
        self.assertEqual(cluster["evidence_offset"], 0)
        self.assertEqual(cluster["evidence_limit"], 2)


class TestR2DisputedExpanded(unittest.TestCase):
    def test_r2_contradict_is_disputed_expanded(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [
                _claim("gpt-1", "gpt"),
                _claim("gem-1", "gemini"),
            ], relation="contradict"),
        ], contradictions=["gpt-1 vs gem-1"])
        with tempfile.TemporaryDirectory() as tmp:
            manifest = hh.publish_handoff(
                Path(tmp), wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "gemini"],
            )
        cluster = manifest["clusters"][0]
        self.assertEqual(cluster["consensus"], "disputed")
        self.assertEqual(cluster["presentation"], "expanded")
        self.assertIn("disputed", cluster["expansion_reasons"])


class TestR3SingleModelExpanded(unittest.TestCase):
    def test_r3_single_model_is_expanded(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1", "gpt"), _claim("gpt-2", "gpt")]),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            manifest = hh.publish_handoff(
                Path(tmp), wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt"],
            )
        cluster = manifest["clusters"][0]
        self.assertEqual(cluster["consensus"], "single-model")
        self.assertEqual(cluster["presentation"], "expanded")
        self.assertIn("single-model", cluster["expansion_reasons"])


class TestR4UniqueOrLowCredExpanded(unittest.TestCase):
    def test_r4_unique_insight_expands_and_keeps_claim_id(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [
                _claim("gpt-1", "gpt", cred=5),
                _claim("gem-1", "gemini", cred=5),
            ]),
        ], insights=["gem-1"])
        with tempfile.TemporaryDirectory() as tmp:
            manifest = hh.publish_handoff(
                Path(tmp), wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "gemini"],
            )
        cluster = manifest["clusters"][0]
        self.assertEqual(cluster["presentation"], "expanded")
        self.assertIn("unique-insight", cluster["expansion_reasons"])
        self.assertIn("gem-1", cluster["claim_ids"])
        self.assertEqual(manifest["unique_insight_ids"], ["gem-1"])

    def test_r4_low_credibility_expands(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [
                _claim("gpt-1", "gpt", cred=2),
                _claim("gem-1", "gemini", cred=5),
            ]),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            manifest = hh.publish_handoff(
                Path(tmp), wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "gemini"],
            )
        cluster = manifest["clusters"][0]
        self.assertEqual(cluster["presentation"], "expanded")
        self.assertIn("low-credibility", cluster["expansion_reasons"])
        self.assertIn("gpt-1", cluster["claim_ids"])


class TestR5TopLevelAndUnclustered(unittest.TestCase):
    def test_r5_gaps_and_blind_spots_kept_at_top_level_unclustered_expanded(self):
        unclustered = [_claim("solo-1", "claude", cred=4)]
        raw, wip = _raw_and_wip(
            [_cluster("c001", [_claim("gpt-1", "gpt"), _claim("gem-1", "gemini")])],
            gaps=["missing market share"],
            blinds=["no primary source"],
            unclustered=unclustered,
        )
        with tempfile.TemporaryDirectory() as tmp:
            cleaned = Path(tmp)
            manifest = hh.publish_handoff(
                cleaned, wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "gemini", "claude"],
            )
            rows = hh.parse_evidence_jsonl(
                (cleaned / "harvest-evidence.jsonl").read_text(encoding="utf-8")
            )
        self.assertEqual(manifest["coverage_gaps"], ["missing market share"])
        self.assertEqual(manifest["blind_spots"], ["no primary source"])
        self.assertEqual(manifest["unclustered_claim_ids"], ["solo-1"])
        # clustered rows first, unclustered last with empty cluster_id
        self.assertEqual(rows[-1]["id"], "solo-1")
        self.assertEqual(rows[-1]["cluster_id"], "")
        # unclustered is not a compressed cluster
        self.assertTrue(all(c["cluster_id"] != "" for c in manifest["clusters"]))


class TestE1ExcerptVerification(unittest.TestCase):
    def test_e1_every_line_is_url_fetched_only_never_verified_excerpt(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1"), _claim("gem-1", "gemini")]),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            hh.publish_handoff(
                Path(tmp), wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "gemini"],
            )
            text = (Path(tmp) / "harvest-evidence.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("verified-excerpt", text)
        self.assertNotIn("verified_excerpt", text)
        for row in hh.parse_evidence_jsonl(text):
            self.assertEqual(row["excerpt_verification"], "url_fetched_only")

    def test_e1_validate_rejects_verified_excerpt_token(self):
        with self.assertRaises(hh.HandoffError):
            hh.validate_evidence_line({
                **_claim("gpt-1"),
                "cluster_id": "c001",
                "excerpt_verification": "verified-excerpt",
            })


class TestLedgerUsesWipBodies(unittest.TestCase):
    def test_clustered_evidence_uses_wip_text_not_raw(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1", claim="RAW_CLAIM", excerpt="RAW_EX")]),
        ])
        wip["clusters"][0]["claims"][0] = _claim(
            "gpt-1", claim="WIP_CLAIM", excerpt="WIP_EX",
        )
        rows = hh.build_evidence_rows(wip, raw)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["claim"], "WIP_CLAIM")
        self.assertEqual(rows[0]["excerpt"], "WIP_EX")
        self.assertNotEqual(rows[0]["claim"], raw["clusters"][0]["claims"][0]["claim"])
        self.assertNotEqual(rows[0]["excerpt"], raw["clusters"][0]["claims"][0]["excerpt"])
        with tempfile.TemporaryDirectory() as tmp:
            manifest = hh.publish_handoff(
                Path(tmp), wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt"],
            )
            evidence_text = (Path(tmp) / "harvest-evidence.jsonl").read_text(encoding="utf-8")
        hh.validate_published(manifest, evidence_text, raw, wip)
        self.assertIn("WIP_CLAIM", evidence_text)
        self.assertNotIn("RAW_CLAIM", evidence_text)

    def test_unclustered_evidence_uses_wip_text_not_raw(self):
        raw, wip = _raw_and_wip(
            [_cluster("c001", [_claim("gpt-1")])],
            unclustered=[_claim("solo-1", "claude", claim="RAW_SOLO", excerpt="RAW_SOLO_EX")],
        )
        wip["unclustered_claims"] = [
            _claim("solo-1", "claude", claim="WIP_SOLO", excerpt="WIP_SOLO_EX"),
        ]
        rows = hh.build_evidence_rows(wip, raw)
        solo = next(row for row in rows if row["id"] == "solo-1")
        self.assertEqual(solo["claim"], "WIP_SOLO")
        self.assertEqual(solo["excerpt"], "WIP_SOLO_EX")
        self.assertNotEqual(solo["claim"], raw["unclustered_claims"][0]["claim"])
        with tempfile.TemporaryDirectory() as tmp:
            manifest = hh.publish_handoff(
                Path(tmp), wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "claude"],
            )
            evidence_text = (Path(tmp) / "harvest-evidence.jsonl").read_text(encoding="utf-8")
        hh.validate_published(manifest, evidence_text, raw, wip)
        self.assertIn("WIP_SOLO", evidence_text)
        self.assertNotIn("RAW_SOLO", evidence_text)

    def test_missing_unclustered_claims_rejected(self):
        raw, wip = _raw_and_wip([_cluster("c001", [_claim("gpt-1")])])
        del wip["unclustered_claims"]
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.validate_wip(wip)
        self.assertIn("unclustered_claims", str(ctx.exception))
        with self.assertRaises(hh.HandoffError):
            hh.check_coverage(wip, raw)

    def test_unclustered_claims_id_set_must_match_ids(self):
        raw, wip = _raw_and_wip(
            [_cluster("c001", [_claim("gpt-1")])],
            unclustered=[_claim("solo-1", "claude")],
        )
        wip["unclustered_claims"] = []
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.check_coverage(wip, raw)
        self.assertIn("unclustered_claims", str(ctx.exception))
        wip["unclustered_claims"] = [_claim("solo-1", "claude"), _claim("extra-1", "claude")]
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.check_coverage(wip, raw)
        self.assertIn("unclustered_claims", str(ctx.exception))
        wip["unclustered_claims"] = [
            _claim("solo-1", "claude"),
            _claim("solo-1", "claude", claim="dup"),
        ]
        with self.assertRaises(hh.HandoffError) as ctx:
            hh.check_coverage(wip, raw)
        self.assertRegex(str(ctx.exception), r"duplicate claim|unclustered_claims")


class TestAtomicWriteRetriesShortWrite(unittest.TestCase):
    def test_short_write_retries_until_full_payload_lands(self):
        payload = b"ABCDEFGH" * 32
        real_write = os.write
        calls = {"n": 0}

        def short_then_full(fd, buf):
            calls["n"] += 1
            view = memoryview(buf)
            if calls["n"] == 1:
                half = max(1, len(view) // 2)
                return real_write(fd, view[:half])
            return real_write(fd, view)

        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "out.bin"
            with patch.object(hh.os, "write", side_effect=short_then_full):
                hh.atomic_write(dest, payload)
            self.assertEqual(dest.read_bytes(), payload)
            self.assertGreaterEqual(calls["n"], 2)

    def test_zero_progress_raises_and_does_not_replace(self):
        payload = b"NEW-CONTENT"
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "out.bin"
            with patch.object(hh.os, "write", return_value=0):
                with self.assertRaises(OSError):
                    hh.atomic_write(dest, payload)
            self.assertFalse(dest.exists())

            dest.write_bytes(b"OLD")
            with patch.object(hh.os, "write", return_value=0):
                with self.assertRaises(OSError):
                    hh.atomic_write(dest, payload)
            self.assertEqual(dest.read_bytes(), b"OLD")


class TestAtomicWriteIgnoresSiblingTmpSymlink(unittest.TestCase):
    def test_preexisting_evidence_tmp_symlink_is_not_followed(self):
        raw, wip = _raw_and_wip([
            _cluster("c001", [_claim("gpt-1", "gpt"), _claim("gem-1", "gemini")]),
        ])
        with tempfile.TemporaryDirectory() as outside_dir, tempfile.TemporaryDirectory() as cleaned_dir:
            victim = Path(outside_dir) / "outside-victim.bin"
            original = b"DO-NOT-TOUCH"
            victim.write_bytes(original)
            planted = Path(cleaned_dir) / "harvest-evidence.jsonl.tmp"
            os.symlink(victim, planted)
            hh.publish_handoff(
                Path(cleaned_dir), wip, raw,
                goal_file_sha256=_goal_hash(),
                raw_merged_sha256=_raw_hash(raw),
                alive_models=["gpt", "gemini"],
            )
            self.assertEqual(victim.read_bytes(), original)
            self.assertTrue(planted.is_symlink())
            evidence = Path(cleaned_dir) / "harvest-evidence.jsonl"
            self.assertTrue(evidence.is_file())
            self.assertFalse(evidence.is_symlink())
            text = evidence.read_text(encoding="utf-8")
            self.assertIn("gpt-1", text)
            rows = hh.parse_evidence_jsonl(text)
            self.assertEqual({row["id"] for row in rows}, {"gpt-1", "gem-1"})


if __name__ == "__main__":
    unittest.main()
