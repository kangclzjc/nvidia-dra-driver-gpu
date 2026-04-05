#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# common.sh — Shared function library for ComputeDomain performance tests.
# Source this file; do not execute it directly.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
PERF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${PERF_DIR}/results"
NAMESPACE="${PERF_NAMESPACE:-default}"
CD_API_GROUP="resource.nvidia.com"
CD_API_VERSION="v1beta1"
CD_KIND="ComputeDomain"
CONTROLLER_LABEL="nvidia-dra-driver-gpu-component=controller"
FAKE_PLUGIN_LABEL="app=fake-cd-kubelet-plugin"
FAKE_DAEMON_LABEL="app=fake-compute-domain-daemon"

# ---------------------------------------------------------------------------
# GB200 NVL72 Topology Constants
# ---------------------------------------------------------------------------
# GB200 NVL72 rack: 18 nodes per rack, 4 GPUs per node, 72 GPUs per rack
NODES_PER_RACK=18
GPUS_PER_NODE=4
GPUS_PER_RACK=$(( NODES_PER_RACK * GPUS_PER_NODE ))  # 72

# Helper: round up to nearest multiple of NODES_PER_RACK
# Usage: align_to_rack_size 2000 → 2016 (112 racks × 18)
align_to_rack_size() {
    local n="${1:?count required}"
    local remainder=$(( n % NODES_PER_RACK ))
    if (( remainder == 0 )); then
        echo "${n}"
    else
        echo $(( n + NODES_PER_RACK - remainder ))
    fi
}

# Helper: calculate number of racks needed
# Usage: num_racks 2016 → 112
num_racks() {
    local pods="${1:?pod count required}"
    echo $(( (pods + NODES_PER_RACK - 1) / NODES_PER_RACK ))
}

mkdir -p "${RESULTS_DIR}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')] [INFO]  $*"
}

log_error() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')] [ERROR] $*" >&2
}

# ---------------------------------------------------------------------------
# Timing helpers
# ---------------------------------------------------------------------------
now_ms() {
    # Milliseconds since epoch (portable: date +%s%3N on GNU, fallback python)
    if date +%s%3N &>/dev/null; then
        date +%s%3N
    else
        python3 -c 'import time; print(int(time.time()*1000))'
    fi
}

elapsed_ms() {
    local start="$1"
    local end
    end="$(now_ms)"
    echo $(( end - start ))
}

# ---------------------------------------------------------------------------
# Percentile calculation
# ---------------------------------------------------------------------------
# percentile VALUES_ARRAY P (e.g. 50, 95, 99)
# Reads newline-separated numbers from stdin or from a file descriptor.
# Usage: echo -e "10\n20\n30" | percentile 50
percentile() {
    local p="${1:?percentile value required (e.g. 50, 95, 99)}"
    sort -n | awk -v p="$p" '
    {v[NR]=$1}
    END {
        if (NR==0) {print 0; exit}
        idx = p/100 * NR
        if (idx < 1) idx = 1
        low  = int(idx)
        high = (low < NR) ? low+1 : low
        frac = idx - low
        printf "%.0f\n", v[low] + frac*(v[high]-v[low])
    }'
}

# ---------------------------------------------------------------------------
# ComputeDomain helpers
# ---------------------------------------------------------------------------

# create_cd NAME [NUM_NODES] [RCT_NAME] [ALLOC_MODE]
# Creates a ComputeDomain CR and returns immediately.
create_cd() {
    local name="${1:?cd name required}"
    local num_nodes="${2:-0}"
    local rct_name="${3:-${name}-channel}"
    local alloc_mode="${4:-Single}"

    cat <<EOF | kubectl apply -f - --namespace="${NAMESPACE}"
apiVersion: ${CD_API_GROUP}/${CD_API_VERSION}
kind: ${CD_KIND}
metadata:
  name: ${name}
spec:
  numNodes: ${num_nodes}
  channel:
    allocationMode: ${alloc_mode}
    resourceClaimTemplate:
      name: ${rct_name}
EOF
    log_info "Created ComputeDomain ${name} (numNodes=${num_nodes}, rct=${rct_name})"
}

