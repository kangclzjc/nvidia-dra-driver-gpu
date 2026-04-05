#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# test-multi-cd.sh — Multiple ComputeDomains with independent workloads.
# Measures: CD Ready latency distribution, total pod scheduling time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TEST_NAME="multi-cd"
NUM_CDS=10             # Default: 10 CDs (safe for 4vCPU/16GB). Use --num-cds 50 for large machines.
PODS_PER_CD=18         # 1 rack per CD (aligned to rack size)
NUM_NODES=0
TIMEOUT_CD_READY=300
TIMEOUT_PODS=600
CD_PREFIX="perf-mcd"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --num-cds)     NUM_CDS="$2";       shift 2 ;;
        --pods-per-cd) PODS_PER_CD="$(align_to_rack_size "$2")"; shift 2 ;;
        --num-nodes)   NUM_NODES="$2";     shift 2 ;;
        --namespace)   NAMESPACE="$2";     shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--num-cds N] [--pods-per-cd M] [--num-nodes N] [--namespace NS]"
            echo ""
            echo "GB200 NVL72: --pods-per-cd auto-aligns to 18 (nodes per rack)"
            echo "  Default: 50 CDs × 36 pods/CD = 1800 pods (50 CDs, 2 racks each)"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

TOTAL_PODS=$(( NUM_CDS * PODS_PER_CD ))
RACKS_PER_CD="$(num_racks ${PODS_PER_CD})"
TOTAL_RACKS=$(( NUM_CDS * RACKS_PER_CD ))

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
trap 'log_info "Cleaning up ${TEST_NAME}"; cleanup' EXIT

# ---------------------------------------------------------------------------
# 1. Concurrently create all ComputeDomains
# ---------------------------------------------------------------------------
log_info "=== Test: ${TEST_NAME} ==="
log_info "Creating ${NUM_CDS} ComputeDomains, each with ${PODS_PER_CD} pods (${RACKS_PER_CD} racks/CD)"
log_info "Total: ${TOTAL_PODS} pods across ${TOTAL_RACKS} racks"

cd_create_start="$(now_ms)"

for (( i=0; i<NUM_CDS; i++ )); do
    cd_name="${CD_PREFIX}-$(printf '%03d' ${i})"
    create_cd "${cd_name}" "${NUM_NODES}" &
done
# Wait for all create_cd background jobs
wait
cd_create_ms="$(elapsed_ms "${cd_create_start}")"
log_info "All ${NUM_CDS} CDs created in ${cd_create_ms} ms"

# ---------------------------------------------------------------------------
# 2. Wait for each CD to become Ready, measure individual latencies
# ---------------------------------------------------------------------------
log_info "Waiting for all CDs to become Ready"
cd_ready_latencies_file="$(mktemp /tmp/cd-ready-XXXXXX)"

cd_ready_start="$(now_ms)"
pids=()
for (( i=0; i<NUM_CDS; i++ )); do
    cd_name="${CD_PREFIX}-$(printf '%03d' ${i})"
    (
        ms="$(wait_for_cd_ready "${cd_name}" "${TIMEOUT_CD_READY}" 2>/dev/null)"
        echo "${ms}" >> "${cd_ready_latencies_file}"
    ) &
    pids+=($!)
done

# Wait for all background ready-waiters
failed=0
for pid in "${pids[@]}"; do
    if ! wait "${pid}" 2>/dev/null; then
        (( failed++ )) || true
    fi
done

cd_ready_total_ms="$(elapsed_ms "${cd_ready_start}")"

if (( failed > 0 )); then
    log_error "${failed}/${NUM_CDS} CDs failed to become Ready"
fi

# Compute CD Ready latency percentiles
cd_count="$(wc -l < "${cd_ready_latencies_file}")"
cd_p50="$(cat "${cd_ready_latencies_file}" | percentile 50)"
cd_p95="$(cat "${cd_ready_latencies_file}" | percentile 95)"
cd_p99="$(cat "${cd_ready_latencies_file}" | percentile 99)"
cd_max="$(sort -n "${cd_ready_latencies_file}" | tail -1)"
cd_min="$(sort -n "${cd_ready_latencies_file}" | head -1)"

