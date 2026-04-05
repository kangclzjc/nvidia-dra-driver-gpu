#!/usr/bin/env bash
# Copyright The Kubernetes Authors
# SPDX-License-Identifier: Apache-2.0
#
# test-cd-scale.sh — ComputeDomain scalability test.
# Progressively creates 10, 50, 100, 200 CDs and measures controller metrics
# at each tier to produce scalability curve data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TEST_NAME="cd-scale"
CD_PREFIX="perf-scale"
NUM_NODES=0
TIERS="10 20 30 50"    # Default for 4vCPU/16GB. Use --tiers "10 50 100 200" for large machines.
TIMEOUT_CD_READY=300
SETTLE_TIME=15  # seconds to let controller settle after each tier
DRIVER_NAMESPACE="${DRIVER_NAMESPACE:-nvidia-dra-driver}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tiers)       TIERS="$2";              shift 2 ;;
        --num-nodes)   NUM_NODES="$2";          shift 2 ;;
        --namespace)   NAMESPACE="$2";          shift 2 ;;
        --driver-ns)   DRIVER_NAMESPACE="$2";   shift 2 ;;
        --settle)      SETTLE_TIME="$2";        shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--tiers '10 50 100 200'] [--num-nodes N] [--namespace NS] [--settle SEC]"
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
# Helper: get controller resource metrics
# ---------------------------------------------------------------------------
get_controller_resource_info() {
    local controller_pod controller_ns
    local line
    line="$(kubectl get pods -A -l "${CONTROLLER_LABEL}" \
        --no-headers -o custom-columns=':metadata.name,:metadata.namespace' 2>/dev/null | head -1)"
    controller_pod="$(echo "${line}" | awk '{print $1}')"
    controller_ns="$(echo "${line}" | awk '{print $2}')"

    if [[ -z "${controller_pod}" ]]; then
        echo '{"cpu":"unknown","memory":"unknown","goroutines":"unknown"}'
        return 0
    fi

    # Get CPU/memory from kubectl top
    local top_line
    top_line="$(kubectl top pod "${controller_pod}" -n "${controller_ns}" --no-headers 2>/dev/null || echo "unknown unknown unknown")"
    local cpu mem
    cpu="$(echo "${top_line}" | awk '{print $2}')"
    mem="$(echo "${top_line}" | awk '{print $3}')"

    # Try to get goroutine count from /debug/pprof or metrics
    local goroutines="unknown"
    for port in 8080 8443 2112 9090 6060; do
        local g
        g="$(kubectl exec -n "${controller_ns}" "${controller_pod}" -- \
            wget -qO- "http://localhost:${port}/metrics" 2>/dev/null | \
            awk '/^go_goroutines / {print $2}' || true)"
        if [[ -n "${g}" ]]; then
            goroutines="${g}"
            break
        fi
    done

    echo "{\"cpu\":\"${cpu}\",\"memory\":\"${mem}\",\"goroutines\":\"${goroutines}\"}"
}

# ---------------------------------------------------------------------------
# Run scale tiers
# ---------------------------------------------------------------------------
log_info "=== Test: ${TEST_NAME} ==="
log_info "Scale tiers: ${TIERS}"

current_cd_count=0
tier_results="["
tier_first=true

for tier in ${TIERS}; do
    log_info "--- Scale tier: ${tier} CDs ---"

    # Calculate how many new CDs to create
    new_cds=$(( tier - current_cd_count ))
    if (( new_cds <= 0 )); then
        log_info "Already at ${current_cd_count} CDs, skipping tier ${tier}"
        continue
    fi

    # Create new CDs concurrently
    tier_create_start="$(now_ms)"

    for (( i=current_cd_count; i<tier; i++ )); do
        cd_name="${CD_PREFIX}-$(printf '%04d' ${i})"
        create_cd "${cd_name}" "${NUM_NODES}" &
    done
    wait

    tier_create_ms="$(elapsed_ms "${tier_create_start}")"
    log_info "Created ${new_cds} new CDs in ${tier_create_ms} ms (total: ${tier})"

    # Wait for all new CDs to become Ready
    tier_ready_start="$(now_ms)"
    ready_latencies_file="$(mktemp /tmp/scale-ready-XXXXXX)"
    pids=()
    for (( i=current_cd_count; i<tier; i++ )); do
        cd_name="${CD_PREFIX}-$(printf '%04d' ${i})"
        (
            ms="$(wait_for_cd_ready "${cd_name}" "${TIMEOUT_CD_READY}" 2>/dev/null)"
            echo "${ms}" >> "${ready_latencies_file}"
        ) &
        pids+=($!)
    done

    failed=0
    for pid in "${pids[@]}"; do
        if ! wait "${pid}" 2>/dev/null; then
            (( failed++ )) || true
        fi
    done

    tier_ready_ms="$(elapsed_ms "${tier_ready_start}")"

    # Compute latency stats for this batch
    ready_count="$(wc -l < "${ready_latencies_file}")"
    ready_p50="$(cat "${ready_latencies_file}" | percentile 50)"
    ready_p95="$(cat "${ready_latencies_file}" | percentile 95)"
    ready_p99="$(cat "${ready_latencies_file}" | percentile 99)"
    ready_max="$(sort -n "${ready_latencies_file}" | tail -1)"
    rm -f "${ready_latencies_file}"

    current_cd_count="${tier}"

    # Let the controller settle
    log_info "Waiting ${SETTLE_TIME}s for controller to settle"
    sleep "${SETTLE_TIME}"

    # Collect metrics
    metrics_file="${RESULTS_DIR}/${TEST_NAME}-tier-${tier}-metrics.prom"
    collect_controller_metrics "${metrics_file}"
    wq_metrics="$(extract_workqueue_metrics "${metrics_file}")"
    resource_info="$(get_controller_resource_info)"

    # Count actual CDs in cluster
    actual_cds="$(kubectl get computedomains.${CD_API_GROUP} -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)"

    log_info "Tier ${tier}: create=${tier_create_ms}ms ready=${tier_ready_ms}ms actual_cds=${actual_cds} failed=${failed}"
    log_info "  Ready latency: P50=${ready_p50}ms P95=${ready_p95}ms P99=${ready_p99}ms Max=${ready_max:-0}ms"
    log_info "  Resources: ${resource_info}"

    # Append tier result
    ${tier_first} || tier_results+=","
    tier_results+="{
      \"tier\": ${tier},
      \"new_cds_created\": ${new_cds},
      \"actual_cds_in_cluster\": ${actual_cds},
      \"create_time_ms\": ${tier_create_ms},
      \"all_ready_time_ms\": ${tier_ready_ms},
      \"failed_cds\": ${failed},
      \"ready_latency\": {
        \"count\": ${ready_count},
        \"p50_ms\": ${ready_p50},
        \"p95_ms\": ${ready_p95},
        \"p99_ms\": ${ready_p99},
        \"max_ms\": ${ready_max:-0}
      },
      \"controller_resources\": ${resource_info},
      \"workqueue_metrics\": ${wq_metrics}
    }"
    tier_first=false
done

tier_results+="]"

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------
report_results "${TEST_NAME}" "$(cat <<EOJSON
{
  "config": {
    "tiers": [$(echo "${TIERS}" | tr ' ' ',')],
    "num_nodes": ${NUM_NODES},
    "settle_time_sec": ${SETTLE_TIME}
  },
  "scale_curve": ${tier_results}
}
EOJSON
)"

log_info "=== ${TEST_NAME} complete ==="
