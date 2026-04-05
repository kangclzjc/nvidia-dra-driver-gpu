#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# test-cd-failover.sh — ComputeDomain fault recovery testing.
# Kills daemon pods and measures detection, restart, and recovery times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TEST_NAME="cd-failover"
CD_NAME="perf-failover-cd"
NUM_NODES=0
ITERATIONS=10
TIMEOUT_CD_READY=120
DRIVER_NAMESPACE="${DRIVER_NAMESPACE:-nvidia-dra-driver}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iterations)  ITERATIONS="$2";       shift 2 ;;
        --num-nodes)   NUM_NODES="$2";        shift 2 ;;
        --namespace)   NAMESPACE="$2";        shift 2 ;;
        --driver-ns)   DRIVER_NAMESPACE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--iterations N] [--num-nodes N] [--namespace NS] [--driver-ns NS]"
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
# Helper: wait_for_cd_not_ready
# ---------------------------------------------------------------------------
wait_for_cd_not_ready() {
    local name="$1"
    local timeout="${2:-120}"
    local start
    start="$(now_ms)"
    local deadline=$(( $(date +%s) + timeout ))

    while true; do
        local status
        status="$(kubectl get computedomains.${CD_API_GROUP} "${name}" \
            -n "${NAMESPACE}" -o jsonpath='{.status.status}' 2>/dev/null || true)"
        if [[ "${status}" == "NotReady" ]]; then
            local ms
            ms="$(elapsed_ms "$start")"
            echo "${ms}"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            log_error "Timed out waiting for CD ${name} NotReady"
            echo "-1"
            return 1
        fi
        sleep 0.5
    done
}

