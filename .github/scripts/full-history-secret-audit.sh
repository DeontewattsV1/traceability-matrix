#!/usr/bin/env bash
# Scan git history and every external surface this repository still has.
#
# The shared AGI-CP reusable workflow marks the run INCOMPLETE and exits 2
# when any download returns an error. GitHub answers 404 or 410 for Actions
# logs and artifacts it has already deleted, so that check can never pass
# once retention expires. Those objects have no bytes left to scan.
#
# This script still fails the run when:
#   - gitleaks reports a secret in anything it could read
#   - gitleaks itself errors
#   - a list API fails, so a surface could not be enumerated
#   - a retained object returns anything other than success or 404/410
#
# Exit 0: retained surfaces scanned, no secrets
# Exit 1: secret findings
# Exit 2: a retained surface could not be scanned

set -euo pipefail

GITLEAKS_VERSION="8.30.1"
GITLEAKS_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"

cd "$(git rev-parse --show-toplevel)"

RAW_DIR="$PWD/.audit/raw"
SAFE_DIR="$PWD/.audit/safe"
EXT_DIR="$PWD/.audit/external"
mkdir -p "$RAW_DIR" "$SAFE_DIR" \
  "$EXT_DIR/release-assets" "$EXT_DIR/actions-artifacts" \
  "$EXT_DIR/actions-logs" "$EXT_DIR/attachments" "$EXT_DIR/metadata"

cleanup() {
  rm -rf "$RAW_DIR" "$EXT_DIR"
}
trap cleanup EXIT

: > "$SAFE_DIR/unretained.txt"
: > "$RAW_DIR/download-errors.log"

collection_errors=0
hard_errors=0
unretained=0
pending=0
retained=0
scan_error=0
history_code=0
lfs_code=0
external_code=0
LAST_HTTP="000"

