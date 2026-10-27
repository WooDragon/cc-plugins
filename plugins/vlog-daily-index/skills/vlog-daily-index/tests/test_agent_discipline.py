"""Reading discipline must not be duplicated into bundled agent bodies.

The discipline lives in the user's global ``~/.claude/CLAUDE.md``. Every
subagent loads that file, so a per-agent copy only adds the same text to each
request's system prompt without widening coverage.

Measured behaviour behind this rule (313 injection records across all local
sessions, plus a 116-compaction survey):

- ``instructions`` attachments carrying CLAUDE.md reappear in full immediately
  after every auto-compaction boundary, for ``general-purpose`` and every
  custom agent type.
- ``Explore`` and ``Plan`` never receive CLAUDE.md at all, so an in-body copy
  in a bundled agent would not help them either.
- A ``skills:`` preload arrives as a user-role message and is consumed by the
  summarizer; it is gone after the first compaction.
"""
import unittest
from pathlib import Path

AGENTS = Path(__file__).resolve().parents[3] / "agents"
FORBIDDEN = (
    "## Execution Discipline",
    "Read narrowly",
    "trust the filesystem over the summary",
    "Externalized state (ad-hoc mode only)",
)


class TestAgentDiscipline(unittest.TestCase):
    def test_agent_bodies_do_not_duplicate_the_global_discipline(self):
        files = sorted(AGENTS.glob("*.md"))
        self.assertTrue(files, "no agent definitions found")
        for path in files:
            text = path.read_text(encoding="utf-8")
            for marker in FORBIDDEN:
                self.assertNotIn(
                    marker,
                    text,
                    f"{path.name} duplicates the global reading discipline "
                    f"({marker!r}); it belongs in ~/.claude/CLAUDE.md only",
                )

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
