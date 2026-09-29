#!/bin/sh
# Run a Harbor benchmark for microagent and opencode, sequentially, and print a
# per-task summary. One harness at a time on purpose: two 23-task jobs at once
# measured the machine's load, not the harnesses (see docs/benchmark.md).
#
#   bench/harbor.sh tb4                     # Terminal-Bench 4.0, stride sample
#   bench/harbor.sh polyglot                # Aider polyglot, stride sample (the fast one)
#   bench/harbor.sh deepswe                 # DeepSWE 1.1, stride sample
#   bench/harbor.sh tb2                     # Terminal-Bench 2, stride sample
#   bench/harbor.sh swebench                # SWE-bench Verified, stride sample
#   bench/harbor.sh tb4 microagent          # one harness only (microagent, opencode, kimi)
#
# Environment:
#   MICROAGENT_API_KEY / MICROAGENT_BASE_URL   provider (default OpenRouter)
#   MICROAGENT_MAX_TOKENS                      raise only if the balance allows
#   PROVIDER=nvidia|deepseek                   use NVIDIA NIM or DeepSeek's own API + the opencode
#                                              provider overlay it needs
#   TASKS="a b c"                              override the task list
#   JOBS_DIR=~/harbor-jobs                     where results land
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
bench=${1:-tb2}
shift 2>/dev/null || true
harnesses=${*:-"microagent opencode"}
# A job directory holds every container log and agent transcript the run
# produced, and the scores in docs/benchmark.md are read out of it, so it is not
# scratch: it lands beside the home directory the adapter's venv goes in, on
# disk rather than on the tmpfs a /tmp is on a machine that keeps one.
jobs_dir=${JOBS_DIR:-$HOME/harbor-jobs}
jobs=${HARBOR_JOBS:-4}
harbor=${HARBOR:-harbor}
python=${PYTHON:-python3}

# Per benchmark: the dataset, the prefix its task ids carry, the in-container
# process cap and working budget in seconds, and whether the task gives the agent
# no network. The registry's newer datasets namespace their task ids
# (`terminal-bench/<name>`, `datacurve/<name>`), and `-i <bare name>` matches
# nothing in them, so the sample files keep bare names and the prefix is added
# below.
#
# Terminal-Bench 4.0 gives every task an 8 hour agent timeout, and a harness run
# to that would spend hours on one task it cannot solve. `agent_timeout_multiplier`
# scales that limit for both harnesses alike, to 3600 s (0.125 of 28800 s). The
# in-container cap sits under it, as the TB2 and SWE-bench figures do.
id_prefix=""
agent_timeout_multiplier=""
agent_network_closed=""
case "$bench" in
tb2)
	dataset=terminal-bench@2.0
	default_tasks=$(cat "$root/bench/tb2-sample.txt" 2>/dev/null || true)
	agent_timeout=880
	budget=790
	;;
tb4)
	dataset=terminal-bench/terminal-bench@4.0.0
	id_prefix=terminal-bench/
	default_tasks=$(cat "$root/bench/tb4-sample.txt" 2>/dev/null || true)
	agent_timeout_multiplier=0.125
	agent_timeout=3480
	budget=3100
	;;
polyglot)
	# Small single-file exercises in six languages, the shortest tasks here: a trial is minutes,
	# where a Terminal-Bench 4.0 task can use its whole hour. Every task allows 1800 s, which the
	# multiplier halves for both harnesses; the exercises a model can do finish long before it.
	dataset=aider/aider-polyglot
	id_prefix=aider/
	default_tasks=$(cat "$root/bench/polyglot-sample.txt" 2>/dev/null || true)
	agent_timeout_multiplier=0.5
	agent_timeout=870
	budget=500
	;;
deepswe)
	dataset=datacurve/deep-swe-1-1
	id_prefix=datacurve/
	default_tasks=$(cat "$root/bench/deepswe-sample.txt" 2>/dev/null || true)
	agent_timeout=5000
	budget=4600
	agent_network_closed=1
	;;
swebench)
	dataset=swebench-verified@1.0
	default_tasks=$(cat "$root/bench/swe-sample.txt" 2>/dev/null || true)
	agent_timeout=2900
	budget=2700
	;;
*)
	echo "unknown benchmark '$bench': use tb2, tb4, polyglot, deepswe or swebench" >&2
	exit 2
	;;
esac

tasks=${TASKS:-$default_tasks}
[ -z "$tasks" ] && { echo "no tasks: set TASKS or provide bench/$bench-sample.txt" >&2; exit 2; }

include=""
for task in $tasks; do include="$include -i $id_prefix$task"; done