if [ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
  echo "GH_TOKEN or GITHUB_TOKEN is required to read external surfaces." >&2
  exit 2
fi
export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"

if [ -z "${GITHUB_REPOSITORY:-}" ]; then
  origin_url="$(git remote get-url origin)"
  GITHUB_REPOSITORY="$(printf '%s' "$origin_url" | sed -E 's#.*github.com[:/]([^/:]+/[^/.]+)(\.git)?/?$#\1#')"
fi
if [ -z "${GITHUB_REPOSITORY:-}" ] || [[ "$GITHUB_REPOSITORY" != */* ]]; then
  echo "Could not determine GITHUB_REPOSITORY." >&2
  exit 2
fi

for cmd in curl jq gh sha256sum tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 2
  fi
done

install_gitleaks() {
  local dest="${RUNNER_TEMP:-/tmp}/gitleaks-${GITLEAKS_VERSION}"
  local tarball="${dest}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
  mkdir -p "$dest"
  if [ ! -x "${dest}/gitleaks" ]; then
    curl -fsSL --retry 3 --retry-delay 2 \
      -o "$tarball" \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
    echo "${GITLEAKS_SHA256}  ${tarball}" | sha256sum -c -
    tar -xzf "$tarball" -C "$dest" gitleaks
  fi
  GITLEAKS="${dest}/gitleaks"
  "$GITLEAKS" version >/dev/null
}

# 0 = downloaded, 10 = gone (404/410), 20 = retained but unreadable
download_classified() {
  local url="$1"
  local dest="$2"
  local accept="$3"
  local http=""
  http="$(
    curl -sS -L --retry 2 --retry-delay 2 \
      --connect-timeout 20 --max-time 180 \
      -o "$dest" -w '%{http_code}' \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "Accept: ${accept}" \
      -- "$url" 2>>"$RAW_DIR/curl.err" || true
  )"
  http="$(printf '%s' "$http" | tr -cd '0-9')"
  if [ "${#http}" -gt 3 ]; then
    http="${http: -3}"
  fi
  if [ -z "$http" ]; then
    http="000"
  fi
  LAST_HTTP="$http"
  case "$http" in
    2??)
      return 0
      ;;
    404|410)
      rm -f "$dest"
      return 10
      ;;
    *)
      rm -f "$dest"
      printf 'http=%s file=%s\n' "$http" "$(basename "$dest")" >> "$RAW_DIR/download-errors.log"
      return 20
      ;;
  esac
}

account_download() {
  local rc="$1"
  local kind="$2"
  local ident="$3"
  case "$rc" in
    0) retained=$((retained + 1)) ;;
    10)
      unretained=$((unretained + 1))
      printf '%s %s http-%s\n' "$kind" "$ident" "$LAST_HTTP" >> "$SAFE_DIR/unretained.txt"
      ;;
    *) hard_errors=$((hard_errors + 1)) ;;
  esac
}

fetch_one() {
  local url="$1"
  local dest="$2"
  local accept="$3"
  local kind="$4"
  local ident="$5"
  local rc=0
  set +e
  download_classified "$url" "$dest" "$accept"
  rc=$?
  set -e
  account_download "$rc" "$kind" "$ident"
}

collect_json() {
  local endpoint="$1"
  local out="$2"
  if ! gh api --paginate --slurp "$endpoint" > "$out" 2>>"$RAW_DIR/api.err"; then
    echo '[]' > "$out"
    collection_errors=$((collection_errors + 1))
    printf 'list-failed %s\n' "$endpoint" >> "$RAW_DIR/download-errors.log"
  fi
}

install_gitleaks

export GIT_TERMINAL_PROMPT=0
if ! git fetch --quiet --force --prune origin '+refs/*:refs/audit/*'; then
  echo "Failed to fetch advertised refs." >&2
  exit 2
fi
if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
  git lfs install --local >/dev/null 2>&1 || true
  if [ -f .gitattributes ] && grep -q 'filter=lfs' .gitattributes; then
    if ! git lfs fetch --all; then
      echo "Git LFS objects are advertised but could not be fetched." >&2
      exit 2
    fi
  else
    git lfs fetch --all >/dev/null 2>&1 || true
  fi
fi

collect_json "repos/${GITHUB_REPOSITORY}/releases?per_page=100" "$EXT_DIR/metadata/releases.json"
collect_json "repos/${GITHUB_REPOSITORY}/actions/artifacts?per_page=100" "$EXT_DIR/metadata/artifacts.json"
collect_json "repos/${GITHUB_REPOSITORY}/actions/runs?per_page=100" "$EXT_DIR/metadata/runs.json"
collect_json "repos/${GITHUB_REPOSITORY}/issues?state=all&per_page=100" "$EXT_DIR/metadata/issues.json"
collect_json "repos/${GITHUB_REPOSITORY}/issues/comments?per_page=100" "$EXT_DIR/metadata/issue-comments.json"
collect_json "repos/${GITHUB_REPOSITORY}/pulls/comments?per_page=100" "$EXT_DIR/metadata/pr-review-comments.json"

while IFS=$'\t' read -r id name url; do
  [ -n "${id:-}" ] || continue
  safe_name="$(printf '%s' "$name" | tr '/\\ ' '___' | tr -cd '[:alnum:]_.-')"
  [ -n "$safe_name" ] || safe_name="asset"
  fetch_one "$url" "$EXT_DIR/release-assets/${id}-${safe_name}" "application/octet-stream" "release-asset" "$id"
done < <(jq -r '.[] | .[]? | .assets[]? | [.id, .name, .url] | @tsv' "$EXT_DIR/metadata/releases.json" 2>/dev/null || true)

expired_ids="$(jq -r '.[] | .artifacts[]? | select(.expired == true) | [.id, .name] | @tsv' "$EXT_DIR/metadata/artifacts.json" 2>/dev/null || true)"
if [ -n "$expired_ids" ]; then
  while IFS=$'\t' read -r id name; do
    [ -n "${id:-}" ] || continue
    unretained=$((unretained + 1))
    printf 'actions-artifact %s expired\n' "$id" >> "$SAFE_DIR/unretained.txt"
  done <<< "$expired_ids"
fi

while IFS=$'\t' read -r id name; do
  [ -n "${id:-}" ] || continue
  safe_name="$(printf '%s' "$name" | tr '/\\ ' '___' | tr -cd '[:alnum:]_.-')"
  [ -n "$safe_name" ] || safe_name="artifact"
  fetch_one \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/artifacts/${id}/zip" \
    "$EXT_DIR/actions-artifacts/${id}-${safe_name}.zip" \
    "application/vnd.github+json" \
    "actions-artifact" \
    "$id"
done < <(jq -r '.[] | .artifacts[]? | select(.expired == false) | [.id, .name] | @tsv' "$EXT_DIR/metadata/artifacts.json" 2>/dev/null || true)

while IFS=$'\t' read -r run_id run_status; do
  [ -n "${run_id:-}" ] || continue
  if [ -n "${GITHUB_RUN_ID:-}" ] && [ "$run_id" = "$GITHUB_RUN_ID" ]; then
    continue
  fi
  if [ "$run_status" != "completed" ]; then
    pending=$((pending + 1))
    printf 'actions-log %s not-published-yet\n' "$run_id" >> "$SAFE_DIR/unretained.txt"
    continue
  fi
  fetch_one \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/logs" \
    "$EXT_DIR/actions-logs/${run_id}.zip" \
    "application/vnd.github+json" \
    "actions-log" \
    "$run_id"
done < <(jq -r '.[] | .workflow_runs[]? | [.id, .status] | @tsv' "$EXT_DIR/metadata/runs.json" 2>/dev/null || true)

grep -RhoE 'https://(private-user-images\.githubusercontent\.com|user-images\.githubusercontent\.com|github\.com/user-attachments/assets)/[^"[:space:]<>)]+' \
  "$EXT_DIR/metadata" 2>/dev/null | sort -u > "$EXT_DIR/metadata/attachment-urls.txt" || true
n=0
while IFS= read -r url; do
  [ -n "$url" ] || continue
  n=$((n + 1))
  fetch_one "$url" "$EXT_DIR/attachments/attachment-${n}" "*/*" "attachment" "$n"
done < "$EXT_DIR/metadata/attachment-urls.txt"

run_gitleaks() {
  local code_var="$1"
  shift
  local code=0
  set +e
  "$GITLEAKS" detect \
    --redact \
    --exit-code 1 \
    --max-archive-depth 3 \
    --max-decode-depth 2 \
    --report-format json \
    "$@"
  code=$?
  set -e
  printf -v "$code_var" '%s' "$code"
  if [ "$code" -gt 1 ]; then
    scan_error=1
  fi
}

run_gitleaks history_code \
  --source "$PWD" \
  --log-opts='--all' \
  --report-path "$RAW_DIR/history.json"

if [ -d .git/lfs/objects ] && [ -n "$(find .git/lfs/objects -type f -print -quit 2>/dev/null)" ]; then
  run_gitleaks lfs_code \
    --no-git \
    --source "$PWD/.git/lfs/objects" \
    --report-path "$RAW_DIR/lfs.json"
else
  echo '[]' > "$RAW_DIR/lfs.json"
fi

run_gitleaks external_code \
  --no-git \
  --source "$EXT_DIR" \
  --report-path "$RAW_DIR/external.json"

sanitize() {
  local src="$1"
  local dst="$2"
  if [ -s "$src" ] && jq -e 'type == "array"' "$src" >/dev/null 2>&1; then
    jq '[.[] | {RuleID,Description,File,Commit,StartLine,EndLine,Fingerprint}]' "$src" > "$dst"
  else
    echo '[]' > "$dst"
  fi
}

sanitize "$RAW_DIR/history.json" "$SAFE_DIR/history-findings.json"
sanitize "$RAW_DIR/lfs.json" "$SAFE_DIR/lfs-findings.json"
sanitize "$RAW_DIR/external.json" "$SAFE_DIR/external-findings.json"

history_count="$(jq 'length' "$SAFE_DIR/history-findings.json")"
lfs_count="$(jq 'length' "$SAFE_DIR/lfs-findings.json")"
external_count="$(jq 'length' "$SAFE_DIR/external-findings.json")"
total=$((history_count + lfs_count + external_count))

status="PASS"
if [ "$collection_errors" -gt 0 ] || [ "$hard_errors" -gt 0 ] || [ "$scan_error" -gt 0 ]; then
  status="INCOMPLETE"
elif [ "$total" -gt 0 ]; then
  status="FAIL_FINDINGS"
fi

jq -n \
  --arg repository "$GITHUB_REPOSITORY" \
  --arg run_id "${GITHUB_RUN_ID:-local}" \
  --arg gitleaks "$GITLEAKS_VERSION" \
  --arg status "$status" \
  --argjson history_findings "$history_count" \
  --argjson lfs_findings "$lfs_count" \
  --argjson external_findings "$external_count" \
  --argjson collection_errors "$collection_errors" \
  --argjson retained_read_errors "$hard_errors" \
  --argjson unretained_objects "$unretained" \
  --argjson logs_not_published_yet "$pending" \
  --argjson retained_objects "$retained" \
  --argjson history_code "$history_code" \
  --argjson lfs_code "$lfs_code" \
  --argjson external_code "$external_code" \
  '{
    repository: $repository,
    run_id: $run_id,
    gitleaks: $gitleaks,
    scope: [
      "all-advertised-refs",
      "git-history",
      "lfs-objects",
      "release-assets",
      "actions-artifacts",
      "actions-logs",
      "issues-pr-metadata",
      "issues-pr-attachments"
    ],
    history_findings: $history_findings,
    lfs_findings: $lfs_findings,
    external_findings: $external_findings,
    collection_errors: $collection_errors,
    retained_objects: $retained_objects,
    retained_read_errors: $retained_read_errors,
    unretained_objects: $unretained_objects,
    logs_not_published_yet: $logs_not_published_yet,
    gitleaks_exit: { history: $history_code, lfs: $lfs_code, external: $external_code },
    status: $status,
    note: "PASS covers retained surfaces only. Unretained objects were deleted or expired on GitHub and have no bytes left to scan. This is a secret-exposure gate, not a general security certification."
  }' > "$SAFE_DIR/status.json"

case "$status" in
  PASS)
    detail="PASS: no secrets in retained surfaces. Unretained objects not scanned: ${unretained}. Logs not published yet: ${pending}."
    ;;
  FAIL_FINDINGS)
    detail="BLOCKED: ${total} secret finding(s) in retained history or external surfaces."
    ;;
  *)
    detail="BLOCKED: retained surfaces could not be scanned (collection=${collection_errors}, read=${hard_errors}, scan=${scan_error})."
    ;;
