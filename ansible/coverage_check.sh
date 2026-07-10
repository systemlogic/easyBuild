#!/usr/bin/env bash
# coverage_check.sh
#
# Measures code coverage for lines changed in the last commit (HEAD~1..HEAD),
# per language. Validates that patch coverage >= THRESHOLD (default 75%)
# for every affected language; exits 0 (PASS) or 1 (FAIL).
#
# Ported from cross_platform/ansible/coverage_check.sh and adapted to
# easy_build's scaffolded-project layout:
#   - Target discovery is delegated to affected_targets.sh (this directory)
#     instead of re-running its own rdeps query, so the two scripts can't
#     drift out of sync on the changed-file extension list or query shape.
#   - Query/fallback root is //example/... (easy_build's scaffold layout)
#     instead of //examples/....
#   - Covers all 8 languages easy_build can scaffold (cpp, java, python, go,
#     rust, kotlin, scala, haskell) instead of just cc/java/go/python.
#   - Runs plain `bazel` on PATH rather than a workspace-local ./bazel
#     wrapper, since easy_build-scaffolded projects don't ship one.
#
# Supported languages: C/C++, Java, Python, Go, Rust, Kotlin, Scala, Haskell
# Coverage tool: Bazel's built-in `bazel coverage` (lcov output)
#
# Usage:
#   ./ansible/coverage_check.sh [OPTIONS]
#
# Options:
#   --config <cfg>      Bazel platform config  (default: auto-detected)
#                       One of: x86_64 | arm64 | macos_arm64 | macos_x86_64
#   --threshold <pct>   Minimum coverage % required (default: 75)
#   --keep-report       Do not delete the temporary coverage report
#   -h | --help         Show this help
#
# Examples:
#   ./ansible/coverage_check.sh --config macos_arm64
#   ./ansible/coverage_check.sh --threshold 80

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BAZEL="${BAZEL:-bazel}"

# ── Defaults ──────────────────────────────────────────────────────────────────
BAZEL_CONFIG=""
THRESHOLD=75
KEEP_REPORT=0
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="${WORKSPACE_DIR}/coverage_reports/${TIMESTAMP}"
LCOV_MERGED="${REPORT_DIR}/merged_coverage.dat"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo -e "${CYAN}[coverage]${RESET} $*"; }
warn() { echo -e "${YELLOW}[warning]${RESET}  $*"; }
die()  { echo -e "${RED}[error]${RESET}    $*" >&2; exit 1; }

usage() {
    awk '
        /^# Usage:/ { f = 1 }
        f && !/^#/  { exit }
        f           { sub(/^# ?/, ""); print }
    ' "$0"
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)      BAZEL_CONFIG="$2"; shift 2 ;;
        --threshold)   THRESHOLD="$2";   shift 2 ;;
        --keep-report) KEEP_REPORT=1;    shift ;;
        -h|--help)     usage ;;
        *) die "Unknown option: $1  (run with --help for usage)" ;;
    esac
done

# ── Auto-detect Bazel platform config ─────────────────────────────────────────
detect_config() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "${os}" in
        Darwin)
            [[ "${arch}" == "arm64" ]] && echo "macos_arm64" || echo "macos_x86_64" ;;
        Linux)
            [[ "${arch}" == "aarch64" || "${arch}" == "arm64" ]] && echo "arm64" || echo "x86_64" ;;
        *) die "Unsupported OS: ${os}" ;;
    esac
}

if [[ -z "${BAZEL_CONFIG}" ]]; then
    BAZEL_CONFIG="$(detect_config)"
    log "Auto-detected Bazel config: --config=${BAZEL_CONFIG}"
fi

# ── Resolve commit range ──────────────────────────────────────────────────────
CURRENT_BRANCH="$(git -C "${WORKSPACE_DIR}" rev-parse --abbrev-ref HEAD)"
HEAD_SHA="$(git -C "${WORKSPACE_DIR}" rev-parse --short HEAD)"
PREV_SHA="$(git -C "${WORKSPACE_DIR}" rev-parse --short HEAD~1 2>/dev/null)" \
    || die "Could not resolve HEAD~1. Repository must have at least 2 commits."

