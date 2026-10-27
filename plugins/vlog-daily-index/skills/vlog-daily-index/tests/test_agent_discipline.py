"""Bundled subagent bodies must carry the inline execution discipline.

The discipline lives in each agent body (system prompt) because that is the only
carrier that survives auto-compaction: a skill preload arrives as a user-role
message and is consumed by the summarizer, while the system prompt is re-sent
verbatim on every request. Verified against a real run with three auto
compaction boundaries.
"""
import unittest
import json
from pathlib import Path

AGENTS = Path(__file__).resolve().parents[3] / "agents"
MARKERS = (
    "## Execution Discipline",
    "Read narrowly",
    "trust the filesystem over the summary",
    "Externalized state (ad-hoc mode only)",
)


class TestAgentDiscipline(unittest.TestCase):
    def setUp(self):
        skill = Path(__file__).resolve().parents[1]
        # The standalone Skill ZIP intentionally excludes plugin-level agents.
        # A full plugin checkout must still fail when its agents are missing.
        manifest_path = skill / 'release-manifest.json'
        if (not AGENTS.exists() and skill.parent.name != 'skills'
                and not (AGENTS.parent / '.claude-plugin' / 'plugin.json').exists()
                and (skill / 'SKILL.md').is_file() and manifest_path.is_file()):
            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
            if (manifest.get('format') == 'source-skill-zip' and manifest.get('name') == skill.name
                    and manifest.get('version') == (skill / 'VERSION').read_text(encoding='utf-8').strip()
                    and 'tests/test_agent_discipline.py' in manifest.get('files', {})):
                self.skipTest('Standalone Skill release excludes plugin-level agents; checked in full plugin checkout')

    def test_every_agent_carries_the_discipline_block(self):
        files = sorted(AGENTS.glob("*.md"))
        self.assertTrue(files, "no agent definitions found")
        for path in files:
            text = path.read_text(encoding="utf-8")
            for marker in MARKERS:
                self.assertIn(marker, text, f"{path.name} is missing {marker!r}")

    def test_agents_do_not_preload_discipline_as_a_skill(self):
        for path in sorted(AGENTS.glob("*.md")):
            text = path.read_text(encoding="utf-8")
            frontmatter = text.split("\n---\n", 1)[0]
            self.assertNotIn(
                "agent-execution-discipline",
                frontmatter,
                f"{path.name} still preloads the discipline as a skill; "
                "that carrier does not survive auto-compaction",
            )


if __name__ == "__main__":
    unittest.main()
