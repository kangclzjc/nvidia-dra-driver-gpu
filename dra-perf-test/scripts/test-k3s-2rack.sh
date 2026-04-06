#!/bin/bash
# k3s E2E: 2 Racks / 36 Nodes
set -euo pipefail
export KUBECONFIG=/tmp/k3s-kubeconfig

NS="nvidia-dra-driver"
RACKS=("rack0001" "rack0002")
REAL_NODE=$(kubectl get nodes --selector='!node.kubernetes.io/fake' -o jsonpath='{.items[0].metadata.name}')
now_ms() { date +%s%3N; }

echo "============================================"
echo "  k3s E2E: 2 Racks / 36 Nodes"
echo "  Real node: $REAL_NODE"
echo "============================================"

# Clean
kubectl -n $NS delete pods -l role=plugin --wait=false 2>/dev/null || true
kubectl -n $NS delete pods -l role=daemon --wait=false 2>/dev/null || true
kubectl -n $NS delete computedomain --all --wait=false 2>/dev/null || true
sleep 5

echo "--- Setup: 36 plugins (not timed) ---"
for rack in "${RACKS[@]}"; do
  for i in $(seq 1 18); do
    node_name=$(printf "fake-${rack}-node%02d" $i)
    cat <<PEOF | kubectl -n $NS create -f - >/dev/null 2>&1 &
apiVersion: v1
kind: Pod
metadata:
  name: plugin-${node_name}
  namespace: $NS
  labels:
    role: plugin
    rack: ${rack}
spec:
  nodeName: ${REAL_NODE}
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
    command: [fake-cd-kubelet-plugin, --node-name=${node_name}, --num-channels=1, --cd-name=placeholder, --cd-namespace=$NS, --cd-uid=placeholder, --kubelet-plugins-directory-path=/tmp/kubelet-plugins, --kubelet-registrar-directory-path=/tmp/kubelet-registry, --cdi-dir=/tmp/cdi, -v=2]
    volumeMounts:
    - name: tmpdir
      mountPath: /tmp
    resources: {requests: {memory: "16Mi", cpu: "5m"}, limits: {memory: "64Mi"}}
  volumes:
  - name: tmpdir
    emptyDir: {}
PEOF
  done
done
wait

