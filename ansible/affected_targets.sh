#!/usr/bin/env bash
# affected_targets.sh
#
# Lists Bazel targets under //example/... that are transitively affected by
# source-file changes in the last commit (HEAD~1..HEAD), across every
# language easy_build supports (cpp, java, python, go, rust, kotlin, scala,
# haskell).
#
# This is the git-diff + `bazel query rdeps(...)` logic from
# cross_platform/ansible/affected_server_targets.sh, generalized for
# easy_build: no `attr(tags, 'server', ...)` filter (easy_build's scaffolded
# examples aren't tagged that way), the file-extension list covers all 8
# languages, and the query root is //example/... (easy_build's scaffold
# layout) instead of //examples/....
#
# How it works:
#   1. Collects changed source files via:
#        git diff HEAD~1..HEAD --name-only -- "*.cpp" "*.cc" ... "*.hs"
#   2. Passes them to bazel query to find //example/... targets that depend
#      on those files:
#        bazel query "rdeps(//example/..., set(<files>))"
#
# Usage:
#   ./ansible/affected_targets.sh [-h | --help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BAZEL="${BAZEL:-bazel}"

# ── Colours ───────────────────────────────────────────────────────────────────
# Diagnostic/progress output goes to stderr so that stdout carries only the
# final bazel target labels (one per line) — safe to consume programmatically.
CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${CYAN}[affected]${RESET} $*" >&2; }
warn() { echo -e "${YELLOW}[warning]${RESET}  $*" >&2; }
die()  { echo -e "${RED}[error]${RESET}    $*" >&2; exit 1; }

[[ "${1-}" == "-h" || "${1-}" == "--help" ]] && {
    sed -n '/^# Usage:/,/^[^#]/{ /^#/{ s/^# \{0,2\}//; p }; /^[^#]/q }' "$0"
    exit 0
}

# ── Resolve commits ───────────────────────────────────────────────────────────
HEAD_SHA="$(git -C "${WORKSPACE_DIR}" rev-parse --short HEAD)"
PREV_SHA="$(git -C "${WORKSPACE_DIR}" rev-parse --short HEAD~1 2>/dev/null)" \
    || die "Could not resolve HEAD~1 — repository must have at least 2 commits."

log "Diff: ${PREV_SHA}..${HEAD_SHA}  (HEAD~1..HEAD)"

# ── Collect changed source files (every easy_build language) ─────────────────
mapfile -t CHANGED_FILES < <(
    git -C "${WORKSPACE_DIR}" diff HEAD~1..HEAD --name-only \
        -- "*.cpp" "*.cc" "*.cxx" "*.c" "*.h" "*.hh" "*.hpp" \
           "*.java" "*.py" "*.go" "*.rs" "*.kt" "*.scala" "*.hs" \
        2>/dev/null || true
)

if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
    warn "No supported source files changed in the last commit (cpp/java/python/go/rust/kotlin/scala/haskell)."
    exit 0
fi

log "Changed source files (${#CHANGED_FILES[@]}):"
for f in "${CHANGED_FILES[@]}"; do
    echo "    ${f}" >&2
done

# ── Query affected targets ─────────────────────────────────────────────────────
# set() accepts workspace-relative paths as Bazel source-file nodes.
FILE_SET="${CHANGED_FILES[*]}"
QUERY="rdeps(//example/..., set(${FILE_SET}))"

log "Running bazel query..."
log "  Query: ${QUERY}"

mapfile -t AFFECTED_TARGETS < <(
    "${BAZEL}" query "${QUERY}" --output=label 2>/dev/null \
        | grep -v '^$' || true
)

if [[ ${#AFFECTED_TARGETS[@]} -eq 0 ]]; then
    warn "No //example/... targets are affected by the last commit."
    exit 0
fi

log "Affected targets (${#AFFECTED_TARGETS[@]}):"
printf '%s\n' "${AFFECTED_TARGETS[@]}"
