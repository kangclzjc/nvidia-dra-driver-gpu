#!/bin/bash
# E2E Performance Test v2: 1 Rack (18 nodes) → Full Ready
# Fixes: correct labels, delete auto-DaemonSet, use real podIP via fieldRef
set -euo pipefail

CTX="--context kind-dra-perf"
NS="nvidia-dra-driver"
RACK="rack0001"

now_ms() { date +%s%3N; }

echo "============================================"
echo "  E2E Perf Test v2: 1 Rack / 18 Nodes"
echo "  1 channel/node → target: Ready"
echo "============================================"
echo ""

# Ensure clean state
kubectl $CTX -n $NS delete pods -l rack=e2e-$RACK --wait=false 2>/dev/null || true
kubectl $CTX -n $NS delete computedomain cd-e2e-$RACK --wait=false 2>/dev/null || true
sleep 5

echo "--- Phase 1: Create CD ---"
T_START=$(now_ms)
kubectl $CTX -n $NS apply -f - <<'CDEOF'
apiVersion: resource.nvidia.com/v1beta1
kind: ComputeDomain
metadata:
  name: cd-e2e-rack0001
  namespace: nvidia-dra-driver
spec:
  numNodes: 0
  channel:
    allocationMode: Single
    resourceClaimTemplate:
      name: cd-e2e-rack0001-channels
CDEOF
sleep 2
CD_UUID=$(kubectl $CTX -n $NS get computedomain cd-e2e-$RACK -o jsonpath='{.metadata.uid}')
CD_STATUS=$(kubectl $CTX -n $NS get computedomain cd-e2e-$RACK -o jsonpath='{.status.status}')
T_CD=$(( $(now_ms) - T_START ))
echo "  CD created: ${T_CD}ms (status: ${CD_STATUS}, UUID: ${CD_UUID})"

# FIX #2: Delete auto-created DaemonSet so it doesn't fight with our pods
sleep 2
DS_NAME="computedomain-daemon-${CD_UUID}"
kubectl $CTX -n $NS delete daemonset "$DS_NAME" --wait=false 2>/dev/null || true
echo "  Auto-DaemonSet deleted"
echo ""

echo "--- Phase 2: Deploy 18 plugin pods (1 channel/node) ---"
T_START=$(now_ms)
for i in $(seq 1 18); do
  node_name=$(printf "fake-${RACK}-node%02d" $i)
  cat <<PLUGINEOF | kubectl $CTX -n $NS create -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: plugin-${node_name}
  namespace: $NS
  labels:
    app: fake-kubelet-plugin
    role: plugin
    rack: e2e-$RACK
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
      - --cd-name=cd-e2e-$RACK
      - --cd-namespace=$NS
      - --cd-uid=${CD_UUID}
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
PLUGINEOF
done
T_SUBMIT_PLUGIN=$(( $(now_ms) - T_START ))
echo "  18 plugin pods submitted: ${T_SUBMIT_PLUGIN}ms"

