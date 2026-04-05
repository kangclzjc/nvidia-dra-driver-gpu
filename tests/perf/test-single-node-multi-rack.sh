#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# test-single-node-multi-rack.sh — Multi-rack simulation test using fake
# daemon Deployments on a single-node K8s cluster.
#
# Creates N racks × 18 nodes worth of simulated daemons, each with a unique
# clique-id, and measures CDClique creation, node registration, and workload
# pod scheduling at scale.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TEST_NAME="single-node-multi-rack"
CD_NAME="perf-sim-multi-rack"
NUM_RACKS=3
SIM_NODES_PER_RACK=18
DRIVER_NAMESPACE="nvidia-dra-driver"
FAKE_DAEMON_IMAGE="fake-compute-domain-daemon:perf"
WORKLOAD_IMAGE="registry.k8s.io/pause:3.9"
BATCH_SIZE=18
SAMPLE_INTERVAL=10
TIMEOUT_CD_READY=120
TIMEOUT_DAEMONS=600
TIMEOUT_CDCLIQUES=600
TIMEOUT_NODES_READY=900
TIMEOUT_PODS=900
NUM_NODES_SPEC=0
SKIP_WORKLOAD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --racks)            NUM_RACKS="$2";               shift 2 ;;
        --nodes-per-rack)   SIM_NODES_PER_RACK="$2";      shift 2 ;;
        --namespace)        NAMESPACE="$2";                shift 2 ;;
        --driver-namespace) DRIVER_NAMESPACE="$2";         shift 2 ;;
        --daemon-image)     FAKE_DAEMON_IMAGE="$2";        shift 2 ;;
        --cd-name)          CD_NAME="$2";                  shift 2 ;;
        --num-nodes)        NUM_NODES_SPEC="$2";           shift 2 ;;
        --batch)            BATCH_SIZE="$2";               shift 2 ;;
        --timeout-pods)     TIMEOUT_PODS="$2";             shift 2 ;;
        --timeout-daemons)  TIMEOUT_DAEMONS="$2";          shift 2 ;;
        --skip-workload)    SKIP_WORKLOAD=true;            shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Multi-rack simulation test."
            echo ""
            echo "Options:"
            echo "  --racks N              Number of racks (default: 3)"
            echo "  --nodes-per-rack M     Nodes per rack (default: 18)"
            echo "  --namespace NS         Test namespace (default: \$PERF_NAMESPACE or default)"
            echo "  --driver-namespace NS  Driver namespace (default: nvidia-dra-driver)"
            echo "  --daemon-image IMG     Fake daemon image"
            echo "  --cd-name NAME         ComputeDomain name (default: perf-sim-multi-rack)"
            echo "  --num-nodes N          CD spec numNodes (default: 0)"
            echo "  --batch N              Workload pod batch size (default: 18)"
            echo "  --timeout-pods SEC     Workload pod timeout (default: 900)"
            echo "  --timeout-daemons SEC  Daemon pod timeout (default: 600)"
            echo "  --skip-workload        Skip workload pod creation (only test daemon/clique)"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

SIM_NODES=$(( NUM_RACKS * SIM_NODES_PER_RACK ))

log_info "=== Test: ${TEST_NAME} ==="
log_info "  Racks:            ${NUM_RACKS}"
log_info "  Nodes per rack:   ${SIM_NODES_PER_RACK}"
log_info "  Total sim nodes:  ${SIM_NODES}"
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

# Get CD UID
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
log_info "Step 2: Creating ${SIM_NODES} simulated daemon Deployments (${NUM_RACKS} racks)"

daemon_create_start="$(now_ms)"
create_sim_daemon_pods "${CD_UID}" "${CD_NAME}" "${SIM_NODES}" "${SIM_NODES_PER_RACK}" \
    "${DRIVER_NAMESPACE}" "${FAKE_DAEMON_IMAGE}"
daemon_create_ms="$(elapsed_ms "${daemon_create_start}")"
log_info "Daemon Deployment creation: ${daemon_create_ms} ms"

# ---------------------------------------------------------------------------
# 3. Wait for all daemon pods Running
# ---------------------------------------------------------------------------
log_info "Step 3: Waiting for ${SIM_NODES} daemon pods to be Running"

daemon_running_start="$(now_ms)"
wait_for_sim_daemons_running "${SIM_NODES}" "${DRIVER_NAMESPACE}" "${TIMEOUT_DAEMONS}" >/dev/null
daemon_running_ms="$(elapsed_ms "${daemon_running_start}")"
log_info "All ${SIM_NODES} daemon pods Running: ${daemon_running_ms} ms"

# ---------------------------------------------------------------------------
# 4. Monitor CDClique creation
# ---------------------------------------------------------------------------
log_info "Step 4: Monitoring CDClique creation (expecting ${NUM_RACKS} cliques)"

cdclique_ms="$(wait_for_cdcliques "${NUM_RACKS}" "${NAMESPACE}" "${TIMEOUT_CDCLIQUES}")"
log_info "All ${NUM_RACKS} CDCliques created: ${cdclique_ms} ms"

# List CDCliques for reference
log_info "CDCliques:"
kubectl get computedomaincliques.${CD_API_GROUP} -n "${NAMESPACE}" --no-headers 2>/dev/null | \
    while read -r line; do log_info "  ${line}"; done

# ---------------------------------------------------------------------------
# 5. Wait for all nodes Ready
# ---------------------------------------------------------------------------
log_info "Step 5: Waiting for all ${SIM_NODES} nodes to be Ready in CD status"

nodes_ready_ms="$(wait_for_all_nodes_ready "${CD_NAME}" "${SIM_NODES}" "${NAMESPACE}" "${TIMEOUT_NODES_READY}")"
log_info "All ${SIM_NODES} nodes Ready: ${nodes_ready_ms} ms"