# ---------------------------------------------------------------------------
# Helper: get daemon pods for the CD
# ---------------------------------------------------------------------------
get_daemon_pods() {
    # Daemon pods created by the controller carry the compute-domain label
    kubectl get pods -A -l "resource.nvidia.com/compute-domain=${CD_NAME}" \
        --no-headers -o custom-columns=':metadata.name,:metadata.namespace' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: wait_for_daemon_pod_count
# ---------------------------------------------------------------------------
wait_for_daemon_pod_count() {
    local expected="$1"
    local timeout="${2:-120}"
    local start
    start="$(now_ms)"
    local deadline=$(( $(date +%s) + timeout ))

    while true; do
        local count
        count="$(kubectl get pods -A -l "resource.nvidia.com/compute-domain=${CD_NAME}" \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)"
        if (( count >= expected )); then
            local ms
            ms="$(elapsed_ms "$start")"
            echo "${ms}"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            echo "-1"
            return 1
        fi
        sleep 0.5
    done
}

# ---------------------------------------------------------------------------
# 1. Create CD and wait for Ready
# ---------------------------------------------------------------------------
log_info "=== Test: ${TEST_NAME} ==="
log_info "Creating ComputeDomain ${CD_NAME}"
create_cd "${CD_NAME}" "${NUM_NODES}"
wait_for_cd_ready "${CD_NAME}" "${TIMEOUT_CD_READY}" >/dev/null

# Record initial daemon pods
initial_daemons="$(get_daemon_pods)"
initial_count="$(echo "${initial_daemons}" | grep -c . || echo 0)"
log_info "Initial daemon pods: ${initial_count}"

# ---------------------------------------------------------------------------
# 2. Failover iterations
# ---------------------------------------------------------------------------
detection_times=()
restart_times=()
recovery_times=()

for (( iter=1; iter<=ITERATIONS; iter++ )); do
    log_info "--- Failover iteration ${iter}/${ITERATIONS} ---"

    # Ensure CD is Ready before this iteration
    wait_for_cd_ready "${CD_NAME}" "${TIMEOUT_CD_READY}" >/dev/null

    # Pick a daemon pod to kill
    target_pod=""
    target_ns=""
    while IFS= read -r line; do
        if [[ -n "${line}" ]]; then
            target_pod="$(echo "${line}" | awk '{print $1}')"
            target_ns="$(echo "${line}" | awk '{print $2}')"
            break
        fi
    done < <(get_daemon_pods | shuf)

    if [[ -z "${target_pod}" ]]; then
        log_error "No daemon pods found to kill — skipping iteration"
        continue
    fi

    log_info "Killing daemon pod: ${target_pod} in ${target_ns}"

    # Force-delete the daemon pod
    kill_start="$(now_ms)"
    kubectl delete pod "${target_pod}" -n "${target_ns}" --grace-period=0 --force 2>/dev/null || true

    # Measure fault detection time (CD transitions to NotReady)
    detect_ms="$(wait_for_cd_not_ready "${CD_NAME}" 120)"
    if (( detect_ms < 0 )); then
        log_error "CD did not transition to NotReady — possibly already recovered"
        detect_ms=0
    fi
    log_info "Fault detection: ${detect_ms} ms"
    detection_times+=("${detect_ms}")

    # Measure new daemon pod startup (controller recreates it)
    daemon_restart_ms="$(wait_for_daemon_pod_count "${initial_count}" 120)"
    if (( daemon_restart_ms < 0 )); then
        log_error "Daemon pod did not restart within timeout"
        daemon_restart_ms=-1
    fi
    log_info "Daemon pod restart: ${daemon_restart_ms} ms"
    restart_times+=("${daemon_restart_ms}")

    # Measure CD recovery to Ready
    recovery_ms="$(wait_for_cd_ready "${CD_NAME}" "${TIMEOUT_CD_READY}" 2>/dev/null)"
    log_info "CD recovery to Ready: ${recovery_ms} ms"
    recovery_times+=("${recovery_ms}")

    # Brief pause between iterations
    sleep 2
done

# ---------------------------------------------------------------------------
# 3. Compute statistics
# ---------------------------------------------------------------------------
detect_file="$(mktemp /tmp/detect-XXXXXX)"
restart_file="$(mktemp /tmp/restart-XXXXXX)"
recovery_file="$(mktemp /tmp/recovery-XXXXXX)"

printf '%s\n' "${detection_times[@]}" > "${detect_file}"
printf '%s\n' "${restart_times[@]}" > "${restart_file}"
printf '%s\n' "${recovery_times[@]}" > "${recovery_file}"

detect_p50="$(cat "${detect_file}" | percentile 50)"
detect_p95="$(cat "${detect_file}" | percentile 95)"
detect_avg="$(awk '{s+=$1; n++} END{printf "%.0f", (n>0?s/n:0)}' "${detect_file}")"

restart_p50="$(cat "${restart_file}" | percentile 50)"
restart_p95="$(cat "${restart_file}" | percentile 95)"
restart_avg="$(awk '{s+=$1; n++} END{printf "%.0f", (n>0?s/n:0)}' "${restart_file}")"

recovery_p50="$(cat "${recovery_file}" | percentile 50)"
recovery_p95="$(cat "${recovery_file}" | percentile 95)"
recovery_avg="$(awk '{s+=$1; n++} END{printf "%.0f", (n>0?s/n:0)}' "${recovery_file}")"

# Build per-iteration JSON array
iter_json="["
for (( i=0; i<${#detection_times[@]}; i++ )); do
    (( i > 0 )) && iter_json+=","
    iter_json+="{\"iteration\":$((i+1)),\"detection_ms\":${detection_times[$i]},\"restart_ms\":${restart_times[$i]},\"recovery_ms\":${recovery_times[$i]}}"
done
iter_json+="]"

# ---------------------------------------------------------------------------
# 4. Collect controller metrics
# ---------------------------------------------------------------------------
collect_controller_metrics "${RESULTS_DIR}/${TEST_NAME}-metrics.prom"
wq_metrics="$(extract_workqueue_metrics "${RESULTS_DIR}/${TEST_NAME}-metrics.prom")"

# ---------------------------------------------------------------------------
# 5. Report results
# ---------------------------------------------------------------------------
rm -f "${detect_file}" "${restart_file}" "${recovery_file}"

report_results "${TEST_NAME}" "$(cat <<EOJSON
{
  "config": {
    "cd_name": "${CD_NAME}",
    "iterations": ${ITERATIONS},
    "num_nodes": ${NUM_NODES}
  },
  "fault_detection": {
    "avg_ms": ${detect_avg},
    "p50_ms": ${detect_p50},
    "p95_ms": ${detect_p95}
  },
  "daemon_restart": {
    "avg_ms": ${restart_avg},
    "p50_ms": ${restart_p50},
    "p95_ms": ${restart_p95}
  },
  "cd_recovery": {
    "avg_ms": ${recovery_avg},
    "p50_ms": ${recovery_p50},
    "p95_ms": ${recovery_p95}
  },
  "iterations": ${iter_json},
  "workqueue_metrics": ${wq_metrics}
}
EOJSON
)"

log_info "=== ${TEST_NAME} complete ==="
