#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# test-single-cd-2000-pods.sh — 2000 pods sharing a single ComputeDomain.
# Measures: CD Ready latency, pod scheduling throughput, P50/P95/P99 pod startup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TEST_NAME="single-cd-2000-pods"
CD_NAME="perf-single-cd"

# GB200 NVL72 topology: 18 nodes/rack, 4 GPUs/node
# Default: 54 pods = 3 racks × 18 nodes (safe for 4vCPU/16GB machines)
# For large machines: --pods 2016 (112 racks)
NUM_PODS=54            # aligned to rack size (18 × 3)
BATCH_SIZE=18          # one rack per batch (natural scheduling unit)
NUM_NODES=0
SAMPLE_INTERVAL=10  # seconds between progress samples
TIMEOUT_CD_READY=120
TIMEOUT_PODS=600

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pods)       NUM_PODS="$(align_to_rack_size "$2")"; shift 2 ;;
        --batch)      BATCH_SIZE="$2";        shift 2 ;;
        --num-nodes)  NUM_NODES="$2";         shift 2 ;;
        --namespace)  NAMESPACE="$2";         shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--pods N] [--batch N] [--num-nodes N] [--namespace NS]"
            echo ""
            echo "GB200 NVL72 topology: 18 nodes/rack, 4 GPUs/node"
            echo "  --pods will be rounded up to nearest multiple of 18"
            echo "  Default: 2016 pods (112 racks × 18 nodes)"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

RACKS_NEEDED="$(num_racks ${NUM_PODS})"
log_info "GB200 topology: ${NUM_PODS} pods = ${RACKS_NEEDED} racks × ${NODES_PER_RACK} nodes/rack"

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
trap 'log_info "Cleaning up ${TEST_NAME}"; cleanup' EXIT

# ---------------------------------------------------------------------------
# 1. Create ComputeDomain
# ---------------------------------------------------------------------------
log_info "=== Test: ${TEST_NAME} ==="
log_info "Creating ComputeDomain ${CD_NAME} with numNodes=${NUM_NODES}"

cd_ready_ms="$(measure_latency "CD creation + Ready" bash -c "
    source '${SCRIPT_DIR}/common.sh'
    create_cd '${CD_NAME}' '${NUM_NODES}'
    wait_for_cd_ready '${CD_NAME}' '${TIMEOUT_CD_READY}'
")"

log_info "CD Ready latency: ${cd_ready_ms} ms"

# ---------------------------------------------------------------------------
# 2. Collect pre-workload controller metrics
# ---------------------------------------------------------------------------
collect_controller_metrics "${RESULTS_DIR}/${TEST_NAME}-pre-metrics.prom"

# ---------------------------------------------------------------------------
# 3. Create workload pods in batches
# ---------------------------------------------------------------------------
log_info "Creating ${NUM_PODS} workload pods in batches of ${BATCH_SIZE}"
pod_create_start="$(now_ms)"
create_workload_pods "${CD_NAME}" "${NUM_PODS}" "${BATCH_SIZE}"
pod_create_ms="$(elapsed_ms "${pod_create_start}")"
log_info "Pod creation completed in ${pod_create_ms} ms"

# ---------------------------------------------------------------------------
# 4. Monitor scheduling progress
# ---------------------------------------------------------------------------
log_info "Monitoring pod scheduling progress (sample every ${SAMPLE_INTERVAL}s)"
progress_json="$(monitor_pod_progress "cd-name=${CD_NAME}" "${NUM_PODS}" "${SAMPLE_INTERVAL}" "${TIMEOUT_PODS}")"

# ---------------------------------------------------------------------------
# 5. Wait for all pods to be Running
# ---------------------------------------------------------------------------
all_running_ms="$(wait_for_pods_running "cd-name=${CD_NAME}" "${NUM_PODS}" "${TIMEOUT_PODS}")"
log_info "All ${NUM_PODS} pods Running in ${all_running_ms} ms"

# ---------------------------------------------------------------------------
# 6. Compute pod startup latencies
# ---------------------------------------------------------------------------
log_info "Computing per-pod startup latencies"
latencies_file="$(mktemp /tmp/latencies-XXXXXX)"
get_pod_startup_latencies "cd-name=${CD_NAME}" > "${latencies_file}"

total_pods_measured="$(wc -l < "${latencies_file}")"
p50="$(cat "${latencies_file}" | percentile 50)"
p95="$(cat "${latencies_file}" | percentile 95)"
p99="$(cat "${latencies_file}" | percentile 99)"
p_min="$(sort -n "${latencies_file}" | head -1)"
p_max="$(sort -n "${latencies_file}" | tail -1)"

log_info "Pod startup latency: P50=${p50}ms P95=${p95}ms P99=${p99}ms Min=${p_min}ms Max=${p_max}ms (n=${total_pods_measured})"

# Compute throughput (pods/sec)
if (( all_running_ms > 0 )); then
    throughput="$(echo "scale=2; ${NUM_PODS} * 1000 / ${all_running_ms}" | bc)"
else
    throughput="0"
fi

# ---------------------------------------------------------------------------
# 7. Collect post-workload controller metrics
# ---------------------------------------------------------------------------
collect_controller_metrics "${RESULTS_DIR}/${TEST_NAME}-post-metrics.prom"
wq_metrics="$(extract_workqueue_metrics "${RESULTS_DIR}/${TEST_NAME}-post-metrics.prom")"

# ---------------------------------------------------------------------------
# 8. Report results
# ---------------------------------------------------------------------------
rm -f "${latencies_file}"

report_results "${TEST_NAME}" "$(cat <<EOJSON
{
  "config": {
    "cd_name": "${CD_NAME}",
    "num_pods": ${NUM_PODS},
    "batch_size": ${BATCH_SIZE},
    "num_nodes": ${NUM_NODES},
    "topology": {
      "platform": "GB200_NVL72",
      "nodes_per_rack": ${NODES_PER_RACK},
      "gpus_per_node": ${GPUS_PER_NODE},
      "gpus_per_rack": ${GPUS_PER_RACK},
      "racks_needed": ${RACKS_NEEDED}
    }
  },
  "cd_ready_latency_ms": ${cd_ready_ms},
  "pod_creation_time_ms": ${pod_create_ms},
  "all_pods_running_ms": ${all_running_ms},
  "throughput_pods_per_sec": ${throughput},
  "pod_startup_latency": {
    "count": ${total_pods_measured},
    "p50_ms": ${p50},
    "p95_ms": ${p95},
    "p99_ms": ${p99},
    "min_ms": ${p_min:-0},
    "max_ms": ${p_max:-0}
  },
  "scheduling_progress": ${progress_json},
  "workqueue_metrics": ${wq_metrics}
}
EOJSON
)"

log_info "=== ${TEST_NAME} complete ==="
