#!/bin/bash
# E2E Benchmark: 2 Racks (36 nodes), parallel pod creation
set -euo pipefail

CTX="--context kind-dra-perf"
NS="nvidia-dra-driver"
RACKS=("rack0001" "rack0002")

now_ms() { date +%s%3N; }

echo "============================================"
echo "  SETUP: Deploy plugins for 2 racks (36 nodes)"
echo "============================================"

# Clean
kubectl $CTX -n $NS delete pods -l role=plugin --wait=false 2>/dev/null || true
kubectl $CTX -n $NS delete pods -l role=daemon --wait=false 2>/dev/null || true
kubectl $CTX -n $NS delete computedomain --all --wait=false 2>/dev/null || true
sleep 5

# Deploy 36 plugins in parallel
for rack in "${RACKS[@]}"; do
  for i in $(seq 1 18); do
    node_name=$(printf "fake-${rack}-node%02d" $i)
    cat <<PEOF | kubectl $CTX -n $NS create -f - >/dev/null 2>&1 &
apiVersion: v1
kind: Pod
metadata:
  name: plugin-${node_name}
  namespace: $NS
  labels:
    app: fake-kubelet-plugin
    role: plugin
    rack: e2e-${rack}
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node.kubernetes.io/fake
                operator: DoesNotExist
  tolerations:
    - operator: Exists
  serviceAccountName: compute-domain-daemon-service-account
  initContainers:
  - name: init-dirs
    image: debian:bookworm-slim
    command: ["sh", "-c", "mkdir -p /tmp/kubelet-plugins/compute-domain.nvidia.com /tmp/kubelet-registry /tmp/cdi"]
    volumeMounts:
    - name: tmpdir
      mountPath: /tmp
  containers:
  - name: plugin
    image: fake-cd-kubelet-plugin:perf
    imagePullPolicy: Never
    command:
      - fake-cd-kubelet-plugin
      - --node-name=${node_name}
      - --num-channels=1
      - --cd-name=placeholder
      - --cd-namespace=$NS
      - --cd-uid=placeholder
      - --kubelet-plugins-directory-path=/tmp/kubelet-plugins
      - --kubelet-registrar-directory-path=/tmp/kubelet-registry
      - --cdi-dir=/tmp/cdi
      - -v=2
    volumeMounts:
    - name: tmpdir
      mountPath: /tmp
    resources:
      requests:
        memory: "16Mi"
        cpu: "5m"
      limits:
        memory: "64Mi"
  volumes:
  - name: tmpdir
    emptyDir: {}
PEOF
  done
done
wait
echo "  36 plugin pods submitted (parallel)"