# harbor refuses egress to a host it cannot infer from the model name, and a
# custom base url is exactly that: a trial then hangs until its timeout.
allow_host=""
if [ -n "$agent_network_closed" ]; then
	# The agent has no network at all here, so the provider is the one host it is
	# let reach: the base url's, less scheme, path and port.
	allow_host=${MICROAGENT_BASE_URL:-https://openrouter.ai/api/v1}
	allow_host=${allow_host#*://}
	allow_host=${allow_host%%/*}
	allow_host=${allow_host%%:*}
fi
model_micro=deepseek/deepseek-v4-flash
model_open=openrouter/deepseek/deepseek-v4-flash
# The endpoint a provider other than the default serves, and the name opencode
# files it under. Empty for OpenRouter, which every harness already reaches.
provider_url=""
opencode_provider=""
opencode_name=""
opencode_model=""
key=""
case "${PROVIDER:-openrouter}" in
openrouter) ;;
nvidia)
	model_micro=deepseek-ai/deepseek-v4.1-flash
	model_open=nvidia/deepseek-ai/deepseek-v4.1-flash
	allow_host=integrate.api.nvidia.com
	provider_url=${MICROAGENT_BASE_URL:-https://integrate.api.nvidia.com/v1}
	opencode_provider=nvidia
	opencode_name=NVIDIA
	opencode_model=deepseek-ai/deepseek-v4.1-flash
	;;
deepseek)
	# DeepSeek's own API, which names V4.1 Flash `deepseek-flash`.
	model_micro=deepseek-flash
	model_open=deepseek/deepseek-flash
	allow_host=api.deepseek.com
	provider_url=${MICROAGENT_BASE_URL:-https://api.deepseek.com/v1}
	opencode_provider=deepseek
	opencode_name=DeepSeek
	opencode_model=deepseek-flash
	;;
*)
	echo "unknown PROVIDER '$PROVIDER': use openrouter, nvidia or deepseek" >&2
	exit 2
	;;
esac
# The window Kimi Code is told the model has; V4.1 Flash's is a million tokens.
kimi_context_size=1048576
opencode_config=""
if [ -n "$provider_url" ]; then
	# An empty key is refused here: harbor passes it into the container either
	# way, and the trial then runs to its timeout against a provider with no
	# credentials, which reads as a slow task rather than as a missing key.
	key=${MICROAGENT_API_KEY:-}
	if [ -z "$key" ]; then
		echo "PROVIDER=${PROVIDER} needs a key in MICROAGENT_API_KEY" >&2
		exit 2
	fi
	# The microagent adapter reads the endpoint from the environment.
	export MICROAGENT_BASE_URL="$provider_url"
	# Assembled from single-quoted pieces around the values that vary, so
	# the quotes in the JSON are the quotes of an argument. Written with
	# backslashes inside one string, they reach harbor as literal backslashes
	# whenever the string is expanded unquoted.
	opencode_config='{"provider":{"'$opencode_provider'":{"npm":"@ai-sdk/openai-compatible","name":"'$opencode_name'","options":{"baseURL":"'$provider_url'","apiKey":"{env:OPENAI_API_KEY}"},"models":{"'$opencode_model'":{}}}}}'
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
	# The flags both harnesses share, held as positional parameters rather
	# than in a string the shell splits and dequotes on the way in. The
	# harness list is already expanded by the loop, so nothing above reads $@
	# after this point.
	set --
	if [ -n "$allow_host" ]; then
		set -- "$@" --allow-agent-host "$allow_host"
	fi
	if [ -n "$agent_timeout_multiplier" ]; then
		set -- "$@" --agent-timeout-multiplier "$agent_timeout_multiplier"
	fi
	case "$harness" in
	microagent)
		# because: $include is " -i task" per task, built above, and has to
		# reach harbor as that many words rather than as one argument
		# shellcheck disable=SC2086
		PYTHONPATH="$root/integrations/harbor" \
			MICROAGENT_AGENT_TIMEOUT_SEC=$agent_timeout \
			MICROAGENT_BUDGET_SECONDS=$budget \
			MICROAGENT_MAX_TURNS=150 \
			$harbor run -d "$dataset" $include "$@" \
			-a microagent_agent:Microagent -m "$model_micro" \
			--jobs-dir "$jobs_dir" -n "$jobs" --job-name "$job" 2>&1 | tail -6
		;;
	opencode)
		set -- "$@" -a opencode -m "$model_open"
		if [ -n "$opencode_config" ]; then
			set -- "$@" --ak "opencode_config=$opencode_config" --ae "OPENAI_API_KEY=$key"
		fi
		set -- "$@" --jobs-dir "$jobs_dir" -n "$jobs" --job-name "$job"
		# because: the same $include as the microagent arm above, split the same way
		# shellcheck disable=SC2086
		$harbor run -d "$dataset" $include "$@" 2>&1 | tail -6
		;;
	kimi)
		# Kimi Code takes any OpenAI-compatible endpoint from these variables, so
		# it is only run against a provider this script has an endpoint and a key
		# for.
		if [ -z "$provider_url" ]; then
			echo "the kimi arm needs PROVIDER=deepseek or PROVIDER=nvidia" >&2
			exit 2
		fi
		set -- "$@" -a kimi-code -m "$model_micro" \
			--ae "KIMI_MODEL_BASE_URL=$provider_url" --ae "KIMI_MODEL_API_KEY=$key" \
			--ae "KIMI_MODEL_MAX_CONTEXT_SIZE=$kimi_context_size"
		set -- "$@" --jobs-dir "$jobs_dir" -n "$jobs" --job-name "$job"
		# because: the same $include as the microagent arm above, split the same way
		# shellcheck disable=SC2086
		$harbor run -d "$dataset" $include "$@" 2>&1 | tail -6
		;;
	*)
		echo "unknown harness '$harness'" >&2
		exit 2
		;;
	esac
	$python "$root/integrations/harbor/summarize.py" "$jobs_dir/$job" 2>/dev/null | tail -25
done