# ---------------------------------------------------------------------------
# 6. Collect pre-workload metrics
# ---------------------------------------------------------------------------
collect_controller_metrics "${RESULTS_DIR}/${TEST_NAME}-pre-metrics.prom"

# ---------------------------------------------------------------------------
# 7. Daemon pod startup latencies
# ---------------------------------------------------------------------------
log_info "Step 6: Computing daemon pod startup latencies"
daemon_latencies_file="$(mktemp /tmp/daemon-latencies-XXXXXX)"
get_pod_startup_latencies "app=sim-daemon" > "${daemon_latencies_file}"

daemon_pods_measured="$(wc -l < "${daemon_latencies_file}")"
daemon_p50="$(cat "${daemon_latencies_file}" | percentile 50)"
daemon_p95="$(cat "${daemon_latencies_file}" | percentile 95)"
daemon_p99="$(cat "${daemon_latencies_file}" | percentile 99)"
daemon_p_min="$(sort -n "${daemon_latencies_file}" | head -1)"
daemon_p_max="$(sort -n "${daemon_latencies_file}" | tail -1)"

log_info "Daemon startup latency: P50=${daemon_p50}ms P95=${daemon_p95}ms P99=${daemon_p99}ms (n=${daemon_pods_measured})"
rm -f "${daemon_latencies_file}"

# ---------------------------------------------------------------------------
# 8. Workload pods (optional)
# ---------------------------------------------------------------------------
workload_json="{}"
if [[ "${SKIP_WORKLOAD}" != "true" ]]; then
    log_info "Step 7: Creating ${SIM_NODES} workload pods"

    pod_create_start="$(now_ms)"
    create_workload_pods "${CD_NAME}" "${SIM_NODES}" "${BATCH_SIZE}" "${WORKLOAD_IMAGE}"
    pod_create_ms="$(elapsed_ms "${pod_create_start}")"
    log_info "Workload pod creation: ${pod_create_ms} ms"

    log_info "Step 8: Monitoring pod scheduling progress"
    progress_json="$(monitor_pod_progress "cd-name=${CD_NAME}" "${SIM_NODES}" "${SAMPLE_INTERVAL}" "${TIMEOUT_PODS}")"

    all_running_ms="$(wait_for_pods_running "cd-name=${CD_NAME}" "${SIM_NODES}" "${TIMEOUT_PODS}")"
    log_info "All ${SIM_NODES} workload pods Running: ${all_running_ms} ms"

    log_info "Step 9: Computing workload pod startup latencies"
    latencies_file="$(mktemp /tmp/latencies-XXXXXX)"
    get_pod_startup_latencies "cd-name=${CD_NAME}" > "${latencies_file}"

    total_pods_measured="$(wc -l < "${latencies_file}")"
    p50="$(cat "${latencies_file}" | percentile 50)"
    p95="$(cat "${latencies_file}" | percentile 95)"
    p99="$(cat "${latencies_file}" | percentile 99)"
    p_min="$(sort -n "${latencies_file}" | head -1)"
    p_max="$(sort -n "${latencies_file}" | tail -1)"

    if (( all_running_ms > 0 )); then
        throughput="$(echo "scale=2; ${SIM_NODES} * 1000 / ${all_running_ms}" | bc)"
    else
        throughput="0"
    fi

    rm -f "${latencies_file}"

    workload_json="$(cat <<EOWL
{
    "pod_create_ms": ${pod_create_ms},
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
    "scheduling_progress": ${progress_json}
  }
EOWL
)"
else
    log_info "Step 7: Skipping workload pod creation (--skip-workload)"
fi

# ---------------------------------------------------------------------------
# 9. Collect post-workload metrics
# ---------------------------------------------------------------------------
collect_controller_metrics "${RESULTS_DIR}/${TEST_NAME}-post-metrics.prom"
wq_metrics="$(extract_workqueue_metrics "${RESULTS_DIR}/${TEST_NAME}-post-metrics.prom")"

# ---------------------------------------------------------------------------
# 10. Per-rack timing breakdown
# ---------------------------------------------------------------------------
log_info "Step 10: Computing per-rack CDClique timing"
rack_timings="["
for (( r=0; r<NUM_RACKS; r++ )); do
    rack_daemon_count="$(kubectl get pods -n "${DRIVER_NAMESPACE}" -l "rack-id=${r},app=sim-daemon" \
        --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
    (( r > 0 )) && rack_timings+=","
    rack_timings+="{\"rack_id\":${r},\"running_daemons\":${rack_daemon_count}}"
done
rack_timings+="]"

# ---------------------------------------------------------------------------
# 11. Report results
# ---------------------------------------------------------------------------
report_results "${TEST_NAME}" "$(cat <<EOJSON
{
  "config": {
    "mode": "single-node-simulation",
    "cd_name": "${CD_NAME}",
    "num_racks": ${NUM_RACKS},
    "sim_nodes": ${SIM_NODES},
    "nodes_per_rack": ${SIM_NODES_PER_RACK},
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
    "all_nodes_ready_ms": ${nodes_ready_ms}
  },
  "daemon_pod_startup_latency": {
    "count": ${daemon_pods_measured},
    "p50_ms": ${daemon_p50},
    "p95_ms": ${daemon_p95},
    "p99_ms": ${daemon_p99},
    "min_ms": ${daemon_p_min:-0},
    "max_ms": ${daemon_p_max:-0}
  },
  "rack_breakdown": ${rack_timings},
  "workload": ${workload_json},
  "workqueue_metrics": ${wq_metrics}
}
EOJSON
)"

log_info "=== ${TEST_NAME} complete ==="
