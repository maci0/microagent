#!/bin/sh
set -e
cat > wc.py <<'PY'
import sys

def count(text, unique=False):
    words = text.split()
    return len(words)

def main(argv):
    text = sys.stdin.read()
    print(count(text))

if __name__ == "__main__":
    main(sys.argv[1:])
PY
cat > test_wc.py <<'PY'
import subprocess

out = subprocess.run(["python3", "wc.py"], input="a b a", capture_output=True, text=True)
assert out.stdout.strip() == "3", out
out = subprocess.run(["python3", "wc.py", "--unique"], input="a b a", capture_output=True, text=True)
assert out.stdout.strip() == "2", out
print("ok")
PY
