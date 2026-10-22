#!/usr/bin/env bash
# Validate every configured SHACL file against each data repository — same
# validate loop as validate-all-and-write-to-gdb.sh — but write results to
# disk instead of GraphDB history:
#
#   <out>/<data-repo-id>/<SHACL-stem>/validation-report.ttl
#   <out>/<data-repo-id>/<SHACL-stem>/timing.txt
#
# Does not prune history and does not rebuild the dashboard. Useful for local
# GraphDB testing (e.g. validation_history.base_url = http://localhost:7200/).
#
# Usage:
#   export GDBUSER=... GDBPASS=...
#   ./validate-to-files.sh
#   ./validate-to-files.sh /path/to/output-dir
#
# Environment:
#   OUT_DIR       — output root (default: ./validation-files, or first arg)
#   GDB_BASE_URL  — overrides validation_history.base_url
#   GDBUSER / GDBPASS — required for GraphDB login
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(python3 "$SCRIPT_DIR/dashboard_config.py" --export-shell)"
: "${GDB_URL:?}" "${DATA_REPO_IDS:?}" "${DATA_REPO_GRAPHDB_NAMES:?}"

OUT_DIR="${1:-${OUT_DIR:-$SCRIPT_DIR/validation-files}}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

echo "GraphDB: $GDB_URL"
echo "Data repositories: $DATA_REPO_IDS"
echo "Output: $OUT_DIR"

LOG="$SCRIPT_DIR/batch-files.log"
: > "$LOG"

: "${GDBUSER:?GDBUSER env var must be set}"
: "${GDBPASS:?GDBPASS env var must be set}"

GDB_AUTH_URL="${GDB_URL}rest/login/${GDBUSER}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
login_headers="$tmp_dir/login.headers"
login_body="$tmp_dir/login.body"
login_code=$(curl -sS -D "$login_headers" -o "$login_body" -X POST \
  -H "X-GraphDB-Password: $GDBPASS" \
  -w "%{http_code}" \
  "$GDB_AUTH_URL" || true)
auth_header=$(grep -i "^authorization:" "$login_headers" || true)
auth_header=${auth_header%$'\r'}
if [[ -z "$auth_header" ]]; then
  echo "GraphDB login failed: HTTP ${login_code:-curl error} from $GDB_AUTH_URL" | tee -a "$LOG"
  if [[ -s "$login_body" ]]; then
    cat "$login_body" | tee -a "$LOG"
    echo | tee -a "$LOG"
  fi
  echo "Export GDBUSER and GDBPASS for an account that can log in to this GraphDB, then re-run." | tee -a "$LOG"
  exit 1
fi
token=${auth_header#*: }
token=${token#"${token%%[![:space:]]*}"}
AUTH_HEADER="Authorization: $token"

IFS=' ' read -r -a repo_ids <<< "$DATA_REPO_IDS"
IFS=' ' read -r -a repo_names <<< "$DATA_REPO_GRAPHDB_NAMES"

total_done_count=0
total_fail_count=0

for idx in "${!repo_ids[@]}"; do
  data_repo_id="${repo_ids[$idx]}"
  data_repo_name="${repo_names[$idx]}"

  echo "" | tee -a "$LOG"
  echo "======================================================================" | tee -a "$LOG"
  echo "[$(date -Iseconds)] VALIDATING DATA REPOSITORY: $data_repo_id ($data_repo_name)" | tee -a "$LOG"
  echo "======================================================================" | tee -a "$LOG"

  VALIDATE_ENDPOINT="${GDB_URL}rest/repositories/${data_repo_name}/validate/file"
  done_count=0
  fail_count=0

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    base=$(basename "$file")
    [[ "$base" == "validation-report.ttl" || "$base" == "relicap-val-report.ttl" ]] && continue

    name="${base%.ttl}"
    out_subdir="$OUT_DIR/$data_repo_id/$name"
    mkdir -p "$out_subdir"
    report_path="$out_subdir/validation-report.ttl"
    timing_path="$out_subdir/timing.txt"

    echo "[$(date -Iseconds)] [$data_repo_id] START $name" | tee -a "$LOG"
    start=$(python3 -c 'import time; print(time.perf_counter())')
    http_code=$(curl -s -X POST --header 'Accept: text/turtle' -H "$AUTH_HEADER" \
      "$VALIDATE_ENDPOINT" \
      -F "file=@$file;type=text/turtle" \
      -o "$report_path" \
      -w "%{http_code}")
    end=$(python3 -c 'import time; print(time.perf_counter())')
    duration=$(python3 -c "print(f'{$end - $start:.3f}')")
    finished_at="$(date -Iseconds)"

    cat > "$timing_path" <<EOF
file: $base
data_repository_id: $data_repo_id
repository: $data_repo_name
http_status: $http_code
duration_seconds: $duration
finished_at: $finished_at
EOF

    if [[ "$http_code" == "200" ]]; then
      echo "[$(date -Iseconds)] [$data_repo_id] DONE $name (${duration}s) -> $out_subdir" | tee -a "$LOG"
      ((done_count++)) || true
    else
      echo "[$(date -Iseconds)] [$data_repo_id] FAIL $name (HTTP $http_code, ${duration}s) -> $out_subdir" | tee -a "$LOG"
      ((fail_count++)) || true
    fi
  done < <(python3 "$SCRIPT_DIR/dashboard_config.py" --list-shacl)

  echo "[$(date -Iseconds)] [$data_repo_id] COMPLETE: $done_count succeeded, $fail_count failed" | tee -a "$LOG"
  total_done_count=$((total_done_count + done_count))
  total_fail_count=$((total_fail_count + fail_count))
done

echo "[$(date -Iseconds)] BATCH COMPLETE: $total_done_count succeeded, $total_fail_count failed" | tee -a "$LOG"
echo "[$(date -Iseconds)] Reports written under $OUT_DIR/<data-repo-id>/<SHACL-stem>/{validation-report.ttl,timing.txt}" | tee -a "$LOG"
