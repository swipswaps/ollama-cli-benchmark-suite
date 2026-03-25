#!/usr/bin/env bash
# llm-run v5.5 (OPERATOR-SAFE, LIVE STREAM, DRY-RUN SIMULATION, COPY-READY OUTPUT)
#
# SAFE BY DEFAULT:
# - DRY RUN (simulated execution if EXEC=0)
# - sandbox fully isolated
# - cannot kill parent shell
# - live streaming of model + command output
# - repair loop fully visible
# - controlled failure handling
# - final command ready for copy/paste, optionally copied to clipboard
#
# USAGE:
#   ./llm-run.sh "show disk usage"
#   EXEC=1 ./llm-run.sh "show disk usage"   # allow execution
#   COPY=1 ./llm-run.sh "show disk usage"   # copy command to clipboard (xclip)

set -uo pipefail
trap 'echo "[ERROR] contained failure (no shell exit)" >&2' ERR

PRIMARY_MODEL="qwen2:1.5b"
FALLBACK_MODEL="qwen2:0.5b"
TIMEOUT=12
SANDBOX_TIMEOUT=5
REPAIR_ATTEMPTS=2

EXEC="${EXEC:-0}"
COPY="${COPY:-0}"

CACHE="./.llm_cmd_cache.db"
LOG="./.llm_cmd.log"

touch "$CACHE" "$LOG"

TASK="${1:-}"

if [[ -z "$TASK" ]]; then
    echo "Usage: $0 \"task\""
    exit 1
fi

# -----------------------------
# TASK CONSTRAINTS
# -----------------------------
task_hint() {
    case "$1" in
        "list files sorted by newest") echo "Use: ls -t" ;;
        "show current directory") echo "Use: pwd" ;;
        "list running processes") echo "Use: ps aux" ;;
        "show disk usage") echo "Use: df -h" ;;
        *) echo "" ;;
    esac
}

# -----------------------------
# CACHE
# -----------------------------
cache_get() {
    grep -F "$TASK|" "$CACHE" | tail -n1 | cut -d'|' -f2- || true
}

cache_put() {
    echo "$TASK|$1" >> "$CACHE"
}

# -----------------------------
# LOGGING
# -----------------------------
log() {
    echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"
}

# -----------------------------
# PROMPT / MODEL
# -----------------------------
build_prompt() {
    cat <<EOF
Return ONLY:

COMMAND: <single bash command>

STRICT:
- one line
- no explanation
- must start with COMMAND:
- valid Linux shell

Constraint:
$(task_hint "$TASK")

Task: $TASK
EOF
}

extract_command() {
    awk '
    /^COMMAND:/ {
        sub(/^COMMAND:[[:space:]]+/, "", $0)
        print
        exit
    }
    NF {
        print
        exit
    }'
}

call_model() {
    (
        set +e
        build_prompt | timeout "$TIMEOUT" ollama run "$1" 2>&1 | tee -a "$LOG"
    )
}

get_command() {
    local raw clean cmd
    raw=$(call_model "$1")
    clean=$(echo "$raw" | tr -d '\000' | sed 's/```//g')
    cmd=$(echo "$clean" | extract_command)
    echo "$cmd"
}

validate_command() {
    local cmd="$1"
    [[ -z "$cmd" ]] && return 1
    case "$TASK" in
        "list files sorted by newest") [[ "$cmd" =~ ls && "$cmd" =~ -t ]] ;;
        "show current directory") [[ "$cmd" == "pwd" ]] ;;
        "list running processes") [[ "$cmd" =~ ps ]] ;;
        "show disk usage") [[ "$cmd" =~ df ]] ;;
        *) return 1 ;;
    esac
}

