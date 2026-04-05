#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# test-single-node-rack.sh — Single-rack (18 nodes) test using simulated
# daemon Deployments on a single-node K8s cluster.
#
# Measures: CD creation latency, daemon pod scheduling, CDClique creation,
# all-nodes-ready latency, workload pod scheduling, and per-pod startup
# latency (P50/P95/P99).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TEST_NAME="single-node-rack"
CD_NAME="perf-sim-rack"
SIM_NODES=18               # 1 rack = 18 nodes
SIM_NODES_PER_RACK=18
DRIVER_NAMESPACE="nvidia-dra-driver"
FAKE_DAEMON_IMAGE="fake-compute-domain-daemon:perf"
WORKLOAD_IMAGE="registry.k8s.io/pause:3.9"
SAMPLE_INTERVAL=5
TIMEOUT_CD_READY=120
TIMEOUT_DAEMONS=300
TIMEOUT_CDCLIQUES=300
TIMEOUT_NODES_READY=600
TIMEOUT_PODS=600
NUM_NODES_SPEC=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sim-nodes)        SIM_NODES="$2";              shift 2 ;;
        --nodes-per-rack)   SIM_NODES_PER_RACK="$2";     shift 2 ;;
        --namespace)        NAMESPACE="$2";               shift 2 ;;
        --driver-namespace) DRIVER_NAMESPACE="$2";        shift 2 ;;
        --daemon-image)     FAKE_DAEMON_IMAGE="$2";       shift 2 ;;
        --cd-name)          CD_NAME="$2";                 shift 2 ;;
        --num-nodes)        NUM_NODES_SPEC="$2";          shift 2 ;;
        --timeout-pods)     TIMEOUT_PODS="$2";            shift 2 ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Single-rack simulation test (default: 18 nodes, 1 rack)."
            echo ""
            echo "Options:"
            echo "  --sim-nodes N          Simulated nodes (default: 18)"
            echo "  --nodes-per-rack M     Nodes per rack (default: 18)"
            echo "  --namespace NS         Test namespace (default: \$PERF_NAMESPACE or default)"
            echo "  --driver-namespace NS  Driver namespace (default: nvidia-dra-driver)"
            echo "  --daemon-image IMG     Fake daemon image"
            echo "  --cd-name NAME         ComputeDomain name (default: perf-sim-rack)"
            echo "  --num-nodes N          CD spec numNodes (default: 0)"
            echo "  --timeout-pods SEC     Workload pod timeout (default: 600)"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

NUM_RACKS=$(( (SIM_NODES + SIM_NODES_PER_RACK - 1) / SIM_NODES_PER_RACK ))

log_info "=== Test: ${TEST_NAME} ==="
log_info "  Simulated nodes:  ${SIM_NODES}"
log_info "  Racks:            ${NUM_RACKS}"
log_info "  Nodes per rack:   ${SIM_NODES_PER_RACK}"
log_info "  Namespace:        ${NAMESPACE}"

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
trap 'log_info "Cleaning up ${TEST_NAME}"; cleanup_single_node "${NAMESPACE}"' EXIT

# ---------------------------------------------------------------------------
# 1. Create ComputeDomain
# ---------------------------------------------------------------------------
log_info "Step 1: Creating ComputeDomain ${CD_NAME}"

cd_create_start="$(now_ms)"
create_cd "${CD_NAME}" "${NUM_NODES_SPEC}"
cd_create_ms="$(elapsed_ms "${cd_create_start}")"
log_info "CD creation API call: ${cd_create_ms} ms"

# Get CD UID for daemon pods
sleep 2
CD_UID="$(get_cd_uid "${CD_NAME}" "${NAMESPACE}")"
if [[ -z "${CD_UID}" ]]; then
    log_error "Failed to get UID for ComputeDomain ${CD_NAME}"
    exit 1
fi
log_info "ComputeDomain UID: ${CD_UID}"

# ---------------------------------------------------------------------------
# 2. Create simulated daemon Deployments
# ---------------------------------------------------------------------------
log_info "Step 2: Creating ${SIM_NODES} simulated daemon Deployments"

