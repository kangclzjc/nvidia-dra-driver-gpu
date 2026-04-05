#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# test-dryrun-rack.sh — Rack-level test using real compute-domain-daemon
# in --dry-run mode. Supports two modes:
#   kind  — Uses DaemonSet (controller-managed) with real scheduling
#   sim   — Uses sim-spawner-style Deployments (single-node simulation)
#
# Measures: CD creation, daemon pod scheduling, CDClique registration,
# DNS negotiation, all-nodes-ready latency.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Helper: create dry-run sim daemon Deployments (real daemon + --dry-run)
# Unlike create_sim_daemon_pods in common.sh, this uses the real daemon image
# with --dry-run flag instead of the fake daemon.
# ---------------------------------------------------------------------------
create_dryrun_sim_daemon_pods() {
    local cd_uid="${1:?cd uid required}"
    local cd_name="${2:?cd name required}"
    local num_nodes="${3:?num nodes required}"
    local nodes_per_rack="${4:-${NODES_PER_RACK}}"
    local ns="${5:-${NAMESPACE}}"
    local image="${6:-compute-domain-daemon:dryrun}"

    local total_racks=$(( (num_nodes + nodes_per_rack - 1) / nodes_per_rack ))
    local chunk_size=10
    local parallel_jobs=8
    log_info "Creating ${num_nodes} dry-run daemon Deployments (${total_racks} racks, ${nodes_per_rack} nodes/rack)"

    local chunk_dir
    chunk_dir="$(mktemp -d /tmp/dryrun-daemon-chunks-XXXXXX)"
    local chunk_index=0
    local items_in_chunk=0
    local current_chunk="${chunk_dir}/chunk-$(printf '%04d' ${chunk_index}).yaml"

    for (( i=0; i<num_nodes; i++ )); do
        local rack_id=$(( i / nodes_per_rack ))
        local sim_node="sim-node-$(printf '%04d' ${i})"
        local clique_id="clique-${rack_id}"
        local deploy_name="sim-daemon-$(printf '%04d' ${i})"

        cat >> "${current_chunk}" << YAMEOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${deploy_name}
  namespace: ${ns}
  labels:
    app: sim-daemon
    perf-sim: "true"
    perf-dryrun: "true"
    cd-name: ${cd_name}
    rack-id: "${rack_id}"
    sim-node: ${sim_node}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sim-daemon
      sim-node: ${sim_node}
  template:
    metadata:
      labels:
        app: sim-daemon
        perf-sim: "true"
        perf-dryrun: "true"
        cd-name: ${cd_name}
        rack-id: "${rack_id}"
        sim-node: ${sim_node}
    spec:
      serviceAccountName: nvidia-dra-driver-gpu-compute-domain-daemon
      terminationGracePeriodSeconds: 5
      containers:
      - name: daemon
        image: ${image}
        imagePullPolicy: IfNotPresent
        command: ["compute-domain-daemon", "-v", "2", "--dry-run", "run"]
        env:
        - name: COMPUTE_DOMAIN_UUID
          value: "${cd_uid}"
        - name: COMPUTE_DOMAIN_NAME
          value: "${cd_name}"
        - name: COMPUTE_DOMAIN_NAMESPACE
          value: "${ns}"
        - name: NODE_NAME
          value: "${sim_node}"
        - name: CLIQUE_ID
          value: "${clique_id}"
        - name: MAX_NODES_PER_IMEX_DOMAIN
          value: "${nodes_per_rack}"
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: POD_UID
          valueFrom:
            fieldRef:
              fieldPath: metadata.uid
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        livenessProbe:
          exec:
            command: ["compute-domain-daemon", "--dry-run", "check"]
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          exec:
            command: ["compute-domain-daemon", "--dry-run", "check"]
          initialDelaySeconds: 5
          periodSeconds: 10
YAMEOF
        items_in_chunk=$(( items_in_chunk + 1 ))
        if (( items_in_chunk >= chunk_size && i < num_nodes - 1 )); then
            chunk_index=$(( chunk_index + 1 ))
            current_chunk="${chunk_dir}/chunk-$(printf '%04d' ${chunk_index}).yaml"
            items_in_chunk=0
        fi
    done

    local total_chunks=$(( chunk_index + 1 ))
    log_info "Parallel applying ${num_nodes} dry-run daemon Deployments (${total_chunks} chunks, ${parallel_jobs} parallel jobs)..."
    # shellcheck disable=SC2012
    ls "${chunk_dir}"/*.yaml | xargs -P "${parallel_jobs}" -I {} kubectl apply -f {} 2>/dev/null
    local apply_rc=$?

    rm -rf "${chunk_dir}"

    if (( apply_rc != 0 )); then
        log_error "Some parallel kubectl apply jobs failed (rc=${apply_rc})"
        return "${apply_rc}"
    fi

    log_info "All ${num_nodes} dry-run daemon Deployments created"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TEST_NAME="dryrun-rack"
CD_NAME="perf-dryrun-rack"
NUM_RACKS=1
SIM_NODES_PER_RACK=18
MODE="sim"               # kind | sim
DRIVER_NAMESPACE="nvidia-dra-driver"
DRYRUN_DAEMON_IMAGE="compute-domain-daemon:dryrun"
SAMPLE_INTERVAL=5
TIMEOUT_DAEMONS=600
TIMEOUT_CDCLIQUES=600
TIMEOUT_NODES_READY=900
NUM_NODES_SPEC=0
SKIP_CLEANUP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --racks)            NUM_RACKS="$2";               shift 2 ;;
        --nodes-per-rack)   SIM_NODES_PER_RACK="$2";      shift 2 ;;
        --mode)             MODE="$2";                     shift 2 ;;
        --namespace)        NAMESPACE="$2";                shift 2 ;;
        --driver-namespace) DRIVER_NAMESPACE="$2";         shift 2 ;;
        --daemon-image)     DRYRUN_DAEMON_IMAGE="$2";      shift 2 ;;
        --cd-name)          CD_NAME="$2";                  shift 2 ;;
        --num-nodes)        NUM_NODES_SPEC="$2";           shift 2 ;;
        --timeout-daemons)  TIMEOUT_DAEMONS="$2";          shift 2 ;;
        --skip-cleanup)     SKIP_CLEANUP=true;             shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Dry-run daemon rack test. Measures CD → daemon → CDClique → Ready."
            echo ""
            echo "Options:"
            echo "  --racks N              Number of racks (default: 1)"
            echo "  --nodes-per-rack M     Nodes per rack (default: 18)"
            echo "  --mode kind|sim        kind = DaemonSet scheduling; sim = sim-spawner (default: sim)"
            echo "  --namespace NS         Test namespace (default: \$PERF_NAMESPACE or default)"
            echo "  --driver-namespace NS  Driver namespace (default: nvidia-dra-driver)"
            echo "  --daemon-image IMG     Dry-run daemon image (default: compute-domain-daemon:dryrun)"
            echo "  --cd-name NAME         ComputeDomain name (default: perf-dryrun-rack)"
            echo "  --num-nodes N          CD spec numNodes (default: 0)"
            echo "  --timeout-daemons SEC  Daemon pod timeout (default: 600)"
            echo "  --skip-cleanup         Do not clean up resources on exit"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ "${MODE}" != "kind" && "${MODE}" != "sim" ]]; then
    log_error "Invalid mode '${MODE}'. Must be 'kind' or 'sim'."
    exit 1
fi

SIM_NODES=$(( NUM_RACKS * SIM_NODES_PER_RACK ))

log_info "=== Test: ${TEST_NAME} (mode=${MODE}) ==="
log_info "  Racks:            ${NUM_RACKS}"
log_info "  Nodes per rack:   ${SIM_NODES_PER_RACK}"
log_info "  Total nodes:      ${SIM_NODES}"
log_info "  Daemon image:     ${DRYRUN_DAEMON_IMAGE}"
log_info "  Mode:             ${MODE}"
log_info "  Namespace:        ${NAMESPACE}"

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
cleanup_dryrun_test() {
    if [[ "${MODE}" == "sim" ]]; then
        cleanup_single_node "${NAMESPACE}"
    else
        # kind mode: delete CD (controller will clean up DaemonSets)
        kubectl delete computedomains.${CD_API_GROUP} "${CD_NAME}" -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true
        # Remove CD labels from worker nodes
        for node in $(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name \
            -l '!node-role.kubernetes.io/control-plane' 2>/dev/null); do
            kubectl label node "${node}" "resource.nvidia.com/compute-domain-" 2>/dev/null || true
        done
        cleanup "${NAMESPACE}"
    fi
}

if [[ "${SKIP_CLEANUP}" != "true" ]]; then
    trap 'log_info "Cleaning up ${TEST_NAME}"; cleanup_dryrun_test' EXIT
fi

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
# 2. Start daemon pods (mode-dependent)
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "kind" ]]; then
    # Kind mode: label worker nodes to trigger DaemonSet scheduling
    log_info "Step 2 (kind mode): Labeling worker nodes with CD label to trigger DaemonSet"

    daemon_start="$(now_ms)"

    WORKER_NODES=($(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name \
        -l '!node-role.kubernetes.io/control-plane' | sort))

    # Label up to SIM_NODES worker nodes with the CD label
    label_count=0
    for node in "${WORKER_NODES[@]}"; do
        if (( label_count >= SIM_NODES )); then
            break
        fi
        kubectl label node "${node}" \
            "resource.nvidia.com/compute-domain=${CD_NAME}" \
            --overwrite
        label_count=$(( label_count + 1 ))
        log_info "  Labeled ${node} with CD=${CD_NAME}"
    done

    daemon_label_ms="$(elapsed_ms "${daemon_start}")"
    log_info "Node labeling complete: ${daemon_label_ms} ms (${label_count} nodes)"
    daemon_create_ms="${daemon_label_ms}"

    # Wait for daemon pods to be Running (launched by controller DaemonSet)
    log_info "Step 3 (kind mode): Waiting for ${SIM_NODES} daemon pods to be Running"
    daemon_running_start="$(now_ms)"
    wait_for_pods_running "app.kubernetes.io/component=compute-domain-daemon" "${SIM_NODES}" "${TIMEOUT_DAEMONS}" "${DRIVER_NAMESPACE}" >/dev/null
    daemon_running_ms="$(elapsed_ms "${daemon_running_start}")"
    log_info "All ${SIM_NODES} daemon pods Running: ${daemon_running_ms} ms"

else
    # Sim mode: create Deployments with real daemon + --dry-run
    log_info "Step 2 (sim mode): Creating ${SIM_NODES} dry-run daemon Deployments"

    daemon_create_start="$(now_ms)"
    create_dryrun_sim_daemon_pods "${CD_UID}" "${CD_NAME}" "${SIM_NODES}" "${SIM_NODES_PER_RACK}" \
        "${DRIVER_NAMESPACE}" "${DRYRUN_DAEMON_IMAGE}"
    daemon_create_ms="$(elapsed_ms "${daemon_create_start}")"
    log_info "Daemon Deployment creation: ${daemon_create_ms} ms"

    # Wait for all daemon pods to be Running
    log_info "Step 3 (sim mode): Waiting for ${SIM_NODES} daemon pods to be Running"
    daemon_running_start="$(now_ms)"
    wait_for_sim_daemons_running "${SIM_NODES}" "${DRIVER_NAMESPACE}" "${TIMEOUT_DAEMONS}" >/dev/null
    daemon_running_ms="$(elapsed_ms "${daemon_running_start}")"
    log_info "All ${SIM_NODES} daemon pods Running: ${daemon_running_ms} ms"
fi

# ---------------------------------------------------------------------------
# 4. Monitor CDClique creation
# ---------------------------------------------------------------------------
log_info "Step 4: Monitoring CDClique creation (expecting ${NUM_RACKS} cliques)"

cdclique_ms="$(wait_for_cdcliques "${NUM_RACKS}" "${NAMESPACE}" "${TIMEOUT_CDCLIQUES}")"
log_info "All ${NUM_RACKS} CDCliques created: ${cdclique_ms} ms"

kubectl get computedomaincliques.${CD_API_GROUP} -n "${NAMESPACE}" --no-headers 2>/dev/null | \
    while read -r line; do log_info "  ${line}"; done

# ---------------------------------------------------------------------------
# 5. Wait for all nodes Ready in CD status
# ---------------------------------------------------------------------------
log_info "Step 5: Waiting for all ${SIM_NODES} nodes to be Ready in CD status"

nodes_ready_ms="$(wait_for_all_nodes_ready "${CD_NAME}" "${SIM_NODES}" "${NAMESPACE}" "${TIMEOUT_NODES_READY}")"
log_info "All ${SIM_NODES} nodes Ready: ${nodes_ready_ms} ms"

# ---------------------------------------------------------------------------
# 6. Collect metrics
# ---------------------------------------------------------------------------
collect_controller_metrics "${RESULTS_DIR}/${TEST_NAME}-metrics.prom"
wq_metrics="$(extract_workqueue_metrics "${RESULTS_DIR}/${TEST_NAME}-metrics.prom")"

# ---------------------------------------------------------------------------
# 7. Daemon pod startup latencies
# ---------------------------------------------------------------------------
log_info "Step 6: Computing daemon pod startup latencies"
daemon_latencies_file="$(mktemp /tmp/daemon-latencies-XXXXXX)"
if [[ "${MODE}" == "sim" ]]; then
    get_pod_startup_latencies "app=sim-daemon" > "${daemon_latencies_file}"
else
    get_pod_startup_latencies "app.kubernetes.io/component=compute-domain-daemon" > "${daemon_latencies_file}"
fi

daemon_pods_measured="$(wc -l < "${daemon_latencies_file}")"
daemon_p50="$(cat "${daemon_latencies_file}" | percentile 50)"
daemon_p95="$(cat "${daemon_latencies_file}" | percentile 95)"
daemon_p99="$(cat "${daemon_latencies_file}" | percentile 99)"
daemon_p_min="$(sort -n "${daemon_latencies_file}" | head -1)"
daemon_p_max="$(sort -n "${daemon_latencies_file}" | tail -1)"

log_info "Daemon startup latency: P50=${daemon_p50}ms P95=${daemon_p95}ms P99=${daemon_p99}ms (n=${daemon_pods_measured})"
rm -f "${daemon_latencies_file}"

# ---------------------------------------------------------------------------
# 8. Per-rack breakdown
# ---------------------------------------------------------------------------
log_info "Step 7: Computing per-rack breakdown"
rack_timings="["
for (( r=0; r<NUM_RACKS; r++ )); do
    if [[ "${MODE}" == "sim" ]]; then
        rack_daemon_count="$(kubectl get pods -n "${DRIVER_NAMESPACE}" -l "rack-id=${r},app=sim-daemon" \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
    else
        rack_daemon_count="${SIM_NODES_PER_RACK}"
    fi
    (( r > 0 )) && rack_timings+=","
    rack_timings+="{\"rack_id\":${r},\"running_daemons\":${rack_daemon_count}}"
done
rack_timings+="]"

# ---------------------------------------------------------------------------
# 9. Report results
# ---------------------------------------------------------------------------
report_results "${TEST_NAME}" "$(cat <<EOJSON
{
  "config": {
    "mode": "${MODE}",
    "daemon_type": "real-dryrun",
    "cd_name": "${CD_NAME}",
    "num_racks": ${NUM_RACKS},
    "sim_nodes": ${SIM_NODES},
    "nodes_per_rack": ${SIM_NODES_PER_RACK},
    "daemon_image": "${DRYRUN_DAEMON_IMAGE}",
    "topology": {
      "platform": "GB200_NVL72",
      "nodes_per_rack": ${SIM_NODES_PER_RACK},
      "gpus_per_node": ${GPUS_PER_NODE},
      "gpus_per_rack": ${GPUS_PER_RACK}
    }
  },
  "timings": {
    "cd_create_ms": ${cd_create_ms},
    "daemon_create_ms": ${daemon_create_ms},
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
  "workqueue_metrics": ${wq_metrics}
}
EOJSON
)"

log_info "=== ${TEST_NAME} (mode=${MODE}) complete ==="
