# shellcheck shell=sh
# Appending one measurement row to a committed JSONL results file, once per
# logical run, as a sourced shell function. Not meant to be run.
#
#   record_run_row FILE ROW FIELD...   append ROW unless this run already
#                                     recorded one over the same FIELD values
#
# ROW is the whole line already JSON-escaped by whatever built it, and FIELDs
# name the fields that identify the measurement: the agent and the task for the
# harness benchmark, the agent for the usefulness one. The `run` field is not
# named here; it is part of the identity and is read from the row.
#
# The results files are append-only and committed, and every row of one
# invocation carries the same `run` so a reader can take that invocation's rows
# as a group. That grouping is the whole reason the field exists, and it holds
# only while a run contributes one row per measurement: a retry, a crash and a
# restart, a second shell running the same script, or a caller that passes
# `BENCH_RUN_ID` to name a logical run each append a second row under that same
# `run`, and every one of those rows is one measurement counted twice. A mean
# taken over the group is then a mean over a number of samples nobody chose, and
# the count the reader can check does not match what was measured once.
#
# The comparison is on (run, FIELD values) rather than on the line, because a
# repeat of one measurement is rarely byte-identical to the first: the wall time
# and the token count move with the machine's load, and two lines differing in
# `wall_s` are the same measurement run twice, not two measurements. Comparing
# whole lines would let the duplicate through whenever anything but the identity
# moved, which is almost always. A row whose `run` differs is never this run's
# and is never skipped, so a re-measurement with the default clock-and-pid `run`
# is a new row beside the old one, grouped by its own run the way the reader
# groups it.
#
# Skipped, not replaced: the row already there is this run's answer to that
# measurement, and a later row would let the tail of a script rewrite a file it
# is partway through writing. The first row is what one run measured.
#
# This is a read-then-write, not a lock, so two copies of the same script running
# at once can both read the file, both find the row absent, and both append:
# two rows, the state this improves on and cannot prevent. The scripts already
# keep concurrent copies out of each other's work directories, and two
# invocations share one run name only when a caller set `*_RUN_ID` itself. A lock
# is the answer to that and is deliberately not here: it is a dependency and a
# new failure mode for a duplicate row in a file of measurements.
record_run_row() {
	# because: the row and the field names come from the caller as arguments, and
	# they reach the comparison as argv rather than interpolated into the program
	# because: a field name or a value carrying a quote would end the program
	# shellcheck disable=SC2016
	python3 -c '
import json, sys

path, row_text, *fields = sys.argv[1:]
row = json.loads(row_text)
run = row.get("run")
key = tuple(row.get(name) for name in fields)
try:
    with open(path, encoding="utf-8") as handle:
        existing = [json.loads(line) for line in handle if line.strip()]
except FileNotFoundError:
    existing = []
if any(
    other.get("run") == run and tuple(other.get(name) for name in fields) == key
    for other in existing
):
    sys.exit(0)
with open(path, "a", encoding="utf-8") as handle:
    handle.write(row_text + "\n")
' "$@"
}