for attempt in $(seq 1 120); do
  running=$(kubectl $CTX -n $NS get pods -l role=plugin --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$running" -ge 36 ]; then break; fi
  echo -ne "  Waiting: ${running}/36 plugins Running (${attempt}s)\r"
  sleep 1
done
rs=$(kubectl $CTX get resourceslices --no-headers 2>/dev/null | grep -c "compute-domain.nvidia.com" || true)
echo "  ✅ 36 plugins Running, ${rs} ResourceSlices                  "
echo ""

# ==========================================
# BENCHMARK
# ==========================================

run_test() {
  local MODE=$1  # "serial" or "parallel"
  echo "============================================"
  echo "  TEST: 2 Racks / 36 nodes ($MODE daemon deploy)"
  echo "============================================"
  echo ""

  # Clean
  kubectl $CTX -n $NS delete pods -l role=daemon --wait=false 2>/dev/null || true
  kubectl $CTX -n $NS delete computedomain --all --wait=false 2>/dev/null || true
  sleep 5

  # Phase 1: Create 2 CDs
  T0=$(now_ms)
  for rack in "${RACKS[@]}"; do
    cat <<CDEOF | kubectl $CTX -n $NS apply -f - >/dev/null
apiVersion: resource.nvidia.com/v1beta1
kind: ComputeDomain
metadata:
  name: cd-e2e-${rack}
  namespace: $NS
spec:
  numNodes: 0
  channel:
    allocationMode: Single
    resourceClaimTemplate:
      name: cd-e2e-${rack}-channels
CDEOF
  done
  sleep 2

  # Get UUIDs and delete auto-DaemonSets
  declare -A CD_UUIDS
  for rack in "${RACKS[@]}"; do
    CD_UUIDS[$rack]=$(kubectl $CTX -n $NS get computedomain "cd-e2e-${rack}" -o jsonpath='{.metadata.uid}')
    kubectl $CTX -n $NS delete daemonset "computedomain-daemon-${CD_UUIDS[$rack]}" --wait=false 2>/dev/null || true
  done
  sleep 1
  # Delete again in case recreated
  for rack in "${RACKS[@]}"; do
    kubectl $CTX -n $NS delete daemonset "computedomain-daemon-${CD_UUIDS[$rack]}" --wait=false 2>/dev/null || true
  done

  T_CD=$(( $(now_ms) - T0 ))
  echo "  2 CDs created: ${T_CD}ms"
  for rack in "${RACKS[@]}"; do
    echo "    ${rack}: ${CD_UUIDS[$rack]}"
  done

  # Phase 2: Deploy 36 daemon pods
  T_DEPLOY=$(now_ms)
  for rack in "${RACKS[@]}"; do
    local uuid="${CD_UUIDS[$rack]}"
    for i in $(seq 1 18); do
      node_name=$(printf "fake-${rack}-node%02d" $i)
      if [ "$MODE" = "parallel" ]; then
        cat <<DEOF | kubectl $CTX -n $NS create -f - >/dev/null &
apiVersion: v1
kind: Pod
metadata:
  name: daemon-${node_name}
  namespace: $NS
  labels:
    app: daemon-dry-run
    role: daemon
    rack: e2e-${rack}
    resource.nvidia.com/computeDomain: "${uuid}"
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node.kubernetes.io/fake
                operator: DoesNotExist
  tolerations:
    - operator: Exists
  serviceAccountName: compute-domain-daemon-service-account
  containers:
  - name: daemon
    image: compute-domain-daemon:dry-run
    imagePullPolicy: Never
    env:
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
    - name: POD_UID
      valueFrom:
        fieldRef:
          fieldPath: metadata.uid
    command:
      - compute-domain-daemon
      - --dry-run
      - --node-name=${node_name}
      - --compute-domain-name=cd-e2e-${rack}
      - --compute-domain-namespace=$NS
      - --compute-domain-uuid=${uuid}
      - --cliqueid=${uuid}
      - --max-nodes-per-imex-domain=18
      - -v=2
      - run
    resources:
      requests:
        memory: "16Mi"
        cpu: "5m"
      limits:
        memory: "64Mi"
DEOF
      else
        # Serial
        cat <<DEOF | kubectl $CTX -n $NS create -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: daemon-${node_name}
  namespace: $NS
  labels:
    app: daemon-dry-run
    role: daemon
    rack: e2e-${rack}
    resource.nvidia.com/computeDomain: "${uuid}"
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node.kubernetes.io/fake
                operator: DoesNotExist
  tolerations:
    - operator: Exists
  serviceAccountName: compute-domain-daemon-service-account
  containers:
  - name: daemon
    image: compute-domain-daemon:dry-run
    imagePullPolicy: Never
    env:
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
    - name: POD_UID
      valueFrom:
        fieldRef:
          fieldPath: metadata.uid
    command:
      - compute-domain-daemon
      - --dry-run
      - --node-name=${node_name}
      - --compute-domain-name=cd-e2e-${rack}
      - --compute-domain-namespace=$NS
      - --compute-domain-uuid=${uuid}
      - --cliqueid=${uuid}
      - --max-nodes-per-imex-domain=18
      - -v=2
      - run
    resources:
      requests:
        memory: "16Mi"
        cpu: "5m"
      limits:
        memory: "64Mi"
DEOF
      fi
    done
  done
  [ "$MODE" = "parallel" ] && wait
  T_SUBMIT=$(( $(now_ms) - T_DEPLOY ))
  echo "  36 daemon pods submitted ($MODE): ${T_SUBMIT}ms"

  # Wait for all Running
  for attempt in $(seq 1 120); do
    running=$(kubectl $CTX -n $NS get pods -l role=daemon --no-headers 2>/dev/null | grep -c Running || true)
    if [ "$running" -ge 36 ]; then break; fi
    echo -ne "  Daemon Running: ${running}/36 (${attempt}s)\r"
    sleep 1
  done
  T_RUN=$(( $(now_ms) - T_DEPLOY ))
  echo "  36 daemons Running: ${T_RUN}ms                              "

  # Wait for both CDs Ready
  for attempt in $(seq 1 120); do
    ready_cds=0
    for rack in "${RACKS[@]}"; do
      cs=$(kubectl $CTX -n $NS get computedomain "cd-e2e-${rack}" -o jsonpath='{.status.status}' 2>/dev/null || echo "?")
      nc=$(kubectl $CTX -n $NS get computedomain "cd-e2e-${rack}" -o jsonpath='{.status.nodes}' 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
      [ "$cs" = "Ready" ] && [ "$nc" -ge 18 ] && ready_cds=$((ready_cds+1))
    done
    if [ "$ready_cds" -ge 2 ]; then break; fi
    echo -ne "  CDs Ready: ${ready_cds}/2 (${attempt}s)\r"
    sleep 1
  done
  T_READY=$(( $(now_ms) - T0 ))

  # Final status
  echo ""
  for rack in "${RACKS[@]}"; do
    cs=$(kubectl $CTX -n $NS get computedomain "cd-e2e-${rack}" -o jsonpath='{.status.status}' 2>/dev/null)
    nc=$(kubectl $CTX -n $NS get computedomain "cd-e2e-${rack}" -o jsonpath='{.status.nodes}' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{len(d)} nodes, {sum(1 for n in d if n[\"status\"]==\"Ready\")} Ready')" 2>/dev/null)
    echo "  cd-e2e-${rack}: ${cs} (${nc})"
  done

  echo ""
  echo "  ► RESULTS ($MODE):"
  echo "    CD Create:          ${T_CD}ms"
  echo "    Daemon submit:      ${T_SUBMIT}ms"
  echo "    Daemon all Running: ${T_RUN}ms"
  echo "    E2E All Ready:      ${T_READY}ms"
  echo ""
  docker stats --no-stream --format "    {{.Name}}: {{.MemUsage}} ({{.CPUPerc}} CPU)" 2>/dev/null | grep dra-perf

  # Cleanup
  echo ""
  echo "  Cleaning up..."
  kubectl $CTX -n $NS delete pods -l role=daemon --wait=false 2>/dev/null || true
  kubectl $CTX -n $NS delete computedomain --all --wait=false 2>/dev/null || true
  for attempt in $(seq 1 60); do
    rem=$(kubectl $CTX -n $NS get pods -l role=daemon --no-headers 2>/dev/null | grep -c . || true)
    if [ "${rem:-0}" -eq 0 ]; then break; fi
    sleep 1
  done
  sleep 3
  echo "  Cleanup done"
  echo ""
}

# Run both modes
run_test "serial"
run_test "parallel"

# Final cleanup
echo "=== Final cleanup ==="
kubectl $CTX -n $NS delete pods -l role=plugin --wait=false 2>/dev/null || true
kubectl $CTX -n $NS delete pods -l role=daemon --wait=false 2>/dev/null || true
kubectl $CTX -n $NS delete computedomain --all --wait=false 2>/dev/null || true
echo "Done"
