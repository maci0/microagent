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
	extra_open="--ak opencode_config={\"provider\":{\"nvidia\":{\"npm\":\"@ai-sdk/openai-compatible\",\"name\":\"NVIDIA\",\"options\":{\"baseURL\":\"${MICROAGENT_BASE_URL:-https://integrate.api.nvidia.com/v1}\",\"apiKey\":\"{env:OPENAI_API_KEY}\"},\"models\":{\"deepseek-ai/deepseek-v4.1-flash\":{}}}}} --ae OPENAI_API_KEY=${MICROAGENT_API_KEY:-}"
fi

for harness in $harnesses; do
	job="$harness-$bench-$(date +%H%M)"
	echo "=== $job: $bench, ${jobs} at a time"
	case "$harness" in
	microagent)
		PYTHONPATH="$root/integrations/harbor" \
			MICROAGENT_AGENT_TIMEOUT_SEC=$agent_timeout \
			MICROAGENT_BUDGET_SECONDS=$budget \
			MICROAGENT_MAX_TURNS=150 \
			$harbor run -d "$dataset" $include $allow \
			-a microagent_agent:Microagent -m "$model_micro" \
			--jobs-dir "$jobs_dir" -n "$jobs" --job-name "$job" 2>&1 | tail -6
		;;
	opencode)
		# shellcheck disable=SC2086
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