# wait_for_cd_ready NAME [TIMEOUT_SEC]
# Blocks until the CD status becomes Ready. Prints elapsed ms to stdout.
wait_for_cd_ready() {
    local name="${1:?cd name required}"
    local timeout="${2:-300}"
    local start
    start="$(now_ms)"
    local deadline=$(( $(date +%s) + timeout ))

    while true; do
        local status
        status="$(kubectl get computedomains.${CD_API_GROUP} "${name}" \
            -n "${NAMESPACE}" -o jsonpath='{.status.status}' 2>/dev/null || true)"
        if [[ "${status}" == "Ready" ]]; then
            local ms
            ms="$(elapsed_ms "$start")"
            log_info "ComputeDomain ${name} is Ready (${ms} ms)"
            echo "${ms}"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            log_error "Timed out waiting for ComputeDomain ${name} to become Ready (${timeout}s)"
            return 1
        fi
        sleep 1
    done
}

# wait_for_cd_deleted NAME [TIMEOUT_SEC]
# Blocks until the CD and its owned resources are fully removed.
wait_for_cd_deleted() {
    local name="${1:?cd name required}"
    local timeout="${2:-300}"
    local start
    start="$(now_ms)"
    local deadline=$(( $(date +%s) + timeout ))

    while true; do
        if ! kubectl get computedomains.${CD_API_GROUP} "${name}" -n "${NAMESPACE}" &>/dev/null; then
            local ms
            ms="$(elapsed_ms "$start")"
            log_info "ComputeDomain ${name} fully deleted (${ms} ms)"
            echo "${ms}"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            log_error "Timed out waiting for ComputeDomain ${name} deletion (${timeout}s)"
            return 1
        fi
        sleep 1
    done
}

# wait_for_pods_running LABEL_SELECTOR EXPECTED_COUNT [TIMEOUT_SEC] [NAMESPACE]
# Returns elapsed ms via stdout.
wait_for_pods_running() {
    local selector="${1:?label selector required}"
    local expected="${2:?expected count required}"
    local timeout="${3:-600}"
    local ns="${4:-${NAMESPACE}}"
    local start
    start="$(now_ms)"
    local deadline=$(( $(date +%s) + timeout ))

    while true; do
        local running
        running="$(kubectl get pods -n "${ns}" -l "${selector}" \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
        if (( running >= expected )); then
            local ms
            ms="$(elapsed_ms "$start")"
            log_info "${running}/${expected} pods Running (${ms} ms)"
            echo "${ms}"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            log_error "Timed out: only ${running}/${expected} pods Running after ${timeout}s"
            return 1
        fi
        sleep 2
    done
}

# create_workload_pods CD_NAME POD_COUNT [BATCH_SIZE] [IMAGE]
# Creates POD_COUNT pods that reference the CD channel ResourceClaimTemplate.
# Each pod requests 4 GPUs (one GB200 node = 4 GPUs) + CD channel.
create_workload_pods() {
    local cd_name="${1:?cd name required}"
    local count="${2:?pod count required}"
    local batch="${3:-18}"  # default = 1 rack (18 nodes)
    local image="${4:-registry.k8s.io/pause:3.9}"
    local rct_name="${cd_name}-channel"

    log_info "Creating ${count} workload pods for CD ${cd_name} (batch=${batch}, ${GPUS_PER_NODE} GPUs/pod)"

    local created=0
    while (( created < count )); do
        local remaining=$(( count - created ))
        local this_batch=$(( remaining < batch ? remaining : batch ))
        local yaml=""

        for (( i=0; i<this_batch; i++ )); do
            local idx=$(( created + i ))
            local rack_id=$(( idx / NODES_PER_RACK ))
            local node_in_rack=$(( idx % NODES_PER_RACK ))
            local pod_name="${cd_name}-rack$(printf '%04d' ${rack_id})-node$(printf '%02d' ${node_in_rack})"
            yaml+="---
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${NAMESPACE}
  labels:
    perf-test: \"true\"
    cd-name: ${cd_name}
    rack-id: \"$(printf '%04d' ${rack_id})\"
    node-in-rack: \"$(printf '%02d' ${node_in_rack})\"
  annotations:
    nvidia.com/topology: \"GB200_NVL72\"
    nvidia.com/rack-id: \"${rack_id}\"
    nvidia.com/gpus-requested: \"${GPUS_PER_NODE}\"
spec:
  containers:
  - name: workload
    image: ${image}
    resources:
      claims:
      - name: cd-channel
  resourceClaims:
  - name: cd-channel
    resourceClaimTemplateName: ${rct_name}
"
        done

        echo "${yaml}" | kubectl apply -f - 2>/dev/null
        created=$(( created + this_batch ))
        log_info "  Created batch: ${this_batch} pods (rack #${rack_id}, total: ${created}/${count})"
        # Brief pause between batches to avoid API server overload
        sleep 1
    done
}

