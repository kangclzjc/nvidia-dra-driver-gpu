#!/bin/bash
# test-cd-full.sh - Full CD performance test suite at 1000 node scale
set -euo pipefail

CTX="kind-dra-perf"
NS="nvidia-dra-driver"
RESULTS_DIR="$(dirname "$0")/../results"
mkdir -p "$RESULTS_DIR"
RESULT_FILE="$RESULTS_DIR/cd-perf-1000node.jsonl"
> "$RESULT_FILE"

timestamp() { date +%s%3N; }

echo "============================================"
echo "  CD Performance Test @ 1000 Node / 56 Rack"
echo "============================================"
echo ""

# ============================================
# Test 1: Single CD Create→Ready Latency
# ============================================
echo "--- Test 1: Single CD Create→Ready Latency (5 iterations) ---"
single_results=()

for iter in $(seq 1 5); do
  cd_name="cd-single-test-${iter}"
  
  start=$(timestamp)
  kubectl --context "$CTX" -n "$NS" apply -f - >/dev/null 2>&1 <<EOF
apiVersion: resource.nvidia.com/v1beta1
kind: ComputeDomain
metadata:
  name: ${cd_name}
  namespace: ${NS}
spec:
  numNodes: 0
  channel:
    allocationMode: Single
    resourceClaimTemplate:
      name: ${cd_name}-channels
