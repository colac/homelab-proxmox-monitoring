#!/usr/bin/env python3
"""Refuse a secrets file that is not SOPS ciphertext throughout.

pre-commit passes the staged secrets.yaml files. Each must end in SOPS's
top-level `sops:` metadata, and above it every value and comment must be
ciphertext (ENC[...]), which is how `sops edit` writes them. That catches a
decrypted copy as well as a value or comment typed in by hand.

Line-based on purpose: standard library only, no age key needed, and it
reports line numbers and key names (plaintext in a SOPS file anyway), never
a value.
"""
import re
import sys

# A mapping key, bare or quoted, and whatever follows its colon.
KEY = re.compile(r"""^("[^"]*"|'[^']*'|[^\s#'"][^:]*?):(?:\s+(.*))?$""")
EMPTY = {"", '""', "''"}


def problems(path):
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    try:
        end = lines.index("sops:")
    except ValueError:
        return ["no top-level `sops:` metadata, so the file is not encrypted"]

    found = []
    for number, line in enumerate(lines[:end], start=1):
        text = line.strip()
        if text in ("", "---"):
            continue
        if text.startswith("#"):
            # SOPS leaves an empty comment as a bare "#": nothing to encrypt.
            if text != "#" and not text.startswith("#ENC["):
                found.append(f"line {number}: a comment that is not encrypted")
            continue
        while text.startswith("- "):  # list items
            text = text[2:].lstrip()
        if text.startswith("ENC["):
            continue
        match = KEY.match(text)
        if not match:
            found.append(f"line {number}: not a SOPS entry")
            continue
        value = (match.group(2) or "").strip()
        if value not in EMPTY and not value.startswith("ENC["):
            found.append(f"line {number}: the value of {match.group(1)} is not encrypted")
    return found


def main(paths):
    failed = False
    for path in paths:
        for problem in problems(path):
            print(f"{path}: {problem}")
            failed = True
    if failed:
        print(
            "Edit secrets only with `mise run secrets:edit`, or encrypt a "
            "plaintext file with `sops --encrypt --in-place <file>`."
        )
    return int(failed)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