esac

{
  echo "## Full History Secret Audit"
  echo
  echo "- Status: **${status}**"
  echo "- Git-history findings: ${history_count}"
  echo "- LFS findings: ${lfs_count}"
  echo "- External-surface findings: ${external_count}"
  echo "- Retained objects scanned: ${retained}"
  echo "- Unretained objects (deleted, expired, or HTTP 404/410): ${unretained}"
  echo "- Logs not published yet: ${pending}"
  echo "- Collection errors: ${collection_errors}"
  echo "- Retained objects that could not be read: ${hard_errors}"
  echo "- gitleaks exit codes: history=${history_code}, lfs=${lfs_code}, external=${external_code}"
  echo
  echo "A PASS means every surface GitHub still retains was scanned and no secrets were found."
  echo "Objects GitHub has deleted cannot be scanned from Actions; they are listed in unretained.txt and do not by themselves fail the run."
  echo "Secret findings, scanner errors, and failures to read an object GitHub still stores fail the run."
  echo "This is a secret-exposure gate, not a general security certification."
} | tee "$SAFE_DIR/summary.md"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$SAFE_DIR/summary.md" >> "$GITHUB_STEP_SUMMARY"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "status=${status}"
    echo "findings=${total}"
    echo "unretained=${unretained}"
    echo "detail=${detail}"
  } >> "$GITHUB_OUTPUT"
fi

case "$status" in
  PASS) exit 0 ;;
  FAIL_FINDINGS) exit 1 ;;
  *) exit 2 ;;
esac
