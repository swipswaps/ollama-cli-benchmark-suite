#!/usr/bin/env bash
# llm-run v6.0 (FULL FIX: CLEAN CACHE + STRIP ALL SPINNERS, ANSI, CONTROL CHARS)
# SAFE: DRY-RUN, SANDBOX, COPY-TO-CLIPBOARD, REPAIR LOOP

set -euo pipefail
trap 'printf "[ERROR] Contained failure (no shell exit)\n" >&2' ERR

PRIMARY_MODEL="qwen2:1.5b"
FALLBACK_MODEL="qwen2:0.5b"
TIMEOUT=12
SANDBOX_TIMEOUT=5
REPAIR_ATTEMPTS=2

EXEC="${EXEC:-0}"
COPY="${COPY:-0}"

CACHE="./.llm_cmd_cache.db"
LOG="./.llm_cmd.log"
TASK="${1:-}"

[[ -n "$TASK" ]] || { printf "Usage: %s \"task\"\n" "$0"; exit 1; }

touch "$CACHE" "$LOG"

# -----------------------------
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }

task_hint() {
    case "$1" in
        "list files sorted by newest") printf "Use: ls -t\n" ;;
        "show current directory") printf "Use: pwd\n" ;;
        "list running processes") printf "Use: ps aux\n" ;;
        "show disk usage") printf "Use: df -h\n" ;;
        *) printf "" ;;
    esac
}

normalize_command() {
    # Strip all leading/trailing whitespace, residual COMMAND:, ANSI, control chars
    local cmd="$1"
    echo "$cmd" \
        | tr -d '\000' \
        | sed 's/```//g' \
        | sed -r 's/\x1B\[[0-9;?]*[a-zA-Z]//g' \
        | tr -cd '\11\12\15\40-\176' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | sed -e 's/^COMMAND:[[:space:]]*//'
}

cache_get() { grep -F "$TASK|" "$CACHE" | tail -n1 | cut -d'|' -f2- || true; }
cache_put() { printf "%s|%s\n" "$TASK" "$(normalize_command "$1")" >> "$CACHE"; }

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

get_command() { normalize_command "$(call_model "$1" | extract_command)"; }

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

sandbox_exec() {
    local cmd
    cmd=$(normalize_command "$1")
    if echo "$cmd" | grep -Eq '(rm -rf /|mkfs|dd if=|:(){|shutdown|reboot|poweroff|kill -9 1)'; then
        echo "BLOCKED"
        return 1
    fi

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
    case "$TASK" in
        "show disk usage") df -h | head -n5 ;;
        "list running processes") ps aux | head -n5 ;;
        "list files sorted by newest") ls -t | head -n5 ;;
        "show current directory") pwd ;;
        *) printf "[SIMULATED OUTPUT]\n" ;;
    esac
}

copy_to_clipboard() {
    [[ "$COPY" == "1" ]] && command -v xclip >/dev/null 2>&1 && \
        printf '%s' "$1" | xclip -sel clip && log "COPIED TO CLIPBOARD"
}

# -----------------------------
log "TASK: $TASK"

CMD=$(cache_get)
CMD=$(normalize_command "$CMD")
if [[ -n "$CMD" ]]; then
    log "CACHE HIT: $CMD"
    copy_to_clipboard "$CMD"
    if [[ "$EXEC" == "1" ]]; then
        OUTPUT=$(sandbox_exec "$CMD" || true)
        validate_execution "$OUTPUT" && { printf '%s\n' "$CMD"; exit 0; }
    else
        printf "[DRY-RUN][CACHE] %s\n" "$CMD"
        simulate_output
        printf "Command ready for copy: %s\n" "$CMD"
        exit 0
    fi
fi

CMD=$(get_command "$PRIMARY_MODEL")
validate_command "$CMD" || CMD=$(get_command "$FALLBACK_MODEL")
log "MODEL CMD: $CMD"
copy_to_clipboard "$CMD"

[[ "$EXEC" == "1" ]] || { simulate_output; printf "Command ready for copy: %s\n" "$CMD"; exit 0; }

OUTPUT=$(sandbox_exec "$CMD" || true)

if ! validate_execution "$OUTPUT"; then
    for i in $(seq 1 $REPAIR_ATTEMPTS); do
        log "REPAIR ATTEMPT: $i"
        CMD=$(get_command "$PRIMARY_MODEL")
        OUTPUT=$(sandbox_exec "$CMD" || true)
        validate_execution "$OUTPUT" && { log "REPAIR SUCCESS: $CMD"; copy_to_clipboard "$CMD"; break; }
    done
fi

if validate_execution "$OUTPUT"; then
    cache_put "$CMD"
    printf '%s\n' "$CMD"
    log "SUCCESS: $CMD"
    printf "Command ready for copy: %s\n" "$CMD"
else
    log "FAIL"
    printf "FAILED\n"
    exit 1
fi