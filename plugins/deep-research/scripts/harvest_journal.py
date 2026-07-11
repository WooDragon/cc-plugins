"""Journal-append helper: single choke point that stamps every journal
event with a wall-clock timestamp. Zero-dependency bottom module -- imported
by harvest.py + harvest_search + harvest_fetch, imports nothing of theirs, so
the dependency graph stays acyclic (harvest.py already imports the two
sub-packages; a reverse import would be a circular-import ImportError)."""
import time


def jappend(journal, entry):
    """Append `entry` to `journal` after stamping it with `t` (epoch seconds,
    0.1s precision -- same source/precision as run.log's _emit t field). The
    single place a journal event gets its timestamp, so no append site can
    forget it."""
    entry["t"] = round(time.time(), 1)
    journal.append(entry)
    return entry
