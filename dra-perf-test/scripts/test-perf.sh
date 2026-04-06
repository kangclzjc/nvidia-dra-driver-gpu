#!/bin/bash
# test-perf.sh - Performance test harness
# Measures CD create→ready, multi-CD, and scale tests
# Usage: ./test-perf.sh [PHASE] (1=18node, 2=90node, 3=200node)
set -euo pipefail

CTX="kind-dra-perf"
NODES_PER_RACK=18
RESULTS_DIR="$(dirname "$0")/../results"
mkdir -p "$RESULTS_DIR"

phase=${1:-1}
case $phase in
  1) NUM_NODES=18;  NUM_RACKS=1  ;;
  2) NUM_NODES=90;  NUM_RACKS=5  ;;
  3) NUM_NODES=200; NUM_RACKS=11 ;;
  *) echo "Usage: $0 [1|2|3]"; exit 1 ;;
esac

echo "========================================="
echo "  DRA ComputeDomain Perf Test - Phase $phase"
echo "  Nodes: $NUM_NODES  Racks: $NUM_RACKS"
echo "========================================="
echo ""

timestamp() { date +%s%3N; }  # milliseconds

# --- Test 1: Single CD Create→Ready Latency ---
test_single_cd_latency() {
  echo "--- Test 1: Single CD Create→Ready Latency ---"
  local results=()
  local iterations=5
  
  for iter in $(seq 1 $iterations); do
    local cd_name="cd-latency-test-${iter}"
    
    local start=$(timestamp)
    kubectl --context "$CTX" apply -f - <<EOF >/dev/null 2>&1
apiVersion: resource.nvidia.com/v1alpha1
kind: ComputeDomain
metadata:
  name: ${cd_name}
spec:
  numNodes: 0
  channel:
    allocationMode: Single
EOF
    
    # Wait for CD to become Ready (poll)
    local timeout=60
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
      status=$(kubectl --context "$CTX" get computedomain "${cd_name}" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
      if [ "$status" = "Ready" ]; then
        break
      fi
      sleep 0.1
      elapsed=$((elapsed + 1))
    done
    local end=$(timestamp)
    
    local latency=$((end - start))
    results+=($latency)
    echo "  Iteration ${iter}: ${latency}ms (status: ${status:-timeout})"
    
    # Cleanup
    kubectl --context "$CTX" delete computedomain "${cd_name}" --wait=false >/dev/null 2>&1
    sleep 2
  done
  
  # Calculate stats
  local sum=0
  local min=999999
  local max=0
  for r in "${results[@]}"; do
    sum=$((sum + r))
    [ $r -lt $min ] && min=$r
    [ $r -gt $max ] && max=$r
  done
  local avg=$((sum / ${#results[@]}))
  
  echo ""
  echo "  Results: min=${min}ms avg=${avg}ms max=${max}ms"
  echo '{"test":"single_cd_latency","phase":'$phase',"nodes":'$NUM_NODES',"racks":'$NUM_RACKS',"iterations":'$iterations',"min_ms":'$min',"avg_ms":'$avg',"max_ms":'$max'}' >> "$RESULTS_DIR/phase${phase}.jsonl"
}

# --- Test 2: Multi-CD Concurrent Create ---
test_multi_cd_concurrent() {
  echo ""
  echo "--- Test 2: ${NUM_RACKS} CDs Concurrent Create ---"
  
  local start=$(timestamp)
  
  # Create all CDs at once
  for rack in $(seq 1 $NUM_RACKS); do
    cd_name=$(printf "cd-rack%04d" $rack)
    kubectl --context "$CTX" apply -f - <<EOF >/dev/null 2>&1 &
apiVersion: resource.nvidia.com/v1alpha1
kind: ComputeDomain
metadata:
  name: ${cd_name}
spec:
  numNodes: 0
  channel:
    allocationMode: Single
EOF
  done
  wait
  
  local create_end=$(timestamp)
  echo "  All ${NUM_RACKS} CDs submitted in $((create_end - start))ms"
  
  # Wait for all to be Ready
  local timeout=120
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    ready_count=$(kubectl --context "$CTX" get computedomain -o json 2>/dev/null | grep -c '"status":"Ready"' || echo 0)
    echo -ne "\r  Ready: ${ready_count}/${NUM_RACKS} (${elapsed}s)"
    if [ "$ready_count" -ge "$NUM_RACKS" ]; then
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  
  local all_ready_end=$(timestamp)
  echo ""
  echo "  All Ready in $((all_ready_end - start))ms"
  
  echo '{"test":"multi_cd_concurrent","phase":'$phase',"nodes":'$NUM_NODES',"racks":'$NUM_RACKS',"submit_ms":'$((create_end - start))',"all_ready_ms":'$((all_ready_end - start))'}' >> "$RESULTS_DIR/phase${phase}.jsonl"
  
  # Test delete
  echo ""
  echo "--- Test 3: Batch Delete ${NUM_RACKS} CDs ---"
  local del_start=$(timestamp)
  
  for rack in $(seq 1 $NUM_RACKS); do
    cd_name=$(printf "cd-rack%04d" $rack)
    kubectl --context "$CTX" delete computedomain "${cd_name}" --wait=false >/dev/null 2>&1 &
  done
  wait
  
  # Wait for all deleted
  elapsed=0
  while [ $elapsed -lt $timeout ]; do
    remaining=$(kubectl --context "$CTX" get computedomain --no-headers 2>/dev/null | wc -l)
    echo -ne "\r  Remaining: ${remaining}"
    if [ "$remaining" -eq 0 ]; then
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  
  local del_end=$(timestamp)
  echo ""
  echo "  All deleted in $((del_end - del_start))ms"
  
  echo '{"test":"multi_cd_delete","phase":'$phase',"racks":'$NUM_RACKS',"delete_ms":'$((del_end - del_start))'}' >> "$RESULTS_DIR/phase${phase}.jsonl"
}

# --- Test 4: Resource Pressure ---
test_resource_pressure() {
  echo ""
  echo "--- Test 4: API Server Resource Pressure ---"
  
  echo "  Node objects:      $(kubectl --context "$CTX" get nodes --no-headers | wc -l)"
  echo "  Fake nodes:        $(kubectl --context "$CTX" get nodes -l node.kubernetes.io/fake=true --no-headers 2>/dev/null | wc -l)"
  echo "  ResourceSlices:    $(kubectl --context "$CTX" get resourceslices --no-headers 2>/dev/null | wc -l)"
  echo "  Pods:              $(kubectl --context "$CTX" get pods -A --no-headers | wc -l)"
  
  # Measure API latency
  local api_start=$(timestamp)
  kubectl --context "$CTX" get nodes >/dev/null 2>&1
  local api_end=$(timestamp)
  echo "  API latency (get nodes): $((api_end - api_start))ms"
  
  api_start=$(timestamp)
  kubectl --context "$CTX" get resourceslices >/dev/null 2>&1
  api_end=$(timestamp)
  echo "  API latency (get resourceslices): $((api_end - api_start))ms"
  
  echo ""
  echo "  Host memory:"
  free -h | grep Mem
  
  echo '{"test":"resource_pressure","phase":'$phase',"nodes":'$NUM_NODES'}' >> "$RESULTS_DIR/phase${phase}.jsonl"
}

# --- Run ---
test_resource_pressure

echo ""
echo "Note: CD lifecycle tests require ComputeDomain CRD and controller."
echo "Checking if CRD exists..."
if kubectl --context "$CTX" api-resources | grep -q computedomain; then
  test_single_cd_latency
  test_multi_cd_concurrent
else
  echo "ComputeDomain CRD not found. Skipping CD tests."
  echo "To run CD tests, deploy the CRD and controller first."
  echo ""
  echo "API-level tests completed. Results in: $RESULTS_DIR/phase${phase}.jsonl"
fi

echo ""
echo "========================================="
echo "  Phase $phase Complete"
echo "========================================="
