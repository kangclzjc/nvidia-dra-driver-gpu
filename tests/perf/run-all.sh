#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# run-all.sh — Run all ComputeDomain performance tests and collect results.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Available tests
# ---------------------------------------------------------------------------
ALL_TESTS=(
    "single-cd:test-single-cd-2000-pods.sh"
    "multi-cd:test-multi-cd.sh"
    "failover:test-cd-failover.sh"
    "lifecycle:test-cd-lifecycle.sh"
    "scale:test-cd-scale.sh"
)

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
SELECTED_TESTS=()
EXTRA_ARGS=""

usage() {
    echo "Usage: $0 [--tests test1,test2,...] [--extra-args '...']"
    echo ""
    echo "Available tests:"
    for t in "${ALL_TESTS[@]}"; do
        local name="${t%%:*}"
        local script="${t#*:}"
        echo "  ${name}  →  ${script}"
    done
    echo ""
    echo "Examples:"
    echo "  $0                            # Run all tests"
    echo "  $0 --tests single-cd,scale    # Run specific tests"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tests)
            IFS=',' read -ra SELECTED_TESTS <<< "$2"
            shift 2
            ;;
        --extra-args)
            EXTRA_ARGS="$2"
            shift 2
            ;;
        -h|--help) usage ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# If no specific tests selected, run all
if (( ${#SELECTED_TESTS[@]} == 0 )); then
    for t in "${ALL_TESTS[@]}"; do
        SELECTED_TESTS+=("${t%%:*}")
    done
fi

# ---------------------------------------------------------------------------
# Run selected tests
# ---------------------------------------------------------------------------
log_info "========================================="
log_info "ComputeDomain Performance Test Suite"
log_info "========================================="
log_info "Tests to run: ${SELECTED_TESTS[*]}"
log_info "Results dir:  ${RESULTS_DIR}"
log_info ""

suite_start="$(now_ms)"
passed=0
failed=0
skipped=0
test_summaries="["
first_summary=true

for test_name in "${SELECTED_TESTS[@]}"; do
    # Find the corresponding script
    script_file=""
    for t in "${ALL_TESTS[@]}"; do
        if [[ "${t%%:*}" == "${test_name}" ]]; then
            script_file="${t#*:}"
            break
        fi
    done

    if [[ -z "${script_file}" ]]; then
        log_error "Unknown test: ${test_name}"
        (( skipped++ )) || true
        continue
    fi

    script_path="${SCRIPT_DIR}/${script_file}"
    if [[ ! -x "${script_path}" ]]; then
        log_error "Test script not executable: ${script_path}"
        (( skipped++ )) || true
        continue
    fi

    log_info "---------------------------------------"
    log_info "Running: ${test_name} (${script_file})"
    log_info "---------------------------------------"

    test_start="$(now_ms)"
    test_status="passed"

    if bash "${script_path}" ${EXTRA_ARGS}; then
        (( passed++ )) || true
    else
        test_status="failed"
        (( failed++ )) || true
        log_error "Test ${test_name} FAILED"
    fi

    test_duration_ms="$(elapsed_ms "${test_start}")"
    log_info "Test ${test_name}: ${test_status} (${test_duration_ms} ms)"

    # Add to summary
    ${first_summary} || test_summaries+=","
    test_summaries+="{\"test\":\"${test_name}\",\"status\":\"${test_status}\",\"duration_ms\":${test_duration_ms}}"
    first_summary=false

    # Cleanup between tests
    cleanup 2>/dev/null || true
    sleep 5
done

test_summaries+="]"
suite_duration_ms="$(elapsed_ms "${suite_start}")"

# ---------------------------------------------------------------------------
# Generate summary
# ---------------------------------------------------------------------------
log_info ""
log_info "========================================="
log_info "Test Suite Summary"
log_info "========================================="
log_info "Passed:   ${passed}"
log_info "Failed:   ${failed}"
log_info "Skipped:  ${skipped}"
log_info "Duration: ${suite_duration_ms} ms"
log_info "========================================="

# Write summary.json
summary_file="${RESULTS_DIR}/summary.json"
cat > "${summary_file}" <<EOJSON
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "suite_duration_ms": ${suite_duration_ms},
  "passed": ${passed},
  "failed": ${failed},
  "skipped": ${skipped},
  "tests": ${test_summaries},
  "result_files": [
$(ls -1 "${RESULTS_DIR}"/*.json 2>/dev/null | grep -v summary.json | \
  sed 's|.*/||' | awk '{printf "    \"%s\"", $0; if (NR>0) printf ",\n"}' | sed '$ s/,$//')
  ]
}
EOJSON

log_info "Summary written to ${summary_file}"

# Exit with failure if any tests failed
if (( failed > 0 )); then
    exit 1
fi
