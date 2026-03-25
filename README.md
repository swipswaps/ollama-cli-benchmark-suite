# llm-run.sh v6.5

PRF-compliant Bash utility for safely generating, validating, and optionally executing single-line Linux commands suggested by an LLM. v6.5 adds resilience: minor LLM variations are accepted, fallback model rotates during repair, and sandbox stderr is logged separately.

---

## **Purpose**

- Safely query an LLM for Linux commands without risk.
- Cache validated commands.
- Dry-run simulation for preview.
- Safe sandbox execution with Bubblewrap or timed Bash.
- Clipboard support and debug logging.

---

## **Features**

- **Minor LLM Variations:** Accepts slight differences like `ls -tl`.
- **Repair Model Rotation:** Switches fallback model during repair attempts.
- **Sandbox stderr Logging:** Easier debugging.
- **PRF Compliance:** `[PRF-Pxx]` markers.
- **Cache:** `.llm_cmd_cache.db`.
- **Clipboard Copy:** X11 and Wayland.
- **Debug Mode:** Logs raw LLM output.
- **Simulated Output:** Safe dry-run preview.

---

## **Usage Examples**

```bash
# Dry-run
./llm-run.sh "list files sorted by newest"

# Execute in sandbox
EXEC=1 ./llm-run.sh "show current directory"

# Debug mode
DEBUG=1 ./llm-run.sh "list running processes"

# Copy output to clipboard
COPY=1 ./llm-run.sh "show disk usage"
Dry-run outputs simulated results without execution.
Sandbox execution isolates filesystem and prevents dangerous commands.
Debug mode logs raw model output.
Clipboard copies validated commands automatically.