for attempt in $(seq 1 90); do
  running=$(kubectl $CTX -n $NS get pods -l role=plugin,rack=e2e-$RACK --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$running" -ge 18 ]; then break; fi
  echo -ne "  Waiting: ${running}/18 Running (${attempt}s)\r"
  sleep 1
done
T_PLUGIN_READY=$(( $(now_ms) - T_START ))
echo "  18 plugin pods Running: ${T_PLUGIN_READY}ms                    "

rs_count=$(kubectl $CTX get resourceslices --no-headers 2>/dev/null | grep -c "compute-domain.nvidia.com" || true)
echo "  ResourceSlices published: ${rs_count}"
echo ""

echo "--- Phase 3: Deploy 18 daemon pods (with correct labels + real podIP) ---"
T_START=$(now_ms)

# FIX #2 again: controller may have recreated the DaemonSet
kubectl $CTX -n $NS delete daemonset "$DS_NAME" --wait=false 2>/dev/null || true

for i in $(seq 1 18); do
  node_name=$(printf "fake-${RACK}-node%02d" $i)
  # FIX #1: add resource.nvidia.com/computeDomain label
  # FIX #3: use env fieldRef for real podIP
  cat <<DAEMONEOF | kubectl $CTX -n $NS create -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: daemon-${node_name}
  namespace: $NS
  labels:
    app: daemon-dry-run
    role: daemon
    rack: e2e-$RACK
    resource.nvidia.com/computeDomain: "${CD_UUID}"
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
      - --compute-domain-name=cd-e2e-$RACK
      - --compute-domain-namespace=$NS
      - --compute-domain-uuid=${CD_UUID}
      - --cliqueid=${CD_UUID}
      - --max-nodes-per-imex-domain=18
      - -v=2
      - run
    resources:
      requests:
        memory: "16Mi"
        cpu: "5m"
      limits:
        memory: "64Mi"
DAEMONEOF
done
T_SUBMIT_DAEMON=$(( $(now_ms) - T_START ))
echo "  18 daemon pods submitted: ${T_SUBMIT_DAEMON}ms"

for attempt in $(seq 1 90); do
  running=$(kubectl $CTX -n $NS get pods -l role=daemon,rack=e2e-$RACK --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$running" -ge 18 ]; then break; fi
  echo -ne "  Waiting: ${running}/18 Running (${attempt}s)\r"
  sleep 1
done
T_DAEMON_READY=$(( $(now_ms) - T_START ))
echo "  18 daemon pods Running: ${T_DAEMON_READY}ms                    "
echo ""

echo "--- Phase 4: Wait for 18 nodes registered + CD Ready ---"
T_START=$(now_ms)
for attempt in $(seq 1 120); do
  node_count=$(kubectl $CTX -n $NS get computedomain cd-e2e-$RACK -o jsonpath='{.status.nodes}' 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  cd_status=$(kubectl $CTX -n $NS get computedomain cd-e2e-$RACK -o jsonpath='{.status.status}' 2>/dev/null || echo "?")
  if [ "$node_count" -ge 18 ] && [ "$cd_status" = "Ready" ]; then break; fi
  echo -ne "  Nodes: ${node_count}/18 | CD: ${cd_status} (${attempt}s)\r"
  sleep 1
done
T_ALL_READY=$(( $(now_ms) - T_START ))
final_status=$(kubectl $CTX -n $NS get computedomain cd-e2e-$RACK -o jsonpath='{.status.status}' 2>/dev/null)
final_nodes=$(kubectl $CTX -n $NS get computedomain cd-e2e-$RACK -o jsonpath='{.status.nodes}' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{len(d)} nodes, {sum(1 for n in d if n[\"status\"]==\"Ready\")} Ready')" 2>/dev/null)
echo "  All registered + Ready: ${T_ALL_READY}ms                    "
echo "  CD status: ${final_status} (${final_nodes})"
echo ""

echo "--- Phase 5: Teardown ---"
T_START=$(now_ms)
kubectl $CTX -n $NS delete pods -l rack=e2e-$RACK --wait=false 2>/dev/null
kubectl $CTX -n $NS delete computedomain cd-e2e-$RACK --wait=false 2>/dev/null

for attempt in $(seq 1 120); do
  remaining=$(kubectl $CTX -n $NS get pods -l rack=e2e-$RACK --no-headers 2>/dev/null | wc -l || echo 0)
  if [ "$remaining" -eq 0 ]; then break; fi
  echo -ne "  Pods remaining: ${remaining} (${attempt}s)\r"
  sleep 1
done
T_TEARDOWN=$(( $(now_ms) - T_START ))
echo "  Full teardown: ${T_TEARDOWN}ms                    "
echo ""

echo "============================================"
echo "  RESULTS SUMMARY"
echo "============================================"
echo "  CD Create→Ready:          ${T_CD}ms"
echo "  Plugin submit:            ${T_SUBMIT_PLUGIN}ms"
echo "  Plugin all Running:       ${T_PLUGIN_READY}ms"
echo "  ResourceSlices:           ${rs_count}"
echo "  Daemon submit:            ${T_SUBMIT_DAEMON}ms"
echo "  Daemon all Running:       ${T_DAEMON_READY}ms"
echo "  All nodes Ready:          ${T_ALL_READY}ms"
echo "  CD final status:          ${final_status}"
echo "  Full teardown:            ${T_TEARDOWN}ms"
echo "============================================"
echo ""
echo "=== Resource usage ==="
docker stats --no-stream --format "  {{.Name}}: {{.MemUsage}} ({{.CPUPerc}} CPU)" 2>/dev/null | grep dra-perf
free -h | grep Mem | awk '{print "  Host: "$3" used / "$7" available"}'