log "Branch : ${CURRENT_BRANCH}"
log "Diff   : ${PREV_SHA}..${HEAD_SHA}  (HEAD~1..HEAD — last commit)"

# ── Collect changed source files ──────────────────────────────────────────────
# Use --name-only for target discovery; also keep the full patch for line tracking.
PATCH_CONTENT="$(git -C "${WORKSPACE_DIR}" diff HEAD~1..HEAD)"
[[ -n "${PATCH_CONTENT}" ]] || die "Diff is empty — last commit introduced no changes."

# Gather only source-file paths that Bazel can trace as srcs nodes. Extension
# list mirrors affected_targets.sh's — every language easy_build can scaffold.
mapfile -t CHANGED_SOURCE_FILES < <(
    git -C "${WORKSPACE_DIR}" diff HEAD~1..HEAD --name-only \
        -- "*.cpp" "*.cc" "*.cxx" "*.c" "*.h" "*.hh" "*.hpp" \
           "*.java" "*.py" "*.go" "*.rs" "*.kt" "*.scala" "*.hs" \
        2>/dev/null || true
)

if [[ ${#CHANGED_SOURCE_FILES[@]} -eq 0 ]]; then
    warn "No supported source files changed (cpp/java/python/go/rust/kotlin/scala/haskell). Nothing to check."
    exit 0
fi

log "Changed source files (${#CHANGED_SOURCE_FILES[@]}):"
for f in "${CHANGED_SOURCE_FILES[@]}"; do
    echo "    ${f}"
done

# ── Parse patch → {file:lineno} for patch coverage computation ────────────────
# Outputs lines of the form:  <file>:<lineno>
parse_patch_lines() {
    local patch="$1"
    local current_file="" lineno

    while IFS= read -r line; do
        if [[ "${line}" =~ ^\+\+\+\ b/(.+)$ ]]; then
            current_file="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "${line}" =~ ^@@\ -[0-9]+(,[0-9]+)?\ \+([0-9]+)(,([0-9]+))?\ @@ ]]; then
            lineno="${BASH_REMATCH[2]}"
            continue
        fi

        [[ -z "${current_file}" || -z "${lineno}" ]] && continue

        if [[ "${line}" =~ ^\+ && ! "${line}" =~ ^\+\+\+ ]]; then
            echo "${current_file}:${lineno}"
            (( lineno++ )) || true
        elif [[ ! "${line}" =~ ^- ]]; then
            (( lineno++ )) || true
        fi
    done <<< "${patch}"
}

declare -A PATCH_LINES   # key="file:lineno" → 1
declare -A PATCHED_FILES # key=file → 1

log "Parsing patch lines..."
while IFS= read -r entry; do
    PATCH_LINES["${entry}"]=1
    PATCHED_FILES["${entry%%:*}"]=1
done < <(parse_patch_lines "${PATCH_CONTENT}")

[[ ${#PATCHED_FILES[@]} -eq 0 ]] && die "No changed source lines found in patch."

# ── Classify changed files by language (for reporting) ────────────────────────
declare -A LANG_HAS_CHANGES

for f in "${CHANGED_SOURCE_FILES[@]}"; do
    case "${f}" in
        *.cpp|*.cc|*.cxx|*.c|*.h|*.hh|*.hpp) LANG_HAS_CHANGES["cpp"]=1 ;;
        *.java)   LANG_HAS_CHANGES["java"]=1 ;;
        *.py)     LANG_HAS_CHANGES["python"]=1 ;;
        *.go)     LANG_HAS_CHANGES["go"]=1 ;;
        *.rs)     LANG_HAS_CHANGES["rust"]=1 ;;
        *.kt)     LANG_HAS_CHANGES["kotlin"]=1 ;;
        *.scala)  LANG_HAS_CHANGES["scala"]=1 ;;
        *.hs)     LANG_HAS_CHANGES["haskell"]=1 ;;
    esac
done

log "Languages with changes: ${!LANG_HAS_CHANGES[*]}"

