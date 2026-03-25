#!/usr/bin/env bash
# ollama_cli_benchmark_suite.sh (ENFORCED + HARDENED)

set -euo pipefail

# -----------------------------
# CONFIG (BASED ON REAL RESULTS)
# -----------------------------

MODELS=(
    "qwen2:0.5b"
    "qwen2:1.5b"
    "llama3.2:3b"
)

PROMPTS=(
    "list files sorted by newest"
    "show current directory"
    "list running processes"
    "show disk usage"
)

ITERATIONS=2
TIMEOUT=20

OUTDIR="ollama_bench_$(date +%s)"
mkdir -p "$OUTDIR"

CSV="$OUTDIR/results.csv"
LOG="$OUTDIR/raw.log"

echo "model,prompt,iteration,latency_seconds,valid,reason,output" > "$CSV"

# -----------------------------
# MODEL MGMT
# -----------------------------

have_model() {
    local model="$1"
    ollama list | awk '{print $1}' | grep -Fxq "$model"
}

ensure_model() {
    local model="$1"

    if have_model "$model"; then
        echo "[INFO] Model present: $model"
    else
        echo "[INFO] Pulling model: $model"
        ollama pull "$model"
    fi
}

warmup_model() {
    local model="$1"
    echo "[INFO] Warming up $model"
    echo "ping" | timeout 10 ollama run "$model" >/dev/null 2>&1 || true
}

# -----------------------------
# OUTPUT NORMALIZATION
# -----------------------------

normalize_output() {
    sed -E '
        s/```[a-zA-Z]*//g;
        s/```//g;
        s/^[[:space:]]+//;
        s/[[:space:]]+$//;
        s/[[:space:]]+/ /g;
    '
}

extract_command() {
    sed -nE 's/^COMMAND:[[:space:]]+(.+)$/\1/p'
}

# -----------------------------
# SEMANTIC VALIDATION
# -----------------------------

validate_command() {
    local task="$1"
    local cmd="$2"

    # empty check
    [[ -z "$cmd" ]] && { echo "no|empty"; return; }

    case "$task" in
        "list files sorted by newest")
            [[ "$cmd" =~ ls ]] && [[ "$cmd" =~ -t ]] && {
                echo "yes|ok"; return;
            }
            echo "no|not_ls_sorted"
            ;;

        "show current directory")
            [[ "$cmd" == "pwd" ]] && {
                echo "yes|ok"; return;
            }
            echo "no|not_pwd"
            ;;

        "list running processes")
            [[ "$cmd" =~ ps ]] && {
                echo "yes|ok"; return;
            }
            echo "no|not_ps"
            ;;

        "show disk usage")
            [[ "$cmd" =~ df ]] && {
                echo "yes|ok"; return;
            }
            echo "no|not_df"
            ;;

        *)
            echo "no|unknown_task"
            ;;
    esac
}

# -----------------------------
# CORE EXECUTION
# -----------------------------

run_prompt() {
    local model="$1"
    local task="$2"

    local PROMPT
    read -r -d '' PROMPT <<EOF || true
Return ONLY this exact format:

COMMAND: <single bash command>

STRICT RULES:
- Output ONLY one line
- NO markdown
- NO backticks
- NO explanation
- NO extra text
- NO code fences
- MUST start with: COMMAND:

Task: $task
EOF

    local START END LATENCY RESPONSE CLEAN CMD VALID REASON

    START=$(date +%s.%N)

    RESPONSE=$(echo "$PROMPT" | timeout "$TIMEOUT" ollama run "$model" 2>/dev/null || true)

    END=$(date +%s.%N)
    LATENCY=$(awk "BEGIN {print $END - $START}")

    CLEAN=$(echo "$RESPONSE" | normalize_output)

    CMD=$(echo "$CLEAN" | extract_command)

    IFS="|" read -r VALID REASON < <(validate_command "$task" "$CMD")

    echo "$LATENCY|$VALID|$REASON|$CMD|$CLEAN"
}

# -----------------------------
# MAIN
# -----------------------------

echo "[INFO] Starting benchmark..."
echo "[INFO] Output dir: $OUTDIR"

for model in "${MODELS[@]}"; do
    ensure_model "$model"
    warmup_model "$model"

    for task in "${PROMPTS[@]}"; do
        for i in $(seq 1 $ITERATIONS); do
            echo "[RUN] model=$model | task='$task' | iter=$i"

            RESULT=$(run_prompt "$model" "$task")

            LATENCY=$(echo "$RESULT" | cut -d'|' -f1)
            VALID=$(echo "$RESULT" | cut -d'|' -f2)
            REASON=$(echo "$RESULT" | cut -d'|' -f3)
            CMD=$(echo "$RESULT" | cut -d'|' -f4)
            RAW=$(echo "$RESULT" | cut -d'|' -f5-)

            ESCAPED=$(echo "$RAW" | sed 's/"/""/g')

            echo "$model,\"$task\",$i,$LATENCY,$VALID,$REASON,\"$ESCAPED\"" >> "$CSV"

            {
                echo "MODEL: $model"
                echo "TASK: $task"
                echo "ITER: $i"
                echo "LATENCY: $LATENCY"
                echo "VALID: $VALID"
                echo "REASON: $REASON"
                echo "COMMAND: $CMD"
                echo "RAW: $RAW"
                echo "----------------------------------"
            } >> "$LOG"
        done
    done
done

echo "[DONE] Benchmark complete."
echo "[INFO] CSV: $CSV"
echo "[INFO] LOG: $LOG"