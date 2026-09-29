#!/bin/sh
# Run a Harbor benchmark for microagent and opencode, sequentially, and print a
# per-task summary. One harness at a time on purpose: two 23-task jobs at once
# measured the machine's load, not the harnesses (see BENCHMARK.md).
#
#   bench/harbor.sh tb2                     # Terminal-Bench 2, stride sample
#   bench/harbor.sh swebench                # SWE-bench Verified, stride sample
#   bench/harbor.sh tb2 microagent          # one harness only
#
# Environment:
#   MICROAGENT_API_KEY / MICROAGENT_BASE_URL   provider (default OpenRouter)
#   MICROAGENT_MAX_TOKENS                      raise only if the balance allows
#   PROVIDER=nvidia                            use NVIDIA NIM + the opencode
#                                              provider overlay it needs
#   TASKS="a b c"                              override the task list
#   JOBS_DIR=/tmp/harbor-jobs                  where results land
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
bench=${1:-tb2}
shift 2>/dev/null || true
harnesses=${*:-"microagent opencode"}
jobs_dir=${JOBS_DIR:-/tmp/harbor-jobs}
jobs=${HARBOR_JOBS:-4}
harbor=${HARBOR:-harbor}
python=${PYTHON:-python3}

case "$bench" in
tb2)
	dataset=terminal-bench@2.0
	default_tasks=$(cat "$root/bench/tb2-sample.txt" 2>/dev/null || true)
	agent_timeout=880
	budget=790
	;;
swebench)
	dataset=swebench-verified@1.0
	default_tasks=$(cat "$root/bench/swe-sample.txt" 2>/dev/null || true)
	agent_timeout=2900
	budget=2700
	;;
*)
	echo "unknown benchmark '$bench': use tb2 or swebench" >&2
	exit 2
	;;
esac

tasks=${TASKS:-$default_tasks}
[ -z "$tasks" ] && { echo "no tasks: set TASKS or provide bench/$bench-sample.txt" >&2; exit 2; }

include=""
for task in $tasks; do include="$include -i $task"; done

# harbor refuses egress to a host it cannot infer from the model name, and a
# custom base url is exactly that: a trial then hangs until its timeout.
allow=""
model_micro=deepseek/deepseek-v4-flash
model_open=openrouter/deepseek/deepseek-v4-flash
extra_open=""
if [ "${PROVIDER:-openrouter}" = "nvidia" ]; then
	model_micro=deepseek-ai/deepseek-v4.1-flash
	model_open=nvidia/deepseek-ai/deepseek-v4.1-flash
	allow="--allow-agent-host integrate.api.nvidia.com"
	# The overlay is JSON, so the quotes are part of the argument harbor is
	# meant to receive and word splitting is how the arguments reach it.
	# shellcheck disable=SC2089
	extra_open="--ak opencode_config={\"provider\":{\"nvidia\":{\"npm\":\"@ai-sdk/openai-compatible\",\"name\":\"NVIDIA\",\"options\":{\"baseURL\":\"${MICROAGENT_BASE_URL:-https://integrate.api.nvidia.com/v1}\",\"apiKey\":\"{env:OPENAI_API_KEY}\"},\"models\":{\"deepseek-ai/deepseek-v4.1-flash\":{}}}}} --ae OPENAI_API_KEY=${MICROAGENT_API_KEY:-}"
fi

# A job name no earlier run already holds, printed on stdout.
#
# The name is a directory under $jobs_dir, and harbor writes one trial
# directory per task into it. Two runs that pick the same name therefore share
# one directory: the second run's trials land beside the first run's, and the
# summary printed at the end of the second is a mean over the two runs' trials
# as if they were one, with a trial count nobody can explain. A rerun minutes
# after a run that died, or a rerun of the same script from a second shell, is
# the ordinary way to get there, so the name carries seconds and the pid, and
# a name whose directory is still there is given a counter rather than reused.
#
# A stale directory is left where it is: it is the record of a run somebody may
# still want, and this script is not the thing that decides which runs are
# worth keeping.
new_job() {
	base="$1-$(date +%H%M%S)-$$"
	n=0
	while [ -e "$jobs_dir/$base" ] && [ "$n" -lt 100 ]; do
		n=$((n + 1))
		base="$1-$(date +%H%M%S)-$$-$n"
	done
	printf '%s' "$base"
}

for harness in $harnesses; do
	job=$(new_job "$harness-$bench")
	echo "=== $job: $bench, ${jobs} at a time"
	case "$harness" in
	microagent)
		# shellcheck disable=SC2086
		PYTHONPATH="$root/integrations/harbor" \
			MICROAGENT_AGENT_TIMEOUT_SEC=$agent_timeout \
			MICROAGENT_BUDGET_SECONDS=$budget \
			MICROAGENT_MAX_TURNS=150 \
			$harbor run -d "$dataset" $include $allow \
			-a microagent_agent:Microagent -m "$model_micro" \
			--jobs-dir "$jobs_dir" -n "$jobs" --job-name "$job" 2>&1 | tail -6
		;;
	opencode)
		# shellcheck disable=SC2086,SC2089,SC2090
		$harbor run -d "$dataset" $include $allow \
			-a opencode -m "$model_open" $extra_open \
			--jobs-dir "$jobs_dir" -n "$jobs" --job-name "$job" 2>&1 | tail -6
		;;
	*)
		echo "unknown harness '$harness'" >&2
		exit 2
		;;
	esac
	$python "$root/integrations/harbor/summarize.py" "$jobs_dir/$job" 2>/dev/null | tail -25
done
