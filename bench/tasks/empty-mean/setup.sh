#!/bin/sh
# Broken module + the test that defines "done".
set -e
cat > calc.py <<'PY'
def mean(xs):
    total = 0
    for x in xs:
        total += x
    return total / len(xs)
PY
cat > test_calc.py <<'PY'
from calc import mean

assert mean([1, 2, 3]) == 2
try:
    mean([])
except ValueError:
    pass
else:
    raise SystemExit("mean([]) must raise ValueError")
print("ok")
PY
