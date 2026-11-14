#!/usr/bin/env python3
"""export_debug_output.py: writes the output files a to-silica transpiler printed in its debug mode into a directory.

PROVISIONAL (P1). The transpiler's real output is records in its store (app design 6.5), and the real exporter reads
a (:backing) region's file (app design 6.6, P2). The P1 transpiler's store is (:memory): there is no file to read.
So, with ts_config@debug_output() true, it also prints every output file to standard output between marker lines,
and this script cuts them out of that log:

    === to-silica output file: <path> session: <id> ===
    ...content...
    === end of <path> ===

Usage: export_debug_output.py <transpiler-stdout-log> <session-id> <directory>
Writes only plain file names (no separator, no "..") inside <directory>; prints each file written.
"""
import os
import re
import sys


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    log, session, out = sys.argv[1:]
    text = open(log, encoding="utf-8", errors="replace").read()
    begin = re.compile(r"^=== to-silica output file: (\S+) session: (\S+) ===\n", re.M)
    written = 0
    for m in begin.finditer(text):
        path, sid = m.group(1), m.group(2)
        if sid != session:
            continue
        if "/" in path or "\\" in path or path in ("", ".", "..") or path.startswith("."):
            raise SystemExit("refusing the path %r" % path)
        end = text.find("=== end of %s ===\n" % path, m.end())
        if end < 0:
            raise SystemExit("no end marker for %s" % path)
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, path), "w", encoding="utf-8") as f:
            f.write(text[m.end():end])
        print(os.path.join(out, path))
        written += 1
    if written == 0:
        raise SystemExit("no output file of session %s in %s" % (session, log))


if __name__ == "__main__":
    main()