daemon_create_start="$(now_ms)"
create_sim_daemon_pods "${CD_UID}" "${CD_NAME}" "${SIM_NODES}" "${SIM_NODES_PER_RACK}" \
    "${DRIVER_NAMESPACE}" "${FAKE_DAEMON_IMAGE}"
daemon_create_ms="$(elapsed_ms "${daemon_create_start}")"
log_info "Daemon Deployment creation: ${daemon_create_ms} ms"

# ---------------------------------------------------------------------------
# 3. Wait for all daemon pods to be Running
# ---------------------------------------------------------------------------
log_info "Step 3: Waiting for daemon pods to be Running"

daemon_running_start="$(now_ms)"
wait_for_sim_daemons_running "${SIM_NODES}" "${DRIVER_NAMESPACE}" "${TIMEOUT_DAEMONS}" >/dev/null
daemon_running_ms="$(elapsed_ms "${daemon_running_start}")"
log_info "All ${SIM_NODES} daemon pods Running: ${daemon_running_ms} ms"

# ---------------------------------------------------------------------------
# 4. Monitor CDClique creation
# ---------------------------------------------------------------------------
log_info "Step 4: Monitoring CDClique creation (expecting ${NUM_RACKS} cliques)"

cdclique_ms="$(wait_for_cdcliques "${NUM_RACKS}" "${NAMESPACE}" "${TIMEOUT_CDCLIQUES}")"
log_info "CDCliques created: ${cdclique_ms} ms"

# ---------------------------------------------------------------------------
# 5. Wait for all nodes Ready in CD status
# ---------------------------------------------------------------------------
log_info "Step 5: Waiting for all ${SIM_NODES} nodes to be Ready in CD status"

nodes_ready_ms="$(wait_for_all_nodes_ready "${CD_NAME}" "${SIM_NODES}" "${NAMESPACE}" "${TIMEOUT_NODES_READY}")"
log_info "All nodes Ready: ${nodes_ready_ms} ms"

# ---------------------------------------------------------------------------
# 6. Collect pre-workload controller metrics
# ---------------------------------------------------------------------------
collect_controller_metrics "${RESULTS_DIR}/${TEST_NAME}-pre-metrics.prom"

# ---------------------------------------------------------------------------
# 7. Create workload pods
# ---------------------------------------------------------------------------
log_info "Step 6: Creating ${SIM_NODES} workload pods"

pod_create_start="$(now_ms)"
create_workload_pods "${CD_NAME}" "${SIM_NODES}" "${SIM_NODES_PER_RACK}" "${WORKLOAD_IMAGE}"
pod_create_ms="$(elapsed_ms "${pod_create_start}")"
log_info "Workload pod creation: ${pod_create_ms} ms"

# ---------------------------------------------------------------------------
# 8. Monitor scheduling progress
# ---------------------------------------------------------------------------
log_info "Step 7: Monitoring pod scheduling progress"
progress_json="$(monitor_pod_progress "cd-name=${CD_NAME}" "${SIM_NODES}" "${SAMPLE_INTERVAL}" "${TIMEOUT_PODS}")"

# ---------------------------------------------------------------------------
# 9. Wait for all pods Running
# ---------------------------------------------------------------------------
all_running_ms="$(wait_for_pods_running "cd-name=${CD_NAME}" "${SIM_NODES}" "${TIMEOUT_PODS}")"
log_info "All ${SIM_NODES} workload pods Running: ${all_running_ms} ms"

# ---------------------------------------------------------------------------
# 10. Compute pod startup latencies
# ---------------------------------------------------------------------------
log_info "Step 8: Computing per-pod startup latencies"
latencies_file="$(mktemp /tmp/latencies-XXXXXX)"
get_pod_startup_latencies "cd-name=${CD_NAME}" > "${latencies_file}"

total_pods_measured="$(wc -l < "${latencies_file}")"
p50="$(cat "${latencies_file}" | percentile 50)"
p95="$(cat "${latencies_file}" | percentile 95)"
p99="$(cat "${latencies_file}" | percentile 99)"
p_min="$(sort -n "${latencies_file}" | head -1)"
p_max="$(sort -n "${latencies_file}" | tail -1)"

