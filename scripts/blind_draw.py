#!/usr/bin/env python3
"""The blind draw of docs/post-freeze/pool.md.

    scripts/blind_draw.py <randomness-hex>         draw with a given beacon value
    scripts/blind_draw.py --fetch                  fetch round 6725846 from drand and draw

The rule, as written in pool.md before the freeze: for each ID of the not-planned pool, compute
SHA-256(randomness + ":" + ID) with the randomness in lowercase hex; sort by that hash as a hex
string, smallest first; take the first eight.
"""
import hashlib
import json
import os
import re
import sys
import urllib.request

ROUND = 6725846
COUNT = 8
POOL = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "post-freeze", "pool.md")


def pool_ids():
    ids = re.findall(r"^\| (U\d\d) \| ([^|]+) \|", open(POOL).read(), re.M)
    if not ids:
        sys.exit("no IDs found in " + POOL)
    return ids


def draw(randomness):
    randomness = randomness.strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", randomness):
        sys.exit("randomness must be 64 hex digits")
    scored = sorted(
        (hashlib.sha256(f"{randomness}:{i}".encode()).hexdigest(), i, name.strip())
        for i, name in pool_ids()
    )
    return scored[:COUNT]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    if sys.argv[1] == "--fetch":
        url = f"https://api.drand.sh/public/{ROUND}"
        beacon = json.load(urllib.request.urlopen(url, timeout=30))
        if beacon.get("round") != ROUND:
            sys.exit(f"unexpected beacon: {beacon}")
        randomness = beacon["randomness"]
        print(f"drand round {ROUND}: randomness {randomness}")
    else:
        randomness = sys.argv[1]
    for h, i, name in draw(randomness):
        print(f"{i}  {h[:16]}  {name}")


if __name__ == "__main__":
    main()
