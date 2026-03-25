#!/usr/bin/env bash
# ollama_cli_benchmark_suite.sh (FIXED)

set -euo pipefail

# -----------------------------
# CONFIG
# -----------------------------

MODELS=(
    "qwen2:0.5b"
    "phi3:mini"
    "gemma:2b"
    "llama3.2:3b"
    "qwen2:1.5b"
    "mistral:7b"
)

PROMPTS=(
    "list files sorted by newest"
    "show current directory"
    "list running processes"
    "show disk usage"
)

ITERATIONS=2
TIMEOUT=30   # seconds per request

OUTDIR="ollama_bench_$(date +%s)"
mkdir -p "$OUTDIR"

CSV="$OUTDIR/results.csv"
LOG="$OUTDIR/raw.log"

echo "model,prompt,iteration,latency_seconds,valid,output" > "$CSV"

# -----------------------------
# FUNCTIONS
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

run_prompt() {
    local model="$1"
    local task="$2"

    local PROMPT="Return ONLY this format:
COMMAND:
<single bash command>

Task: $task"

    local START END LATENCY RESPONSE CLEAN VALID

    START=$(date +%s.%N)

    RESPONSE=$(echo "$PROMPT" | timeout "$TIMEOUT" ollama run "$model" 2>/dev/null || true)

    END=$(date +%s.%N)

    # latency calc without bc (portable)
    LATENCY=$(awk "BEGIN {print $END - $START}")

    # normalize output
    CLEAN=$(echo "$RESPONSE" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/"/'\''/g')

    # validation
    if [[ "$CLEAN" =~ ^COMMAND:[[:space:]]+[^[:space:]]+ ]]; then
        VALID="yes"
    else
        VALID="no"
    fi

    echo "$LATENCY|$VALID|$CLEAN"
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
            OUTPUT=$(echo "$RESULT" | cut -d'|' -f3-)

            # safe CSV escaping
            ESCAPED_OUTPUT=$(echo "$OUTPUT" | sed 's/"/""/g')

            echo "$model,\"$task\",$i,$LATENCY,$VALID,\"$ESCAPED_OUTPUT\"" >> "$CSV"

            {
                echo "MODEL: $model"
                echo "TASK: $task"
                echo "ITER: $i"
                echo "LATENCY: $LATENCY"
                echo "VALID: $VALID"
                echo "OUTPUT: $OUTPUT"
                echo "----------------------------------"
            } >> "$LOG"
        done
    done
done

echo "[DONE] Benchmark complete."
echo "[INFO] CSV: $CSV"
echo "[INFO] LOG: $LOG"