# ── Discover affected Bazel targets ────────────────────────────────────────────
# Delegate to affected_targets.sh (this directory) so the rdeps(//example/...,
# set(<changed files>)) query lives in exactly one place, shared with
# lint_affected.yml. Its diagnostics go to stderr; only target labels land on
# stdout, which is what we capture here.
[[ -x "${SCRIPT_DIR}/affected_targets.sh" ]] || die "affected_targets.sh not found or not executable next to this script."

log "Discovering affected targets via affected_targets.sh..."
mapfile -t AFFECTED_TARGETS < <("${SCRIPT_DIR}/affected_targets.sh")

if [[ ${#AFFECTED_TARGETS[@]} -eq 0 ]]; then
    warn "affected_targets.sh returned no targets for the changed files."
    warn "The changed files may not be listed as srcs in any //example/... target."
    warn "Falling back to broad per-language targets."
    declare -A LANG_TARGETS=(
        [cpp]="//example/cpp/..."
        [java]="//example/java/..."
        [python]="//example/python/..."
        [go]="//example/go/..."
        [rust]="//example/rust/..."
        [kotlin]="//example/kotlin/..."
        [scala]="//example/scala/..."
        [haskell]="//example/haskell/..."
    )
    for lang in "${!LANG_HAS_CHANGES[@]}"; do
        AFFECTED_TARGETS+=("${LANG_TARGETS[${lang}]}")
    done
fi

log "Affected targets (${#AFFECTED_TARGETS[@]}):"
for t in "${AFFECTED_TARGETS[@]}"; do
    echo "    ${t}"
done

# ── Run bazel coverage on the discovered targets ──────────────────────────────
mkdir -p "${REPORT_DIR}"

log "Running: ${BAZEL} coverage --config=${BAZEL_CONFIG} --combined_report=lcov ${AFFECTED_TARGETS[*]}"
echo ""

"${BAZEL}" coverage \
    --config="${BAZEL_CONFIG}" \
    --combined_report=lcov \
    --instrument_test_targets \
    -- "${AFFECTED_TARGETS[@]}" \
    2>&1 | tee "${REPORT_DIR}/bazel_coverage.log" || {
        echo ""
        die "bazel coverage failed — see ${REPORT_DIR}/bazel_coverage.log"
    }

echo ""

# Locate the merged lcov report Bazel produced
BAZEL_COVERAGE_DAT="${WORKSPACE_DIR}/bazel-out/_coverage/_coverage_report.dat"
if [[ ! -f "${BAZEL_COVERAGE_DAT}" ]]; then
    log "Merged report not found at expected path; aggregating per-test reports..."
    > "${LCOV_MERGED}"
    find "${WORKSPACE_DIR}/bazel-testlogs" -name "coverage.dat" 2>/dev/null | while read -r dat; do
        cat "${dat}" >> "${LCOV_MERGED}"
    done
    [[ -s "${LCOV_MERGED}" ]] || die "No coverage data found under bazel-testlogs/."
    BAZEL_COVERAGE_DAT="${LCOV_MERGED}"
fi

cp "${BAZEL_COVERAGE_DAT}" "${LCOV_MERGED}"
log "Coverage data: ${LCOV_MERGED}"

# ── Parse lcov report filtered to patch lines ─────────────────────────────────
compute_patch_coverage() {
    local lcov_file="$1"
    local current_sf="" lang
    declare -A lang_covered lang_total

    for l in cpp java python go rust kotlin scala haskell; do
        lang_covered[$l]=0
        lang_total[$l]=0
    done

    while IFS= read -r line; do
        if [[ "${line}" =~ ^SF:(.+)$ ]]; then
            current_sf="${BASH_REMATCH[1]}"
            current_sf="${current_sf#*/_main/}"
            current_sf="${current_sf#*/execroot/}"
            # Unlike cross_platform (a fixed workspace name), easy_build
            # scaffolds a differently-named bzlmod root module per project,
            # so normalize to the example/... root instead of hardcoding it.
            case "${current_sf}" in
                example/*) ;;
                */example/*) current_sf="example/${current_sf#*/example/}" ;;
            esac
            continue
        fi

        if [[ "${line}" == "end_of_record" ]]; then
            current_sf=""
            continue
        fi

        [[ -z "${current_sf}" ]] && continue

        if [[ "${line}" =~ ^DA:([0-9]+),([0-9]+) ]]; then
            local lineno="${BASH_REMATCH[1]}"
            local hits="${BASH_REMATCH[2]}"
            local key="${current_sf}:${lineno}"

            [[ "${PATCH_LINES[${key}]+set}" ]] || continue

            case "${current_sf}" in
                *.cpp|*.cc|*.cxx|*.c|*.h|*.hh|*.hpp) lang="cpp" ;;
                *.java)   lang="java" ;;
                *.py)     lang="python" ;;
                *.go)     lang="go" ;;
                *.rs)     lang="rust" ;;
                *.kt)     lang="kotlin" ;;
                *.scala)  lang="scala" ;;
                *.hs)     lang="haskell" ;;
                *) continue ;;
            esac

            (( lang_total[$lang]++ )) || true
            [[ "${hits}" -gt 0 ]] && (( lang_covered[$lang]++ )) || true
        fi
    done < "${lcov_file}"

    for l in cpp java python go rust kotlin scala haskell; do
        echo "${l} ${lang_covered[$l]} ${lang_total[$l]}"
    done
}

