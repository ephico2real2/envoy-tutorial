#!/usr/bin/env python3
"""Run every command in a module README exactly as written, and fail on the first that breaks.

    python3 tooling/walkthrough/run.py 01-what-is-envoy/README.md            # check
    python3 tooling/walkthrough/run.py 01-what-is-envoy/README.md --update   # check, then
                                                                             # paste the real output

A walkthrough a junior engineer copies line by line is only true if every line
runs. This executes each command from the README's ```console blocks, from the
README's own directory, against the current cluster:

  $ command            a command, run with bash -o pipefail
  > continuation       joined to the command above with a newline
  anything else        the output the README shows for that command

--update replaces each command's output in the README with what it printed on
this run, so the pasted output is never older than the last successful run.

Two HTML comments, placed on the line before a block, change how it is run:

  <!-- walkthrough: skip -->          show the block, do not run it (e.g. it
                                      scales a Deployment to zero)
  <!-- walkthrough: expect-exit N --> every command in the block must exit N
                                      (e.g. a TLS handshake that must fail)

Each command runs in its own shell, so a walkthrough must not rely on a
variable set by an earlier command - which is also what makes each step safe
to copy on its own.
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

TIMEOUT_S = 240
DIRECTIVE = re.compile(r"<!--\s*walkthrough:\s*(skip|expect-exit\s+(\d+))\s*-->")


def parse(lines: list[str]):
    """Yield (start, end, directive, commands) per ```console block.

    commands: list of (command_line, command_text, first_output_line, end_output_line) as
    line indexes into `lines`, so --update can splice real output in place.
    """
    i = 0
    while i < len(lines):
        if lines[i].rstrip() == "```console":
            directive = None
            j = i - 1
            while j >= 0 and not lines[j].strip():
                j -= 1
            m = DIRECTIVE.search(lines[j]) if j >= 0 else None
            if m:
                directive = ("skip", None) if m.group(1) == "skip" else ("expect", int(m.group(2)))
            end = i + 1
            while lines[end].rstrip() != "```":
                end += 1
            cmds, k = [], i + 1
            while k < end:
                if lines[k].startswith("$ "):
                    cmd_line = k
                    text = [lines[k][2:].rstrip("\n")]
                    k += 1
                    while k < end and lines[k].startswith("> "):
                        text.append(lines[k][2:].rstrip("\n"))
                        k += 1
                    out_start = k
                    while k < end and not lines[k].startswith("$ "):
                        k += 1
                    cmds.append((cmd_line, "\n".join(text), out_start, k))
                else:
                    k += 1
            yield i, end, directive, cmds
            i = end + 1
        else:
            i += 1


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    update = "--update" in sys.argv
    if len(args) != 1:
        print(__doc__)
        return 2
    readme = pathlib.Path(args[0]).resolve()
    lines = readme.read_text().splitlines(keepends=True)
    # The reader's own environment, unchanged: the walkthrough must run as the
    # reader's `oc` does, with whatever KUBECONFIG / ~/.kube/config they have.
    env = dict(os.environ)

    replacements: list[tuple[int, int, list[str]]] = []
    ran = skipped = 0
    for _start, _end, directive, cmds in parse(lines):
        if directive and directive[0] == "skip":
            skipped += len(cmds)
            continue
        want = directive[1] if directive else 0
        for cmd_line, text, out_start, out_end in cmds:
            print(f"\n\033[1m$ {text.splitlines()[0]}{' …' if chr(10) in text else ''}\033[0m  (line {cmd_line + 1})")
            try:
                p = subprocess.run(["bash", "-o", "pipefail", "-c", text], cwd=readme.parent, env=env,
                                   capture_output=True, text=True, timeout=TIMEOUT_S)
            except subprocess.TimeoutExpired:
                print(f"  \033[31m✗ timed out after {TIMEOUT_S}s\033[0m")
                return 1
            output = p.stdout + p.stderr
            print("  " + output.rstrip().replace("\n", "\n  ") if output.strip() else "  (no output)")
            if p.returncode != want:
                print(f"  \033[31m✗ exit {p.returncode}, expected {want}\033[0m")
                return 1
            ran += 1
            real = [ln + "\n" for ln in output.rstrip("\n").split("\n")] if output.strip() else []
            replacements.append((out_start, out_end, real))

    if update:
        # Splice from the bottom up so earlier line indexes stay valid.
        for out_start, out_end, real in sorted(replacements, reverse=True):
            lines[out_start:out_end] = real
        readme.write_text("".join(lines))
        print(f"\nupdated {readme.name} with the output of this run")
    print(f"\n\033[1m{ran} command(s) ran as written, {skipped} skipped\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