for attempt in $(seq 1 120); do
  running=$(kubectl -n $NS get pods -l role=plugin --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$running" -ge 36 ]; then break; fi
  echo -ne "  Plugins: ${running}/36 (${attempt}s)\r"
  sleep 1
done
rs=$(kubectl get resourceslices --no-headers 2>/dev/null | grep -c "compute-domain.nvidia.com" || true)
echo "  ✅ 36 plugins Running, ${rs} RS                                "
echo ""

echo "--- Benchmark: CD lifecycle ---"
T0=$(now_ms)

# Create 2 CDs
for rack in "${RACKS[@]}"; do
  kubectl -n $NS apply -f - >/dev/null <<CDEOF
apiVersion: resource.nvidia.com/v1beta1
kind: ComputeDomain
metadata:
  name: cd-${rack}
  namespace: $NS
spec:
  numNodes: 0
  channel:
    allocationMode: Single
    resourceClaimTemplate:
      name: cd-${rack}-channels
CDEOF
done
sleep 2

declare -A CD_UUIDS
for rack in "${RACKS[@]}"; do
  CD_UUIDS[$rack]=$(kubectl -n $NS get computedomain "cd-${rack}" -o jsonpath='{.metadata.uid}')
  kubectl -n $NS delete daemonset "computedomain-daemon-${CD_UUIDS[$rack]}" --wait=false 2>/dev/null || true
done
sleep 1
for rack in "${RACKS[@]}"; do
  kubectl -n $NS delete daemonset "computedomain-daemon-${CD_UUIDS[$rack]}" --wait=false 2>/dev/null || true
done

T_CD=$(( $(now_ms) - T0 ))
echo "  2 CDs created: ${T_CD}ms"

# Deploy 36 daemons
T_DEPLOY=$(now_ms)
for rack in "${RACKS[@]}"; do
  uuid="${CD_UUIDS[$rack]}"
  for i in $(seq 1 18); do
    node_name=$(printf "fake-${rack}-node%02d" $i)
    cat <<DEOF | kubectl -n $NS create -f - >/dev/null &
apiVersion: v1
kind: Pod
metadata:
  name: daemon-${node_name}
  namespace: $NS
  labels:
    role: daemon
    rack: ${rack}
    resource.nvidia.com/computeDomain: "${uuid}"
spec:
  nodeName: ${REAL_NODE}
  tolerations:
    - operator: Exists
  serviceAccountName: compute-domain-daemon-service-account
  containers:
  - name: daemon
    image: compute-domain-daemon:dry-run
    imagePullPolicy: Never
    env:
    - name: POD_IP
      valueFrom: {fieldRef: {fieldPath: status.podIP}}
    - name: POD_NAME
      valueFrom: {fieldRef: {fieldPath: metadata.name}}
    - name: POD_NAMESPACE
      valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
    - name: POD_UID
      valueFrom: {fieldRef: {fieldPath: metadata.uid}}
    command: [compute-domain-daemon, --dry-run, --node-name=${node_name}, --compute-domain-name=cd-${rack}, --compute-domain-namespace=$NS, --compute-domain-uuid=${uuid}, --cliqueid=${uuid}, --max-nodes-per-imex-domain=18, -v=2, run]
    resources: {requests: {memory: "16Mi", cpu: "5m"}, limits: {memory: "64Mi"}}
DEOF
  done
done
wait
T_SUBMIT=$(( $(now_ms) - T_DEPLOY ))
echo "  36 daemons submitted: ${T_SUBMIT}ms"

for attempt in $(seq 1 120); do
  running=$(kubectl -n $NS get pods -l role=daemon --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$running" -ge 36 ]; then break; fi
  echo -ne "  Daemons: ${running}/36 (${attempt}s)\r"
  sleep 1
done
T_RUN=$(( $(now_ms) - T_DEPLOY ))
echo "  36 daemons Running: ${T_RUN}ms                              "

for attempt in $(seq 1 120); do
  ready_cds=0
  for rack in "${RACKS[@]}"; do
    cs=$(kubectl -n $NS get computedomain "cd-${rack}" -o jsonpath='{.status.status}' 2>/dev/null || echo "?")
    nc=$(kubectl -n $NS get computedomain "cd-${rack}" -o jsonpath='{.status.nodes}' 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    [ "$cs" = "Ready" ] && [ "$nc" -ge 18 ] && ready_cds=$((ready_cds+1))
  done
  if [ "$ready_cds" -ge 2 ]; then break; fi
  echo -ne "  CDs Ready: ${ready_cds}/2 (${attempt}s)\r"
  sleep 1
done
T_READY=$(( $(now_ms) - T0 ))

echo ""
for rack in "${RACKS[@]}"; do
  cs=$(kubectl -n $NS get computedomain "cd-${rack}" -o jsonpath='{.status.status}' 2>/dev/null)
  nc=$(kubectl -n $NS get computedomain "cd-${rack}" -o jsonpath='{.status.nodes}' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{len(d)} nodes, {sum(1 for n in d if n.get(\"status\")==\"Ready\")} Ready')" 2>/dev/null)
  echo "  cd-${rack}: ${cs} (${nc})"
done

echo ""
echo "============================================"
echo "  RESULTS (k3s native, 2 rack, parallel)"
echo "============================================"
echo "  CD Create:          ${T_CD}ms"
echo "  Daemon submit:      ${T_SUBMIT}ms"
echo "  Daemon all Running: ${T_RUN}ms"
echo "  E2E All Ready:      ${T_READY}ms"
echo "============================================"
free -h | grep Mem | awk '{print "  Mem: "$3" used / "$7" available"}'