log "Analysing coverage for patch lines..."
declare -A COVERED TOTAL PCT
while read -r lang cov tot; do
    COVERED[$lang]="${cov}"
    TOTAL[$lang]="${tot}"
    if [[ "${tot}" -gt 0 ]]; then
        PCT[$lang]=$(( cov * 100 / tot ))
    else
        PCT[$lang]=-1
    fi
done < <(compute_patch_coverage "${LCOV_MERGED}")

# ── Results ───────────────────────────────────────────────────────────────────
declare -A LANG_LABELS=(
    [cpp]="C/C++"
    [java]="Java"
    [python]="Python"
    [go]="Go"
    [rust]="Rust"
    [kotlin]="Kotlin"
    [scala]="Scala"
    [haskell]="Haskell"
)

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  PATCH COVERAGE RESULTS  (threshold: ${THRESHOLD}%)${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

OVERALL_STATUS=0

for lang in cpp java python go rust kotlin scala haskell; do
    [[ "${LANG_HAS_CHANGES[${lang}]+set}" ]] || continue

    label="${LANG_LABELS[$lang]}"
    cov="${COVERED[$lang]}"
    tot="${TOTAL[$lang]}"
    pct="${PCT[$lang]}"

    if [[ "${tot}" -eq 0 ]]; then
        warn "  ${label}: no instrumented patch lines found in coverage data."
        warn "         Changed files may be headers, generated code, or excluded from coverage."
        continue
    fi

    if [[ "${pct}" -ge "${THRESHOLD}" ]]; then
        status_str="${GREEN}PASS ✓${RESET}"
    else
        status_str="${RED}FAIL ✗${RESET}"
        OVERALL_STATUS=1
    fi

    printf "  %-10s  %3d%% / %d%%  (%d / %d patch lines covered)  %b\n" \
        "${label}" "${pct}" "${THRESHOLD}" "${cov}" "${tot}" "${status_str}"
done

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

if [[ "${OVERALL_STATUS}" -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}PATCH STATUS: PASS${RESET}  — all languages meet the ${THRESHOLD}% threshold."
else
    echo -e "  ${RED}${BOLD}PATCH STATUS: FAIL${RESET}  — one or more languages are below ${THRESHOLD}% coverage."
fi

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  Coverage report : ${LCOV_MERGED}"
echo "  Bazel log       : ${REPORT_DIR}/bazel_coverage.log"
echo ""

# ── Cleanup ───────────────────────────────────────────────────────────────────
if [[ "${KEEP_REPORT}" -eq 0 && "${OVERALL_STATUS}" -eq 0 ]]; then
    rm -rf "${REPORT_DIR}"
fi

exit "${OVERALL_STATUS}"