log_info "Pod startup latency: P50=${p50}ms P95=${p95}ms P99=${p99}ms Min=${p_min}ms Max=${p_max}ms (n=${total_pods_measured})"

# Throughput
if (( all_running_ms > 0 )); then
    throughput="$(echo "scale=2; ${SIM_NODES} * 1000 / ${all_running_ms}" | bc)"
else
    throughput="0"
fi

# ---------------------------------------------------------------------------
# 11. Collect post-workload controller metrics
# ---------------------------------------------------------------------------
collect_controller_metrics "${RESULTS_DIR}/${TEST_NAME}-post-metrics.prom"
wq_metrics="$(extract_workqueue_metrics "${RESULTS_DIR}/${TEST_NAME}-post-metrics.prom")"

# ---------------------------------------------------------------------------
# 12. Collect daemon pod startup latencies
# ---------------------------------------------------------------------------
log_info "Step 9: Computing daemon pod startup latencies"
daemon_latencies_file="$(mktemp /tmp/daemon-latencies-XXXXXX)"
get_pod_startup_latencies "app=sim-daemon" > "${daemon_latencies_file}"

daemon_pods_measured="$(wc -l < "${daemon_latencies_file}")"
daemon_p50="$(cat "${daemon_latencies_file}" | percentile 50)"
daemon_p95="$(cat "${daemon_latencies_file}" | percentile 95)"
daemon_p99="$(cat "${daemon_latencies_file}" | percentile 99)"
daemon_p_min="$(sort -n "${daemon_latencies_file}" | head -1)"
daemon_p_max="$(sort -n "${daemon_latencies_file}" | tail -1)"

log_info "Daemon startup latency: P50=${daemon_p50}ms P95=${daemon_p95}ms P99=${daemon_p99}ms (n=${daemon_pods_measured})"

rm -f "${latencies_file}" "${daemon_latencies_file}"

# ---------------------------------------------------------------------------
# 13. Report results
# ---------------------------------------------------------------------------
# Calculate total end-to-end time from CD creation to all workload pods running
total_e2e_ms=$(( cd_create_ms + daemon_create_ms + daemon_running_ms + pod_create_ms + all_running_ms ))

report_results "${TEST_NAME}" "$(cat <<EOJSON
{
  "config": {
    "mode": "single-node-simulation",
    "cd_name": "${CD_NAME}",
    "sim_nodes": ${SIM_NODES},
    "nodes_per_rack": ${SIM_NODES_PER_RACK},
    "num_racks": ${NUM_RACKS},
    "topology": {
      "platform": "GB200_NVL72",
      "nodes_per_rack": ${SIM_NODES_PER_RACK},
      "gpus_per_node": ${GPUS_PER_NODE},
      "gpus_per_rack": ${GPUS_PER_RACK}
    }
  },
  "timings": {
    "cd_create_ms": ${cd_create_ms},
    "daemon_deploy_create_ms": ${daemon_create_ms},
    "daemon_pods_running_ms": ${daemon_running_ms},
    "cdcliques_created_ms": ${cdclique_ms},
    "all_nodes_ready_ms": ${nodes_ready_ms},
    "workload_pod_create_ms": ${pod_create_ms},
    "all_workload_pods_running_ms": ${all_running_ms},
    "total_e2e_ms": ${total_e2e_ms}
  },
  "workload_pod_startup_latency": {
    "count": ${total_pods_measured},
    "p50_ms": ${p50},
    "p95_ms": ${p95},
    "p99_ms": ${p99},
    "min_ms": ${p_min:-0},
    "max_ms": ${p_max:-0}
  },
  "daemon_pod_startup_latency": {
    "count": ${daemon_pods_measured},
    "p50_ms": ${daemon_p50},
    "p95_ms": ${daemon_p95},
    "p99_ms": ${daemon_p99},
    "min_ms": ${daemon_p_min:-0},
    "max_ms": ${daemon_p_max:-0}
  },
  "throughput_pods_per_sec": ${throughput},
  "scheduling_progress": ${progress_json},
  "workqueue_metrics": ${wq_metrics}
}
EOJSON
)"

log_info "=== ${TEST_NAME} complete ==="
