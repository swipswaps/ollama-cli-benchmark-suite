#!/usr/bin/env bash
# ollama_cli_benchmark_suite_v4.sh
#
# SELF-HEALING LLM COMMAND ENGINE
#
# NEW:
# - command cache (learns correct commands)
# - auto-repair loop (feeds failure back to model)
# - execution-first reuse (skip model if known-good)
# - stronger sandbox filtering
# - deterministic scoring pipeline

set -euo pipefail

# -----------------------------
# CONFIG
# -----------------------------

PRIMARY_MODEL="qwen2:1.5b"
FALLBACK_MODEL="qwen2:0.5b"

PROMPTS=(
    "list files sorted by newest"
    "show current directory"
    "list running processes"
    "show disk usage"
)

ITERATIONS=2
TIMEOUT=15
SANDBOX_TIMEOUT=5
REPAIR_ATTEMPTS=1

OUTDIR="ollama_bench_$(date +%s)"
mkdir -p "$OUTDIR"

CSV="$OUTDIR/results.csv"
LOG="$OUTDIR/raw.log"
CACHE="$OUTDIR/cache.db"

touch "$CACHE"

echo "model,task,iter,latency,valid,exec_ok,score,source,command" > "$CSV"

# -----------------------------
# MODEL MGMT
# -----------------------------

have_model() {
    ollama list | awk '{print $1}' | grep -Fxq "$1"
}

ensure_model() {
    have_model "$1" || ollama pull "$1"
}

# -----------------------------
# CACHE
# -----------------------------

cache_get() {
    local task="$1"
    grep -F "$task|" "$CACHE" | tail -n1 | cut -d'|' -f2-
}

cache_put() {
    local task="$1"
    local cmd="$2"
    echo "$task|$cmd" >> "$CACHE"
}

# -----------------------------
# NORMALIZATION
# -----------------------------

normalize_output() {
    sed -E '
        s/```[a-zA-Z]*//g;
        s/```//g;
        s/[[:cntrl:]]//g;
        s/^[[:space:]]+//;
        s/[[:space:]]+$//;
        s/[[:space:]]+/ /g;
    '
}

extract_command() {
    sed -nE 's/^COMMAND:[[:space:]]+(.+)$/\1/p'
}

# -----------------------------
# VALIDATION
# -----------------------------

validate_command() {
    local task="$1"
    local cmd="$2"

    [[ -z "$cmd" ]] && { echo "no"; return; }

    case "$task" in
        "list files sorted by newest")
            [[ "$cmd" =~ ls ]] && [[ "$cmd" =~ -t ]] && echo "yes" || echo "no"
            ;;
        "show current directory")
            [[ "$cmd" == "pwd" ]] && echo "yes" || echo "no"
            ;;
        "list running processes")
            [[ "$cmd" =~ ps ]] && echo "yes" || echo "no"
            ;;
        "show disk usage")
            [[ "$cmd" =~ df ]] && echo "yes" || echo "no"
            ;;
        *)
            echo "no"
            ;;
    esac
}

# -----------------------------
# SANDBOX
# -----------------------------

sandbox_exec() {
    local cmd="$1"

    # denylist
    if echo "$cmd" | grep -Eq '(rm -rf /|mkfs|dd if=|:(){|shutdown|reboot|poweroff|kill -9 1)'; then
        echo "BLOCKED"
        return 1
    fi

    if command -v bwrap >/dev/null 2>&1; then
        timeout "$SANDBOX_TIMEOUT" bwrap \
            --ro-bind /usr /usr \
            --ro-bind /bin /bin \
            --dev /dev \
            --proc /proc \
            --tmpfs /tmp \
            --unshare-net \
            --die-with-parent \
            /bin/sh -c "$cmd" 2>&1
        return $?
    fi

    # fallback
    timeout "$SANDBOX_TIMEOUT" bash -c "$cmd" 2>&1
}

# -----------------------------
# EXEC VALIDATION
# -----------------------------

validate_execution() {
    local task="$1"
    local output="$2"

    case "$task" in
        "show current directory")
            [[ "$output" =~ / ]] && return 0 ;;
        "list files sorted by newest")
            [[ -n "$output" ]] && return 0 ;;
        "list running processes")
            [[ "$output" =~ PID|root|USER ]] && return 0 ;;
        "show disk usage")
            [[ "$output" =~ %|/ ]] && return 0 ;;
    esac

    return 1
}