EOF
  
  # Poll for Ready
  timeout_s=60
  elapsed=0
  status=""
  while [ $elapsed -lt $timeout_s ]; do
    status=$(kubectl --context "$CTX" -n "$NS" get computedomain "${cd_name}" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    if [ "$status" = "Ready" ]; then
      break
    fi
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
  end=$(timestamp)
  
  latency=$((end - start))
  single_results+=($latency)
  echo "  Iter ${iter}: ${latency}ms (status: ${status:-timeout})"
  
  # Cleanup
  kubectl --context "$CTX" -n "$NS" delete computedomain "${cd_name}" --wait=true >/dev/null 2>&1
  sleep 2
done

# Stats
sum=0; min=999999; max=0
for r in "${single_results[@]}"; do
  sum=$((sum + r))
  [ $r -lt $min ] && min=$r
  [ $r -gt $max ] && max=$r
done
avg=$((sum / ${#single_results[@]}))
echo ""
echo "  ► Single CD: min=${min}ms  avg=${avg}ms  max=${max}ms"
echo "{\"test\":\"single_cd_create_ready\",\"nodes\":1000,\"racks\":56,\"iterations\":5,\"min_ms\":${min},\"avg_ms\":${avg},\"max_ms\":${max}}" >> "$RESULT_FILE"

# ============================================
# Test 2: 56 CDs Concurrent Create
# ============================================
echo ""
echo "--- Test 2: 56 CDs Concurrent Create (1 per rack) ---"

start=$(timestamp)

# Create all 56 CDs concurrently
for rack in $(seq 1 56); do
  cd_name=$(printf "cd-rack%04d" $rack)
  kubectl --context "$CTX" -n "$NS" apply -f - >/dev/null 2>&1 <<EOF &
apiVersion: resource.nvidia.com/v1beta1
kind: ComputeDomain
metadata:
  name: ${cd_name}
  namespace: ${NS}
spec:
  numNodes: 0
  channel:
    allocationMode: Single
    resourceClaimTemplate:
      name: ${cd_name}-channels
EOF
done
wait

submit_end=$(timestamp)
echo "  All 56 CDs submitted in $((submit_end - start))ms"

# Wait for all to be Ready
timeout_s=180
elapsed=0
while [ $elapsed -lt $timeout_s ]; do
  ready_count=$(kubectl --context "$CTX" -n "$NS" get computedomain -o jsonpath='{range .items[*]}{.status.status}{"\n"}{end}' 2>/dev/null | grep -c "Ready" || echo 0)
  total_count=$(kubectl --context "$CTX" -n "$NS" get computedomain --no-headers 2>/dev/null | wc -l)
  echo -ne "\r  Ready: ${ready_count}/${total_count} (${elapsed}s)  "
  if [ "$ready_count" -ge 56 ]; then
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

all_ready_end=$(timestamp)
echo ""
echo "  ► 56 CDs all Ready in $((all_ready_end - start))ms (submit: $((submit_end - start))ms)"
echo "{\"test\":\"multi_cd_56_create\",\"nodes\":1000,\"racks\":56,\"submit_ms\":$((submit_end - start)),\"all_ready_ms\":$((all_ready_end - start))}" >> "$RESULT_FILE"

# Check DaemonSets created
ds_count=$(kubectl --context "$CTX" -n "$NS" get daemonsets --no-headers 2>/dev/null | wc -l)
echo "  DaemonSets created: ${ds_count}"

# Check daemon pods
pod_count=$(kubectl --context "$CTX" -n "$NS" get pods -l app.kubernetes.io/component=compute-domain-daemon --no-headers 2>/dev/null | wc -l)
echo "  Daemon pods: ${pod_count}"

# Resource pressure
echo ""
echo "--- Resource Pressure at 56 CDs ---"
echo "  Nodes:           $(kubectl --context "$CTX" get nodes --no-headers | wc -l)"
echo "  ResourceSlices:  $(kubectl --context "$CTX" get resourceslices --no-headers | wc -l)"
echo "  CDs:             $(kubectl --context "$CTX" -n "$NS" get computedomain --no-headers | wc -l)"
echo "  DaemonSets:      ${ds_count}"
echo "  Pods:            $(kubectl --context "$CTX" -n "$NS" get pods --no-headers 2>/dev/null | wc -l)"
echo -n "  API (get CDs):   " && { time kubectl --context "$CTX" -n "$NS" get computedomain >/dev/null 2>&1 ; } 2>&1 | grep real
echo -n "  API (get nodes): " && { time kubectl --context "$CTX" get nodes >/dev/null 2>&1 ; } 2>&1 | grep real
echo ""
echo "  Memory:"
docker stats --no-stream --format "  {{.Name}}: {{.MemUsage}} ({{.CPUPerc}} CPU)" 2>/dev/null | grep dra-perf
free -h | grep Mem | awk '{print "  Host: "$2" total, "$3" used, "$7" available"}'

echo "{\"test\":\"resource_pressure_56cd\",\"ds_count\":${ds_count},\"pod_count\":${pod_count}}" >> "$RESULT_FILE"

# ============================================
# Test 3: Batch Delete 56 CDs + Create/Delete Cycles
# ============================================
echo ""
echo "--- Test 3: Batch Delete 56 CDs ---"

del_start=$(timestamp)

for rack in $(seq 1 56); do
  cd_name=$(printf "cd-rack%04d" $rack)
  kubectl --context "$CTX" -n "$NS" delete computedomain "${cd_name}" --wait=false >/dev/null 2>&1 &
done
wait

del_submit=$(timestamp)
echo "  Delete commands sent in $((del_submit - del_start))ms"

# Wait for all deleted
elapsed=0
while [ $elapsed -lt 180 ]; do
  remaining=$(kubectl --context "$CTX" -n "$NS" get computedomain --no-headers 2>/dev/null | wc -l)
  echo -ne "\r  Remaining: ${remaining}    "
  if [ "$remaining" -eq 0 ]; then
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

del_end=$(timestamp)
echo ""
echo "  ► 56 CDs deleted in $((del_end - del_start))ms (submit: $((del_submit - del_start))ms)"
echo "{\"test\":\"multi_cd_56_delete\",\"submit_ms\":$((del_submit - del_start)),\"total_ms\":$((del_end - del_start))}" >> "$RESULT_FILE"

# Wait for DaemonSets cleanup
sleep 5
ds_remaining=$(kubectl --context "$CTX" -n "$NS" get daemonsets --no-headers 2>/dev/null | wc -l)
echo "  DaemonSets remaining: ${ds_remaining}"

# ============================================
# Test 4: Rapid Create/Delete Cycle (stress test)
# ============================================
echo ""
echo "--- Test 4: Rapid Create/Delete Cycle (10 iterations) ---"
cycle_results=()

for iter in $(seq 1 10); do
  cd_name="cd-stress-${iter}"
  
  c_start=$(timestamp)
  kubectl --context "$CTX" -n "$NS" apply -f - >/dev/null 2>&1 <<EOF
apiVersion: resource.nvidia.com/v1beta1
kind: ComputeDomain
metadata:
  name: ${cd_name}
  namespace: ${NS}
spec:
  numNodes: 0
  channel:
    allocationMode: Single
    resourceClaimTemplate:
      name: ${cd_name}-channels
EOF
  
  # Wait Ready
  for _ in $(seq 1 100); do
    s=$(kubectl --context "$CTX" -n "$NS" get computedomain "${cd_name}" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    [ "$s" = "Ready" ] && break
    sleep 0.1
  done
  c_ready=$(timestamp)
  
  # Delete
  kubectl --context "$CTX" -n "$NS" delete computedomain "${cd_name}" --wait=true >/dev/null 2>&1
  c_done=$(timestamp)
  
  create_ms=$((c_ready - c_start))
  delete_ms=$((c_done - c_ready))
  total_ms=$((c_done - c_start))
  cycle_results+=($total_ms)
  echo "  Cycle ${iter}: create=${create_ms}ms delete=${delete_ms}ms total=${total_ms}ms"
  sleep 1
done

# Stats
sum=0; min=999999; max=0
for r in "${cycle_results[@]}"; do
  sum=$((sum + r))
  [ $r -lt $min ] && min=$r
  [ $r -gt $max ] && max=$r
done
avg=$((sum / ${#cycle_results[@]}))
echo ""
echo "  ► Cycle: min=${min}ms  avg=${avg}ms  max=${max}ms"
echo "{\"test\":\"rapid_create_delete_cycle\",\"iterations\":10,\"min_ms\":${min},\"avg_ms\":${avg},\"max_ms\":${max}}" >> "$RESULT_FILE"

# ============================================
# Final Summary
# ============================================
echo ""
echo "============================================"
echo "  ALL TESTS COMPLETE"
echo "============================================"
echo ""
echo "Results saved to: $RESULT_FILE"
cat "$RESULT_FILE" | while read line; do echo "  $line"; done
echo ""
echo "Final memory:"
docker stats --no-stream --format "  {{.Name}}: {{.MemUsage}}" 2>/dev/null | grep dra-perf
free -h | grep Mem
