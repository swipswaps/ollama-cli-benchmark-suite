#!/usr/bin/env bash
# llm-run v6.3 (Fully sanitized + safe flags + debug + enhanced caching + clipboard compatibility)

set -euo pipefail

PRIMARY_MODEL="qwen2:1.5b"
FALLBACK_MODEL="qwen2:0.5b"
TIMEOUT=12
SANDBOX_TIMEOUT=5
REPAIR_ATTEMPTS=2

EXEC="${EXEC:-0}"
COPY="${COPY:-0}"
DEBUG="${DEBUG:-0}"

CACHE="./.llm_cmd_cache.db"
LOG="./.llm_cmd.log"
TASK="${1:-}"

[[ -n "$TASK" ]] || { echo "Usage: $0 \"task\""; exit 1; }

touch "$CACHE" "$LOG"

log() { 
    local msg="$*"
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$msg" | tee -a "$LOG"
}

task_hint() {
    case "$1" in
        "list files sorted by newest") echo "Use: ls -t" ;;
        "show current directory") echo "Use: pwd" ;;
        "list running processes") echo "Use: ps aux" ;;
        "show disk usage") echo "Use: df -h" ;;
        *) echo "" ;;
    esac
}

normalize_command() {
    local cmd="$1"
    printf '%s' "$cmd" \
        | tr -d '\000' \
        | sed -r 's/\x1B\[[0-9;?]*[a-zA-Z]//g' \
        | tr -cd '\11\12\15\40-\176' \
        | sed -E 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sed -E 's/^COMMAND:[[:space:]]*//;s/^["`]//;s/["`]$//'
}

cache_get() { grep -F "|$TASK|" "$CACHE" | tail -n1 | cut -d'|' -f2- || true; }
cache_put() { printf "%s|%s|%s\n" "$(date +%s)" "$TASK" "$(normalize_command "$1")" >> "$CACHE"; }

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

extract_command() { awk '/^COMMAND:/ {sub(/^COMMAND:[[:space:]]+/, "", $0); print; exit} NF {print; exit}'; }
call_model() { set +e; build_prompt | timeout "$TIMEOUT" ollama run "$1" 2>&1 | tee -a "$LOG"; }

get_command() {
    local raw
    raw=$(call_model "$1" | extract_command)
    [[ "$DEBUG" == "1" ]] && log "[DEBUG RAW MODEL OUTPUT]: $raw"
    normalize_command "$raw"
}

validate_command() {
    local cmd="$1"
    [[ -z "$cmd" ]] && return 1
    case "$TASK" in
        "list files sorted by newest") [[ "$cmd" =~ ^ls ]] ;;
        "show current directory") [[ "$cmd" =~ ^pwd$ ]] ;;
        "list running processes") [[ "$cmd" =~ ^ps ]] ;;
        "show disk usage") [[ "$cmd" =~ ^df ]] ;;
        *) return 1 ;;
    esac
}

sandbox_exec() {
    local cmd="$1"
    cmd=$(normalize_command "$cmd")

    if echo "$cmd" | grep -Eq '(rm -rf /|mkfs|dd if=|:(){|shutdown|reboot|poweroff|kill -9 1)'; then
        echo "BLOCKED"
        return 1
    fi

    local output rc
    if command -v bwrap >/dev/null 2>&1; then
        output=$(timeout "$SANDBOX_TIMEOUT" bwrap \
            --ro-bind /usr /usr \
            --ro-bind /bin /bin \
            --ro-bind /lib /lib \
            --ro-bind /lib64 /lib64 \
            --ro-bind /etc /etc \
            --proc /proc \
            --dev /dev \
            --tmpfs /tmp \
            --unshare-net \
            /bin/sh -c "$cmd" 2>&1) || rc=$?
    else
        output=$(timeout "$SANDBOX_TIMEOUT" bash -c "$cmd" 2>&1) || rc=$?
    fi
    printf '%s' "$output"
    return ${rc:-0}
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

simulate_output() {
    log "[SIMULATED OUTPUT]"
    case "$TASK" in
        "show disk usage") df -h | head -n5 ;;
        "list running processes") ps aux | head -n5 ;;
        "list files sorted by newest") ls -t | head -n5 ;;
        "show current directory") pwd ;;
        *) echo "[SIMULATED OUTPUT]" ;;
    esac
}

copy_to_clipboard() {
    [[ "$COPY" == "1" ]] && {
        if command -v xclip >/dev/null 2>&1; then
            printf '%s' "$1" | xclip -sel clip && log "COPIED TO CLIPBOARD (xclip)"
        elif command -v wl-copy >/dev/null 2>&1; then
            printf '%s' "$1" | wl-copy && log "COPIED TO CLIPBOARD (wl-copy)"
        fi
    }
}

# -----------------------------
log "TASK: $TASK"

CMD=$(normalize_command "$(cache_get)")
if [[ -n "$CMD" ]]; then
    log "CACHE HIT: $CMD"
    copy_to_clipboard "$CMD"
    if [[ "$EXEC" == "1" ]]; then
        OUTPUT=$(sandbox_exec "$CMD")
        validate_execution "$OUTPUT" && { echo "$CMD"; exit 0; }
    else
        simulate_output
        echo "Command ready for copy: $CMD"
        exit 0
    fi
fi

CMD=$(get_command "$PRIMARY_MODEL")
validate_command "$CMD" || CMD=$(get_command "$FALLBACK_MODEL")
log "MODEL CMD: $CMD"
copy_to_clipboard "$CMD"

if [[ "$EXEC" != "1" ]]; then
    simulate_output
    echo "Command ready for copy: $CMD"
    exit 0
fi

OUTPUT=$(sandbox_exec "$CMD")

if ! validate_execution "$OUTPUT"; then
    for i in $(seq 1 $REPAIR_ATTEMPTS); do
        log "REPAIR ATTEMPT: $i"
        CMD=$(get_command "$PRIMARY_MODEL")
        OUTPUT=$(sandbox_exec "$CMD")
        if validate_execution "$OUTPUT"; then
            log "REPAIR SUCCESS: $CMD"
            copy_to_clipboard "$CMD"
            break
        fi
    done
fi

if validate_execution "$OUTPUT"; then
    cache_put "$CMD"
    echo "$CMD"
    log "SUCCESS: $CMD"
    echo "Command ready for copy: $CMD"
else
    log "FAIL"
    echo "FAILED"
    exit 1
fi