# measure_latency DESCRIPTION COMMAND [ARGS...]
# Runs a command, captures wall-clock ms, prints to stdout.
measure_latency() {
    local desc="$1"; shift
    local start
    start="$(now_ms)"
    "$@"
    local ms
    ms="$(elapsed_ms "$start")"
    log_info "${desc}: ${ms} ms"
    echo "${ms}"
}

# ---------------------------------------------------------------------------
# Metrics collection
# ---------------------------------------------------------------------------

# collect_controller_metrics [OUTPUT_FILE]
# Scrapes Prometheus metrics from the controller pod.
collect_controller_metrics() {
    local output="${1:-${RESULTS_DIR}/controller-metrics-$(date +%s).prom}"
    local controller_pod
    controller_pod="$(kubectl get pods -A -l "${CONTROLLER_LABEL}" \
        --no-headers -o custom-columns=':metadata.name,:metadata.namespace' 2>/dev/null | head -1)"

    if [[ -z "${controller_pod}" ]]; then
        log_error "No controller pod found with label ${CONTROLLER_LABEL}"
        echo "{}" > "${output}"
        return 0
    fi

    local pod_name pod_ns
    pod_name="$(echo "${controller_pod}" | awk '{print $1}')"
    pod_ns="$(echo "${controller_pod}" | awk '{print $2}')"

    # Try common metrics ports
    for port in 8080 8443 2112 9090; do
        if kubectl exec -n "${pod_ns}" "${pod_name}" -- \
            wget -qO- "http://localhost:${port}/metrics" 2>/dev/null > "${output}"; then
            log_info "Collected controller metrics from port ${port} → ${output}"
            return 0
        fi
    done

    # Fallback: extract key workqueue metrics from pod logs
    log_info "Could not scrape Prometheus endpoint; collecting from kube API"
    kubectl top pod "${pod_name}" -n "${pod_ns}" --no-headers 2>/dev/null > "${output}" || true
    return 0
}