log_info "CD Ready latency: P50=${cd_p50}ms P95=${cd_p95}ms P99=${cd_p99}ms Max=${cd_max}ms (n=${cd_count})"

# ---------------------------------------------------------------------------
# 3. Create workload pods for each CD
# ---------------------------------------------------------------------------
log_info "Creating workload pods (${PODS_PER_CD} per CD)"
pod_create_start="$(now_ms)"

for (( i=0; i<NUM_CDS; i++ )); do
    cd_name="${CD_PREFIX}-$(printf '%03d' ${i})"
    create_workload_pods "${cd_name}" "${PODS_PER_CD}" "${PODS_PER_CD}" &
done
wait

pod_create_ms="$(elapsed_ms "${pod_create_start}")"
log_info "Pod creation completed in ${pod_create_ms} ms"

# ---------------------------------------------------------------------------
# 4. Wait for all pods to be Running
# ---------------------------------------------------------------------------
all_running_ms="$(wait_for_pods_running "perf-test=true" "${TOTAL_PODS}" "${TIMEOUT_PODS}")"
log_info "All ${TOTAL_PODS} pods Running in ${all_running_ms} ms"

# ---------------------------------------------------------------------------
# 5. Compute per-pod startup latencies
# ---------------------------------------------------------------------------
log_info "Computing pod startup latencies"
pod_latencies_file="$(mktemp /tmp/pod-latencies-XXXXXX)"
get_pod_startup_latencies "perf-test=true" > "${pod_latencies_file}"

pod_count="$(wc -l < "${pod_latencies_file}")"
pod_p50="$(cat "${pod_latencies_file}" | percentile 50)"
pod_p95="$(cat "${pod_latencies_file}" | percentile 95)"
pod_p99="$(cat "${pod_latencies_file}" | percentile 99)"
pod_max="$(sort -n "${pod_latencies_file}" | tail -1)"

# Throughput
if (( all_running_ms > 0 )); then
    throughput="$(echo "scale=2; ${TOTAL_PODS} * 1000 / ${all_running_ms}" | bc)"
else
    throughput="0"
fi

# ---------------------------------------------------------------------------
# 6. Collect controller metrics
# ---------------------------------------------------------------------------
collect_controller_metrics "${RESULTS_DIR}/${TEST_NAME}-metrics.prom"
wq_metrics="$(extract_workqueue_metrics "${RESULTS_DIR}/${TEST_NAME}-metrics.prom")"

# ---------------------------------------------------------------------------
# 7. Report results
# ---------------------------------------------------------------------------
rm -f "${cd_ready_latencies_file}" "${pod_latencies_file}"

report_results "${TEST_NAME}" "$(cat <<EOJSON
{
  "config": {
    "num_cds": ${NUM_CDS},
    "pods_per_cd": ${PODS_PER_CD},
    "total_pods": ${TOTAL_PODS},
    "num_nodes": ${NUM_NODES}
  },
  "cd_creation_time_ms": ${cd_create_ms},
  "cd_ready_total_time_ms": ${cd_ready_total_ms},
  "cd_ready_latency": {
    "count": ${cd_count},
    "failed": ${failed},
    "p50_ms": ${cd_p50},
    "p95_ms": ${cd_p95},
    "p99_ms": ${cd_p99},
    "min_ms": ${cd_min:-0},
    "max_ms": ${cd_max:-0}
  },
  "pod_creation_time_ms": ${pod_create_ms},
  "all_pods_running_ms": ${all_running_ms},
  "throughput_pods_per_sec": ${throughput},
  "pod_startup_latency": {
    "count": ${pod_count},
    "p50_ms": ${pod_p50},
    "p95_ms": ${pod_p95},
    "p99_ms": ${pod_p99},
    "max_ms": ${pod_max:-0}
  },
  "workqueue_metrics": ${wq_metrics}
}
EOJSON
)"

log_info "=== ${TEST_NAME} complete ==="
