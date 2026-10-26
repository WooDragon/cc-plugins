"""Bundled subagent bodies must carry the inline execution discipline.

The discipline lives in each agent body (system prompt) because that is the only
carrier that survives auto-compaction: a skill preload arrives as a user-role
message and is consumed by the summarizer, while the system prompt is re-sent
verbatim on every request. Verified against a real run with three auto
compaction boundaries.
"""
import unittest
from pathlib import Path

AGENTS = Path(__file__).resolve().parents[3] / "agents"
MARKERS = (
    "## Execution Discipline",
    "Read narrowly",
    "trust the filesystem over the summary",
    "Externalized state (ad-hoc mode only)",
)


class TestAgentDiscipline(unittest.TestCase):
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
