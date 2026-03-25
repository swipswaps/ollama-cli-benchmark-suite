#!/usr/bin/env bash
# system_llm_probe.sh
set -euo pipefail

echo "==== CPU ===="
lscpu | grep -E 'Model name|Socket|Thread|Core|MHz'

echo
echo "==== RAM ===="
free -h

echo
echo "==== SWAP ===="
swapon --show || true

echo
echo "==== Disk ===="
df -h /

echo
echo "==== Recommended Max Model Size ===="

RAM_GB=$(free -g | awk '/Mem:/ {print $2}')

if (( RAM_GB <= 8 )); then
  echo "→ Use: 3B–7B models ONLY"
elif (( RAM_GB <= 16 )); then
  echo "→ Use: 7B–13B models (low quantization)"
else
  echo "→ Use: up to 13B–20B (still CPU-bound)"
fi