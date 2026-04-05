#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# test-cd-lifecycle.sh — Full ComputeDomain lifecycle (Create→Ready→Delete→Gone).
# Measures each phase latency over multiple iterations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TEST_NAME="cd-lifecycle"
CD_PREFIX="perf-lifecycle"
NUM_NODES=0
ITERATIONS=20
TIMEOUT_CD_READY=120
TIMEOUT_CD_DELETE=120

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iterations) ITERATIONS="$2";   shift 2 ;;
        --num-nodes)  NUM_NODES="$2";    shift 2 ;;
        --namespace)  NAMESPACE="$2";    shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--iterations N] [--num-nodes N] [--namespace NS]"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
trap 'log_info "Cleaning up ${TEST_NAME}"; cleanup' EXIT

# ---------------------------------------------------------------------------
# Run lifecycle iterations
# ---------------------------------------------------------------------------
log_info "=== Test: ${TEST_NAME} ==="
log_info "Running ${ITERATIONS} lifecycle iterations"

create_times=()
ready_times=()
delete_times=()
total_times=()

for (( iter=1; iter<=ITERATIONS; iter++ )); do
    cd_name="${CD_PREFIX}-$(printf '%03d' ${iter})"
    log_info "--- Iteration ${iter}/${ITERATIONS}: ${cd_name} ---"

    # Phase 1: Create
    create_start="$(now_ms)"
    create_cd "${cd_name}" "${NUM_NODES}"
    create_ms="$(elapsed_ms "${create_start}")"
    log_info "  Create: ${create_ms} ms"
    create_times+=("${create_ms}")

    # Phase 2: Wait for Ready
    ready_ms="$(wait_for_cd_ready "${cd_name}" "${TIMEOUT_CD_READY}")"
    log_info "  Ready: ${ready_ms} ms"
    ready_times+=("${ready_ms}")

    # Phase 3: Delete and wait for full cleanup
    delete_start="$(now_ms)"
    kubectl delete computedomains.${CD_API_GROUP} "${cd_name}" -n "${NAMESPACE}" --timeout="${TIMEOUT_CD_DELETE}s" 2>/dev/null || true
    delete_ms="$(wait_for_cd_deleted "${cd_name}" "${TIMEOUT_CD_DELETE}")"
    log_info "  Delete (full cleanup): ${delete_ms} ms"
    delete_times+=("${delete_ms}")

    # Verify owned resources are cleaned up (DaemonSets, RCTs, finalizers)
    remaining_rct="$(kubectl get resourceclaimtemplates -n "${NAMESPACE}" \
        -o name 2>/dev/null | grep "${cd_name}" || true)"
    if [[ -n "${remaining_rct}" ]]; then
        log_info "  Warning: lingering RCTs detected after deletion: ${remaining_rct}"
    fi

    # Total lifecycle time
    total_ms=$(( create_ms + ready_ms + delete_ms ))
    total_times+=("${total_ms}")
    log_info "  Total lifecycle: ${total_ms} ms"

    # Brief pause between iterations to let the controller settle
    sleep 2
done

# ---------------------------------------------------------------------------
# Compute statistics
# ---------------------------------------------------------------------------
create_file="$(mktemp /tmp/create-XXXXXX)"
ready_file="$(mktemp /tmp/ready-XXXXXX)"
delete_file="$(mktemp /tmp/delete-XXXXXX)"
total_file="$(mktemp /tmp/total-XXXXXX)"

printf '%s\n' "${create_times[@]}" > "${create_file}"
printf '%s\n' "${ready_times[@]}" > "${ready_file}"
printf '%s\n' "${delete_times[@]}" > "${delete_file}"
printf '%s\n' "${total_times[@]}" > "${total_file}"

compute_stats() {
    local file="$1"
    local p50 p95 p99 avg min_v max_v
    p50="$(cat "${file}" | percentile 50)"
    p95="$(cat "${file}" | percentile 95)"
    p99="$(cat "${file}" | percentile 99)"
    avg="$(awk '{s+=$1; n++} END{printf "%.0f", (n>0?s/n:0)}' "${file}")"
    min_v="$(sort -n "${file}" | head -1)"
    max_v="$(sort -n "${file}" | tail -1)"
    echo "{\"avg_ms\":${avg},\"p50_ms\":${p50},\"p95_ms\":${p95},\"p99_ms\":${p99},\"min_ms\":${min_v:-0},\"max_ms\":${max_v:-0}}"
}

create_stats="$(compute_stats "${create_file}")"
ready_stats="$(compute_stats "${ready_file}")"
delete_stats="$(compute_stats "${delete_file}")"
total_stats="$(compute_stats "${total_file}")"

# Build per-iteration JSON array
iter_json="["
for (( i=0; i<${#create_times[@]}; i++ )); do
    (( i > 0 )) && iter_json+=","
    iter_json+="{\"iteration\":$((i+1)),\"create_ms\":${create_times[$i]},\"ready_ms\":${ready_times[$i]},\"delete_ms\":${delete_times[$i]},\"total_ms\":${total_times[$i]}}"
done
iter_json+="]"

# ---------------------------------------------------------------------------
# Collect controller metrics
# ---------------------------------------------------------------------------
collect_controller_metrics "${RESULTS_DIR}/${TEST_NAME}-metrics.prom"
wq_metrics="$(extract_workqueue_metrics "${RESULTS_DIR}/${TEST_NAME}-metrics.prom")"

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------
rm -f "${create_file}" "${ready_file}" "${delete_file}" "${total_file}"

report_results "${TEST_NAME}" "$(cat <<EOJSON
{
  "config": {
    "iterations": ${ITERATIONS},
    "num_nodes": ${NUM_NODES}
  },
  "create_latency": ${create_stats},
  "ready_latency": ${ready_stats},
  "delete_latency": ${delete_stats},
  "total_lifecycle": ${total_stats},
  "iterations": ${iter_json},
  "workqueue_metrics": ${wq_metrics}
}
EOJSON
)"

log_info "=== ${TEST_NAME} complete ==="
