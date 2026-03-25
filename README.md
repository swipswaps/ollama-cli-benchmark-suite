# llm-run.sh v6.4

PRF-compliant Bash utility for safely generating, validating, and optionally executing single-line Linux commands suggested by a Large Language Model (LLM). Designed to be auditable, sandboxed, and user-friendly.

---

## **Purpose**

- Allow users to query an LLM for Linux commands without risk of unsafe execution.
- Cache validated commands for reuse.
- Provide dry-run simulation to preview results.
- Enable safe sandboxed execution.
- Offer clipboard support and debug logging for analysis.

---

## **Features**

- **PRF Compliance:** `[PRF-Pxx]` markers allow full audit tracking.
- **LLM Integration:** Uses `PRIMARY_MODEL` with fallback to `FALLBACK_MODEL`.
- **Command Normalization:** Ensures output is valid shell syntax.
- **Cache:** Saves previous validated commands in `.llm_cmd_cache.db`.
- **Sandboxed Execution:** Uses `bwrap` or timed `bash` to prevent unsafe system changes.
- **Clipboard Copy:** Supports `xclip` (X11) and `wl-copy` (Wayland).
- **Debug Mode:** Logs raw LLM output for troubleshooting.
- **Repair Attempts:** Retries failed commands automatically.
- **Simulated Output:** Provides safe previews without execution.

---

## **Installation**

```bash
# Make script executable
chmod +x llm-run.sh

# Ensure required tools are installed
sudo dnf install xclip bubblewrap coreutils procps -y  # Fedora
# or
sudo apt install xclip bubblewrap coreutils procps -y  # Debian/Ubuntu
Basic Usage
# Dry-run (simulate only)
./llm-run.sh "list files sorted by newest"

# Execute in sandbox (safe execution)
EXEC=1 ./llm-run.sh "show current directory"

# Debug mode (logs raw LLM output)
DEBUG=1 ./llm-run.sh "list running processes"

# Copy validated command to clipboard
COPY=1 ./llm-run.sh "show disk usage"
Configuration Variables
Variable	Description	Default
PRIMARY_MODEL	Main LLM model for command generation	qwen2:1.5b
FALLBACK_MODEL	Secondary LLM model if primary fails	qwen2:0.5b
EXEC	1 = execute commands in sandbox; 0 = dry-run	0
COPY	1 = copy validated command to clipboard	0
DEBUG	1 = enable debug logging	0
TIMEOUT	Max seconds to wait for LLM response	12
SANDBOX_TIMEOUT	Max seconds for sandbox execution	5
REPAIR_ATTEMPTS	Number of auto-retries for failed commands	2
Examples & Workflow
1. Preview Files Sorted by Newest
./llm-run.sh "list files sorted by newest"
Dry-run output simulates the top 5 newest files.
Command ready for copy: e.g., ls -t
2. Execute Current Directory Check
EXEC=1 ./llm-run.sh "show current directory"
Runs pwd in a sandbox.
Returns actual current directory path.
3. Debug Running Processes
DEBUG=1 ./llm-run.sh "list running processes"
Prints LLM raw output for verification.
Simulates execution if EXEC not set.
4. Copy Disk Usage Command
COPY=1 ./llm-run.sh "show disk usage"
Copies df -h to clipboard.
Shows simulated output without executing (unless EXEC=1).
Cache System
Stores validated commands per task in .llm_cmd_cache.db.
Cache ensures repeated queries return fast, consistent results.
Automatic normalization ensures safe reuse.
Sandbox Execution
Primary sandbox: bwrap (Bubblewrap) isolates /usr, /bin, /lib, /etc, /proc, /dev, and /tmp.
Fallback sandbox: bash with timeout if bwrap unavailable.
Prevents execution of dangerous commands (e.g., rm -rf /, shutdown, :(){:|:&};:).
Debugging & Repair Attempts
If command fails validation or execution:
Script retries REPAIR_ATTEMPTS times.
Logs attempt number and raw output.
Debug mode prints raw LLM output to help identify anomalies.
Supported Tasks
Task	Expected Command	Dry-run Output
list files sorted by newest	ls -t	Top 5 newest files
show current directory	pwd	Current path
list running processes	ps aux	First 5 processes
show disk usage	df -h	Top 5 filesystem usage lines
Known Limitations
Minor variations in LLM output may fail regex validation (e.g., ls -tl vs ls -t).
bwrap may fail silently on restricted environments.
Repair attempts currently retry only primary model; fallback model not rotated per attempt.
Adding new tasks requires updating task_hint, validate_command, validate_execution, simulate_output.
Changelog v6.4
Added PRF inline [PRF-Pxx] markers.
Enhanced cache, normalization, and sandboxing.
Debug logging of raw LLM output.
Clipboard support for X11 & Wayland.
Simulated output logging for dry-run mode.