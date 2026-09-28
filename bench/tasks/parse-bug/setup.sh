#!/bin/sh
set -e
cat > duration.py <<'PY'
def parse_duration(text):
    """Parse '1h30m', '45s', '2m' into seconds."""
    total = 0
    number = 0
    for ch in text:
        if ch.isdigit():
            number = number * 10 + int(ch)
        elif ch == "h":
            total += number * 60
            number = 0
        elif ch == "m":
            total += number
            number = 0
        elif ch == "s":
            total += number
            number = 0
    return total
PY
cat > test_duration.py <<'PY'
from duration import parse_duration

cases = {"45s": 45, "2m": 120, "1h": 3600, "1h30m": 5400, "1h2m3s": 3723}
for text, want in cases.items():
    got = parse_duration(text)
    assert got == want, f"{text}: got {got}, want {want}"
print("ok")
PY
