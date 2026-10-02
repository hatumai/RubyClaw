#!/usr/bin/env python3
"""Relocate a ruby-builder tarball to a prefix of your choosing (no sudo, no patchelf).

    relocate_ruby.py <new-prefix> [tree-dir] [--old /opt/hostedtoolcache/Ruby/3.4.11/x64]

`tree-dir` is where the unpacked tarball currently is, when that is not the new
prefix (it is about to be moved there).

ruby-builder builds for the GitHub Actions toolcache path, so every binary carries
that absolute prefix (DT_RUNPATH, the bin/gem shebang, and Ruby's baked-in
load-path array). The old prefix is detected from the binary itself, so this works
for any Ruby version and any architecture. The new prefix is shorter than the old
one, so each baked string is rewritten in place and the leftover bytes zero-padded,
which keeps every ELF offset valid -- that is what makes this possible without
patchelf.

Two traps, both of which leave you with a working `ruby -v` and a broken Ruby:

  * NUL-separated *arrays* (ruby_initial_load_paths) are parsed as a list terminated
    by an EMPTY entry. Padding each entry inline inserts an empty entry after the
    first, so Ruby starts with ONE usable load path and every `require` fails with
    LoadError. Whole runs of entries get repacked tightly, padding only after the
    run's terminator.
  * Padding must go at the END of a whole NUL-terminated string. Padding before a
    trailing suffix ("/lib") truncates the path at load time.

Text files (shebangs, .pc, Makefile) may change length and get a plain replace.
"""
import os
import re
import sys
import pathlib

ARCH_RE = re.compile(rb"/opt/hostedtoolcache/Ruby/[^/\x00]+/[^/\x00]+")


def detect_old(root: pathlib.Path) -> bytes:
    """Find the baked-in toolcache prefix by reading it out of bin/ruby."""
    probe = root / "bin" / "ruby"
    if not probe.exists():
        raise SystemExit(f"! {probe} not found — is that a ruby-builder tarball?")
    m = ARCH_RE.search(probe.read_bytes())
    return m.group(0) if m else b""      # empty = already relocatable


def repack_lists(b: bytes, old: bytes, new: bytes):
    """Rewrite every NUL-separated list whose entries start with old, padding after
    the run's terminator so the parser never sees an empty entry early."""
    n, count = b, 0
    pos = 0
    while True:
        at = n.find(b"\0" + old, pos)
        if at < 0:
            break
        start = at + 1
        p, entries = start, []
        while n[p:p + len(old)] == old:
            q = n.find(b"\0", p)
            entries.append(n[p:q].replace(old, new))
            p = q + 1
        region = p - start                       # includes the last entry's terminator
        block = b"\0".join(entries) + b"\0"
        if len(block) > region:
            raise SystemExit("! new prefix is not shorter than the old one")
        n = n[:start] + block + b"\0" * (region - len(block)) + n[p:]
        count += 1
        pos = start + region
    return n, count


def fix_elf(b: bytes, old: bytes, new: bytes):
    b, lists = repack_lists(b, old, new)
    # anything left is an offset-addressed string: pad in place, at the end
    pat = re.compile(b"(?<=\x00)" + re.escape(old) + b"([^\x00]*)")

    def sub(m):
        s = new + m.group(1)
        return s + b"\x00" * (len(old) + len(m.group(1)) - len(s))

    b = pat.sub(sub, b)
    if b.startswith(old):
        m = re.match(re.escape(old) + b"([^\x00]*)", b)
        s = new + m.group(1)
        b = s + b"\x00" * (len(m.group(0)) - len(s)) + b[len(m.group(0)):]
    return b, lists


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    new = os.fsencode(os.path.abspath(os.path.expanduser(args[0] if args else "~/.rubyclaw/ruby")))
    # The tree may still be sitting in a staging directory: what matters is the
    # prefix it will live at, not where it is while being patched.
    root = pathlib.Path(args[1] if len(args) > 1 else os.fsdecode(new))

    old = None
    if "--old" in sys.argv:
        old = os.fsencode(sys.argv[sys.argv.index("--old") + 1])
    old = old or detect_old(root)
    if not old:
        print(f"= {root}: no toolcache prefix baked in, nothing to relocate")
        return 0
    if len(new) > len(old):
        raise SystemExit(f"! install prefix must be <= {len(old)} bytes, got {len(new)}: {os.fsdecode(new)}")
    print(f"= relocating {os.fsdecode(old)} -> {os.fsdecode(new)}")

    elf = txt = lists = 0
    for p in root.rglob("*"):
        if not p.is_file() or p.is_symlink():
            continue
        try:
            b = p.read_bytes()
        except OSError:
            continue
        if old not in b:
            continue
        if b[:4] == b"\x7fELF":
            b, n = fix_elf(b, old, new)
            lists += n
            elf += 1
        else:
            b = b.replace(old, new)
            txt += 1
        p.write_bytes(b)
    print(f"= patched {elf} binaries, {txt} text files, {lists} NUL-separated arrays")
    return 0


if __name__ == "__main__":
    sys.exit(main())