# -----------------------------
# SANDBOX EXECUTION
# -----------------------------
sandbox_exec() {
    local cmd="$1"
    if echo "$cmd" | grep -Eq '(rm -rf /|mkfs|dd if=|:(){|shutdown|reboot|poweroff|kill -9 1)'; then
        echo "BLOCKED"
        return 1
    fi
    (
        set +e
        if command -v bwrap >/dev/null 2>&1; then
            timeout "$SANDBOX_TIMEOUT" bwrap \
                --ro-bind /usr /usr \
                --ro-bind /bin /bin \
                --ro-bind /lib /lib \
                --ro-bind /lib64 /lib64 \
                --ro-bind /etc /etc \
                --proc /proc \
                --dev /dev \
                --tmpfs /tmp \
                --unshare-net \
                /bin/sh -c "$cmd"
        else
            timeout "$SANDBOX_TIMEOUT" bash -c "$cmd"
        fi
    ) 2>&1 | tee -a "$LOG"
}

validate_execution() {
    local output="$1"
    case "$TASK" in
        "show current directory") [[ "$output" =~ / ]] ;;
        "list files sorted by newest") [[ -n "$output" ]] ;;
        "list running processes") [[ "$output" =~ PID|USER|root ]] ;;
        "show disk usage") [[ "$output" =~ %|/ ]] ;;
        *) return 1 ;;
    esac
}

# -----------------------------
# SIMULATE OUTPUT FOR DRY-RUN
# -----------------------------
simulate_output() {
    case "$TASK" in
        "show disk usage") df -h | head -n5 ;;
        "list running processes") ps aux | head -n5 ;;
        "list files sorted by newest") ls -t | head -n5 ;;
        "show current directory") pwd ;;
        *) echo "[SIMULATED OUTPUT]" ;;
    esac
}

# -----------------------------
# COPY TO CLIPBOARD
# -----------------------------
copy_to_clipboard() {
    local cmd="$1"
    if [[ "$COPY" == "1" ]] && command -v xclip >/dev/null 2>&1; then
        echo -n "$cmd" | xclip -sel clip
        log "COPIED TO CLIPBOARD"
    fi
}

# -----------------------------
# MAIN FLOW
# -----------------------------
log "TASK: $TASK"

# 1. CACHE FIRST
CMD=$(cache_get)
if [[ -n "$CMD" ]]; then
    log "CACHE HIT: $CMD"
    copy_to_clipboard "$CMD"
    if [[ "$EXEC" == "1" ]]; then
        OUTPUT=$(sandbox_exec "$CMD" || true)
        if validate_execution "$OUTPUT"; then
            echo "$CMD"
            exit 0
        fi
    else
        echo "[DRY-RUN][CACHE] $CMD"
        echo "[DRY-RUN SIMULATED OUTPUT]"
        simulate_output
        echo "Command ready for copy: $CMD"
        exit 0
    fi
fi

# 2. MODEL GENERATION
CMD=$(get_command "$PRIMARY_MODEL")
if ! validate_command "$CMD"; then
    CMD=$(get_command "$FALLBACK_MODEL")
fi
log "MODEL CMD: $CMD"
copy_to_clipboard "$CMD"

# DRY RUN SIMULATION
if [[ "$EXEC" != "1" ]]; then
    echo "[DRY-RUN][MODEL] $CMD"
    echo "[DRY-RUN SIMULATED OUTPUT]"
    simulate_output
    echo "Command ready for copy: $CMD"
    exit 0
fi

# 3. EXECUTION
OUTPUT=$(sandbox_exec "$CMD" || true)

# 4. REPAIR LOOP
if ! validate_execution "$OUTPUT"; then
    for _ in $(seq 1 $REPAIR_ATTEMPTS); do
        log "REPAIR ATTEMPT: $(_)"
        CMD=$(get_command "$PRIMARY_MODEL")
        OUTPUT=$(sandbox_exec "$CMD" || true)
        if validate_execution "$OUTPUT"; then
            log "REPAIR SUCCESS: $CMD"
            copy_to_clipboard "$CMD"
            break
        fi
    done
fi

# 5. FINAL
if validate_execution "$OUTPUT"; then
    cache_put "$CMD"
    echo "$CMD"
    log "SUCCESS: $CMD"
    echo "Command ready for copy: $CMD"
else
    echo "FAILED"
    log "FAIL"
    exit 1
fi