# -----------------------------
# PROMPTS
# -----------------------------

build_prompt() {
    local task="$1"
    cat <<EOF
COMMAND: <single bash command>

STRICT:
- one line
- no explanation
- no markdown
- must start with COMMAND:

Task: $task
EOF
}

build_repair_prompt() {
    local task="$1"
    local bad_cmd="$2"
    local error="$3"

    cat <<EOF
The previous command failed.

Task: $task

Bad command:
$bad_cmd

Error/output:
$error

Return corrected command.

FORMAT:
COMMAND: <fixed bash command>
EOF
}

# -----------------------------
# MODEL CALL
# -----------------------------

call_model() {
    local model="$1"
    local prompt="$2"

    echo "$prompt" | timeout "$TIMEOUT" ollama run "$model" 2>/dev/null || true
}

get_command() {
    local model="$1"
    local task="$2"

    local raw clean cmd

    raw=$(call_model "$model" "$(build_prompt "$task")")
    clean=$(echo "$raw" | normalize_output)
    cmd=$(echo "$clean" | extract_command)

    echo "$cmd"
}

repair_command() {
    local model="$1"
    local task="$2"
    local bad_cmd="$3"
    local error="$4"

    local raw clean cmd

    raw=$(call_model "$model" "$(build_repair_prompt "$task" "$bad_cmd" "$error")")
    clean=$(echo "$raw" | normalize_output)
    cmd=$(echo "$clean" | extract_command)

    echo "$cmd"
}

# -----------------------------
# MAIN
# -----------------------------

echo "[INFO] Starting v4 self-healing engine..."

ensure_model "$PRIMARY_MODEL"
ensure_model "$FALLBACK_MODEL"

for task in "${PROMPTS[@]}"; do
    for i in $(seq 1 $ITERATIONS); do

        echo "[RUN] $task | iter=$i"

        START=$(date +%s.%N)

        SOURCE="model"
        CMD=""

        # 1. CACHE FIRST
        CMD=$(cache_get "$task" || true)
        if [[ -n "$CMD" ]]; then
            SOURCE="cache"
        else
            CMD=$(get_command "$PRIMARY_MODEL" "$task")

            if [[ "$(validate_command "$task" "$CMD")" != "yes" ]]; then
                CMD=$(get_command "$FALLBACK_MODEL" "$task")
            fi
        fi

        VALID=$(validate_command "$task" "$CMD")
        EXEC_OK="no"
        OUTPUT=""

        if [[ "$VALID" == "yes" ]]; then
            OUTPUT=$(sandbox_exec "$CMD" || true)

            if validate_execution "$task" "$OUTPUT"; then
                EXEC_OK="yes"
            else
                # REPAIR LOOP
                for _ in $(seq 1 $REPAIR_ATTEMPTS); do
                    FIXED=$(repair_command "$PRIMARY_MODEL" "$task" "$CMD" "$OUTPUT")

                    if [[ "$(validate_command "$task" "$FIXED")" == "yes" ]]; then
                        OUTPUT=$(sandbox_exec "$FIXED" || true)

                        if validate_execution "$task" "$OUTPUT"; then
                            CMD="$FIXED"
                            EXEC_OK="yes"
                            SOURCE="repair"
                            break
                        fi
                    fi
                done
            fi
        fi

        END=$(date +%s.%N)
        LATENCY=$(awk "BEGIN {print $END - $START}")

        # scoring
        SCORE=0
        [[ "$VALID" == "yes" ]] && SCORE=$((SCORE+1))
        [[ "$EXEC_OK" == "yes" ]] && SCORE=$((SCORE+2))

        # cache good results
        if [[ "$EXEC_OK" == "yes" ]]; then
            cache_put "$task" "$CMD"
        fi

        echo "\"$task\",$i,$LATENCY,$VALID,$EXEC_OK,$SCORE,$SOURCE,\"$CMD\"" >> "$CSV"

        {
            echo "TASK: $task"
            echo "CMD: $CMD"
            echo "SOURCE: $SOURCE"
            echo "VALID: $VALID"
            echo "EXEC_OK: $EXEC_OK"
            echo "OUTPUT:"
            echo "$OUTPUT"
            echo "----------------------------------"
        } >> "$LOG"

    done
done

echo "[DONE] Results: $CSV"
echo "[DONE] Cache: $CACHE"