# extract_workqueue_metrics FILE
# Parses Prometheus text format for workqueue_* metrics, outputs JSON summary.
extract_workqueue_metrics() {
    local file="${1:?metrics file required}"
    if [[ ! -s "${file}" ]]; then
        echo '{}'
        return 0
    fi
    awk '
    /^workqueue_depth{/ { gsub(/.*name="/, ""); gsub(/".*/, ""); depth[$0]=$NF }
    /^workqueue_adds_total{/ { gsub(/.*name="/, ""); gsub(/".*/, ""); adds[$0]=$NF }
    /^workqueue_queue_duration_seconds_sum{/ { gsub(/.*name="/, ""); gsub(/".*/, ""); dur[$0]=$NF }
    END {
        printf "{"
        first=1
        for (q in depth) {
            if (!first) printf ","
            printf "\"%s\":{\"depth\":%s,\"adds\":%s,\"queue_duration_sum\":%s}",
                q, depth[q]+0, (q in adds ? adds[q] : 0)+0, (q in dur ? dur[q] : 0)+0
            first=0
        }
        printf "}\n"
    }' "${file}"
}

# collect_resource_usage [LABEL_SELECTOR] [NAMESPACE]
# Collects CPU/memory for pods matching selector. Returns JSON.
collect_resource_usage() {
    local selector="${1:-${CONTROLLER_LABEL}}"
    local ns="${2:-}"
    local ns_flag=""
    [[ -n "${ns}" ]] && ns_flag="-n ${ns}" || ns_flag="-A"

    kubectl top pods ${ns_flag} -l "${selector}" --no-headers 2>/dev/null | \
    awk 'BEGIN{printf "["} NR>1{printf ","} {printf "{\"pod\":\"%s\",\"cpu\":\"%s\",\"memory\":\"%s\"}", $1,$2,$3} END{printf "]\n"}'
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

# report_results TEST_NAME JSON_DATA
# Writes results to a JSON file in the results directory.
report_results() {
    local test_name="${1:?test name required}"
    local json_data="${2:?json data required}"
    local output="${RESULTS_DIR}/${test_name}.json"

    cat <<EOF > "${output}"
{
  "test": "${test_name}",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "namespace": "${NAMESPACE}",
  "results": ${json_data}
}
EOF
    log_info "Results written to ${output}"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

# cleanup [NAMESPACE]
# Removes all perf-test pods and ComputeDomains in the namespace.
cleanup() {
    local ns="${1:-${NAMESPACE}}"
    log_info "Cleaning up perf test resources in namespace ${ns}"

    # Delete workload pods
    kubectl delete pods -n "${ns}" -l perf-test=true --grace-period=0 --force 2>/dev/null || true

    # Delete all ComputeDomains
    kubectl delete computedomains.${CD_API_GROUP} -n "${ns}" --all --timeout=120s 2>/dev/null || true

    # Wait for ResourceClaimTemplates owned by CDs to be cleaned up
    sleep 5

    # Delete any lingering ResourceClaimTemplates with CD ownership
    kubectl delete resourceclaimtemplates -n "${ns}" --all 2>/dev/null || true

    log_info "Cleanup complete"
}

# ---------------------------------------------------------------------------
# Single-node simulation helpers
# ---------------------------------------------------------------------------

# create_sim_daemon_pods CD_UID CD_NAME NUM_NODES NODES_PER_RACK NAMESPACE IMAGE
# Creates NUM_NODES fake daemon Deployments (each 1 replica) simulating
# multi-node CDClique negotiation on a single-node cluster.
# Daemon pods are grouped into racks of NODES_PER_RACK and assigned clique-ids.
# Deployments are split into chunks and applied in parallel for speed.
create_sim_daemon_pods() {
    local cd_uid="${1:?cd uid required}"
    local cd_name="${2:?cd name required}"
    local num_nodes="${3:?num nodes required}"
    local nodes_per_rack="${4:-${NODES_PER_RACK}}"
    local ns="${5:-${NAMESPACE}}"
    local image="${6:-fake-compute-domain-daemon:perf}"

    local total_racks=$(( (num_nodes + nodes_per_rack - 1) / nodes_per_rack ))
    local chunk_size=10
    local parallel_jobs=8
    log_info "Creating ${num_nodes} simulated daemon Deployments (${total_racks} racks, ${nodes_per_rack} nodes/rack, parallel chunks of ${chunk_size})"

    # Generate YAML into chunked files for parallel apply.
    local chunk_dir
    chunk_dir="$(mktemp -d /tmp/sim-daemon-chunks-XXXXXX)"
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
        cd-name: ${cd_name}
        rack-id: "${rack_id}"
        sim-node: ${sim_node}
    spec:
      serviceAccountName: nvidia-dra-driver-gpu-compute-domain-daemon
      terminationGracePeriodSeconds: 5
      containers:
      - name: fake-daemon
        image: ${image}
        imagePullPolicy: IfNotPresent
        command: ["fake-compute-domain-daemon", "-v", "2", "run"]
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
YAMEOF
        items_in_chunk=$(( items_in_chunk + 1 ))
        if (( items_in_chunk >= chunk_size && i < num_nodes - 1 )); then
            chunk_index=$(( chunk_index + 1 ))
            current_chunk="${chunk_dir}/chunk-$(printf '%04d' ${chunk_index}).yaml"
            items_in_chunk=0
        fi
    done

    local total_chunks=$(( chunk_index + 1 ))
    log_info "Parallel applying ${num_nodes} sim-daemon Deployments (${total_chunks} chunks, ${parallel_jobs} parallel jobs)..."
    # shellcheck disable=SC2012
    ls "${chunk_dir}"/*.yaml | xargs -P "${parallel_jobs}" -I {} kubectl apply -f {} 2>/dev/null
    local apply_rc=$?

    rm -rf "${chunk_dir}"

    if (( apply_rc != 0 )); then
        log_error "Some parallel kubectl apply jobs failed (rc=${apply_rc})"
        return "${apply_rc}"
    fi

    log_info "All ${num_nodes} simulated daemon Deployments created"
}

# wait_for_cdcliques EXPECTED_COUNT [NAMESPACE] [TIMEOUT_SEC]
# Blocks until the expected number of CDClique resources exist. Returns elapsed ms.
wait_for_cdcliques() {
    local expected="${1:?expected cdclique count required}"
    local ns="${2:-${NAMESPACE}}"
    local timeout="${3:-300}"
    local start
    start="$(now_ms)"
    local deadline=$(( $(date +%s) + timeout ))

    while true; do
        local count
        count="$(kubectl get computedomaincliques.${CD_API_GROUP} -n "${ns}" \
            --no-headers 2>/dev/null | wc -l)"
        if (( count >= expected )); then
            local ms
            ms="$(elapsed_ms "$start")"
            log_info "${count}/${expected} CDCliques created (${ms} ms)"
            echo "${ms}"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            log_error "Timed out waiting for CDCliques: only ${count}/${expected} after ${timeout}s"
            return 1
        fi
        sleep 2
    done
}

# wait_for_all_nodes_ready CD_NAME EXPECTED_NODES [NAMESPACE] [TIMEOUT_SEC]
# Waits until the ComputeDomain status shows all nodes as Ready. Returns elapsed ms.
wait_for_all_nodes_ready() {
    local cd_name="${1:?cd name required}"
    local expected="${2:?expected node count required}"
    local ns="${3:-${NAMESPACE}}"
    local timeout="${4:-600}"
    local start
    start="$(now_ms)"
    local deadline=$(( $(date +%s) + timeout ))

    while true; do
        local ready_count
        ready_count="$(kubectl get computedomains.${CD_API_GROUP} "${cd_name}" -n "${ns}" \
            -o json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    status = data.get("status", {})
    # Try multiple possible status structures
    nodes = status.get("nodes", {})
    ready = sum(1 for n in nodes.values() if isinstance(n, dict) and n.get("status") == "Ready")
    if ready == 0:
        # Fallback: count from cliques
        cliques = status.get("cliques", [])
        for c in cliques:
            if isinstance(c, dict):
                ready += sum(1 for n in c.get("nodes", []) if isinstance(n, dict) and n.get("ready", False))
    if ready == 0:
        # Fallback: count ready nodes from numNodesReady field
        ready = status.get("numNodesReady", 0)
    print(ready)
except Exception:
    print(0)
' 2>/dev/null || echo 0)"

        if (( ready_count >= expected )); then
            local ms
            ms="$(elapsed_ms "$start")"
            log_info "All ${ready_count}/${expected} nodes Ready in CD ${cd_name} (${ms} ms)"
            echo "${ms}"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            log_error "Timed out: only ${ready_count}/${expected} nodes Ready in CD ${cd_name} after ${timeout}s"
            return 1
        fi
        log_info "  Nodes Ready: ${ready_count}/${expected} — waiting..."
        sleep 5
    done
}

# wait_for_sim_daemons_running NUM_EXPECTED [NAMESPACE] [TIMEOUT_SEC]
# Waits until the expected number of sim-daemon pods are Running.
wait_for_sim_daemons_running() {
    local expected="${1:?expected count required}"
    local ns="${2:-${NAMESPACE}}"
    local timeout="${3:-300}"

    log_info "Waiting for ${expected} sim-daemon pods to be Running"
    wait_for_pods_running "app=sim-daemon" "${expected}" "${timeout}" "${ns}"
}

# cleanup_sim_daemons [NAMESPACE]
# Deletes all simulated daemon Deployments.
cleanup_sim_daemons() {
    local ns="${1:-${NAMESPACE}}"
    log_info "Cleaning up simulated daemon Deployments in namespace ${ns}"
    kubectl delete deployments -n "${ns}" -l perf-sim=true --grace-period=0 --force 2>/dev/null || true
    # Wait for pods to terminate
    local deadline=$(( $(date +%s) + 60 ))
    while true; do
        local remaining
        remaining="$(kubectl get pods -n "${ns}" -l perf-sim=true --no-headers 2>/dev/null | wc -l)"
        if (( remaining == 0 )); then
            break
        fi
        if (( $(date +%s) >= deadline )); then
            log_info "  ${remaining} sim-daemon pods still terminating — proceeding"
            break
        fi
        sleep 2
    done
    log_info "Sim-daemon cleanup complete"
}

# get_cd_uid CD_NAME [NAMESPACE]
# Returns the UID of a ComputeDomain.
get_cd_uid() {
    local cd_name="${1:?cd name required}"
    local ns="${2:-${NAMESPACE}}"
    kubectl get computedomains.${CD_API_GROUP} "${cd_name}" -n "${ns}" \
        -o jsonpath='{.metadata.uid}' 2>/dev/null
}

# cleanup_single_node [NAMESPACE]
# Full cleanup for single-node simulation mode.
cleanup_single_node() {
    local ns="${1:-${NAMESPACE}}"
    log_info "Cleaning up single-node simulation resources in namespace ${ns}"
    cleanup_sim_daemons "${ns}"
    cleanup "${ns}"
}

# monitor_pod_progress LABEL_SELECTOR EXPECTED_COUNT INTERVAL_SEC [DURATION_SEC]
# Periodically samples Running/Pending/Failed counts. Outputs JSON array.
monitor_pod_progress() {
    local selector="${1:?label selector required}"
    local expected="${2:?expected count required}"
    local interval="${3:-10}"
    local duration="${4:-600}"
    local ns="${NAMESPACE}"
    local end_time=$(( $(date +%s) + duration ))

    local samples="["
    local first=true
    while (( $(date +%s) < end_time )); do
        local running pending failed
        running="$(kubectl get pods -n "${ns}" -l "${selector}" \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
        pending="$(kubectl get pods -n "${ns}" -l "${selector}" \
            --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)"
        failed="$(kubectl get pods -n "${ns}" -l "${selector}" \
            --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)"

        local ts
        ts="$(date +%s)"
        ${first} || samples+=","
        samples+="{\"ts\":${ts},\"running\":${running},\"pending\":${pending},\"failed\":${failed}}"
        first=false

        log_info "Progress: Running=${running} Pending=${pending} Failed=${failed} (expected=${expected})"

        if (( running >= expected )); then
            break
        fi
        sleep "${interval}"
    done
    samples+="]"
    echo "${samples}"
}

# get_pod_startup_latencies LABEL_SELECTOR
# For each pod, computes (first-container-started - pod-creation) in ms.
# Outputs newline-separated latency values.
get_pod_startup_latencies() {
    local selector="${1:?label selector required}"
    local ns="${NAMESPACE}"

    kubectl get pods -n "${ns}" -l "${selector}" -o json 2>/dev/null | \
    python3 -c '
import json, sys
from datetime import datetime, timezone

def parse_ts(s):
    s = s.rstrip("Z")
    if "." in s:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=timezone.utc)
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)

data = json.load(sys.stdin)
for pod in data.get("items", []):
    meta = pod.get("metadata", {})
    created = meta.get("creationTimestamp")
    if not created:
        continue
    ct = parse_ts(created)
    # Find earliest container start
    statuses = pod.get("status", {}).get("containerStatuses", [])
    earliest = None
    for cs in statuses:
        state = cs.get("state", {})
        running = state.get("running", {})
        started = running.get("startedAt")
        if started:
            st = parse_ts(started)
            if earliest is None or st < earliest:
                earliest = st
    if earliest:
        delta_ms = int((earliest - ct).total_seconds() * 1000)
        print(delta_ms)
'
}
