#!/bin/bash
# E2E Performance Test: 1 Rack (18 nodes)
# Components: Controller + Daemon dry-run + Fake Kubelet Plugin
# Each node: 1 channel + 1 daemon = 2 devices = 1 ResourceSlice
set -euo pipefail

CTX="--context kind-dra-perf"
NS="nvidia-dra-driver"
RACK="rack0001"

now_ms() { date +%s%3N; }

echo "============================================"
echo "  E2E Perf Test: 1 Rack / 18 Nodes"
echo "  1 channel/node, daemon dry-run + plugin"
echo "============================================"
echo ""

# Ensure clean state
kubectl $CTX -n $NS delete pods -l rack=e2e-$RACK --wait=false 2>/dev/null || true
kubectl $CTX -n $NS delete computedomain cd-e2e-$RACK --wait=false 2>/dev/null || true
sleep 5

echo "--- Phase 1: Create CD ---"
T_START=$(now_ms)
kubectl $CTX -n $NS apply -f - <<EOF
apiVersion: resource.nvidia.com/v1beta1
kind: ComputeDomain
metadata:
  name: cd-e2e-$RACK
  namespace: $NS
spec:
  numNodes: 0
  channel:
    allocationMode: Single
    resourceClaimTemplate:
      name: cd-e2e-$RACK-channels
EOF
sleep 2
CD_UUID=$(kubectl $CTX -n $NS get computedomain cd-e2e-$RACK -o jsonpath='{.metadata.uid}')
CD_STATUS=$(kubectl $CTX -n $NS get computedomain cd-e2e-$RACK -o jsonpath='{.status.status}')
T_CD=$(( $(now_ms) - T_START ))
echo "  CD created: ${T_CD}ms (status: ${CD_STATUS}, UUID: ${CD_UUID})"
echo ""

echo "--- Phase 2: Deploy 18 plugin pods (1 channel/node) ---"
T_START=$(now_ms)
for i in $(seq 1 18); do
  node_name=$(printf "fake-${RACK}-node%02d" $i)
  kubectl $CTX -n $NS create -f - >/dev/null 2>&1 <<EOF
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
EOF
done
T_SUBMIT_PLUGIN=$(( $(now_ms) - T_START ))
echo "  18 plugin pods submitted: ${T_SUBMIT_PLUGIN}ms"

# Wait for all Running
for attempt in $(seq 1 60); do
  running=$(kubectl $CTX -n $NS get pods -l role=plugin,rack=e2e-$RACK --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$running" -ge 18 ]; then break; fi
  echo -ne "  Waiting: ${running}/18 Running ($((attempt))s)\r"
  sleep 1
done
T_PLUGIN_READY=$(( $(now_ms) - T_START ))
echo "  18 plugin pods Running: ${T_PLUGIN_READY}ms                    "

# Check ResourceSlices
rs_count=$(kubectl $CTX get resourceslices --no-headers 2>/dev/null | grep -c "compute-domain.nvidia.com" || true)
echo "  ResourceSlices published: ${rs_count} (expected: 18)"
echo ""

echo "--- Phase 3: Deploy 18 daemon pods ---"
T_START=$(now_ms)
for i in $(seq 1 18); do
  node_name=$(printf "fake-${RACK}-node%02d" $i)
  pod_ip=$(printf "10.0.1.%d" $i)
  kubectl $CTX -n $NS create -f - >/dev/null <<EOF
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
    command:
      - compute-domain-daemon
      - --dry-run
      - --node-name=${node_name}
      - --compute-domain-name=cd-e2e-$RACK
      - --compute-domain-namespace=$NS
      - --compute-domain-uuid=${CD_UUID}
      - --cliqueid=${CD_UUID}
      - --max-nodes-per-imex-domain=18
      - --pod-name=daemon-${node_name}
      - --pod-namespace=$NS
      - --pod-ip=${pod_ip}
      - --pod-uid=fake-uid-${node_name}
      - -v=2
      - run
    resources:
      requests:
        memory: "16Mi"
        cpu: "5m"
      limits:
        memory: "64Mi"
EOF
done
T_SUBMIT_DAEMON=$(( $(now_ms) - T_START ))
echo "  18 daemon pods submitted: ${T_SUBMIT_DAEMON}ms"

# Wait for all Running
for attempt in $(seq 1 60); do
  running=$(kubectl $CTX -n $NS get pods -l role=daemon,rack=e2e-$RACK --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$running" -ge 18 ]; then break; fi
  echo -ne "  Waiting: ${running}/18 Running ($((attempt))s)\r"
  sleep 1
done
T_DAEMON_READY=$(( $(now_ms) - T_START ))
echo "  18 daemon pods Running: ${T_DAEMON_READY}ms                    "
echo ""

echo "--- Phase 4: Wait for all nodes to register in CD status ---"
T_START=$(now_ms)
for attempt in $(seq 1 120); do
  node_count=$(kubectl $CTX -n $NS get computedomain cd-e2e-$RACK -o jsonpath='{.status.nodes}' 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  if [ "$node_count" -ge 18 ]; then break; fi
  echo -ne "  Nodes registered: ${node_count}/18 ($((attempt))s)\r"
  sleep 1
done
T_ALL_REGISTERED=$(( $(now_ms) - T_START ))
echo "  All 18 nodes registered: ${T_ALL_REGISTERED}ms                    "

cd_status=$(kubectl $CTX -n $NS get computedomain cd-e2e-$RACK -o jsonpath='{.status.status}')
echo "  CD final status: ${cd_status}"
echo ""

echo "--- Phase 5: Teardown ---"
T_START=$(now_ms)

# Delete daemon pods first
kubectl $CTX -n $NS delete pods -l role=daemon,rack=e2e-$RACK --wait=false 2>/dev/null
# Delete plugin pods
kubectl $CTX -n $NS delete pods -l role=plugin,rack=e2e-$RACK --wait=false 2>/dev/null
# Delete CD
kubectl $CTX -n $NS delete computedomain cd-e2e-$RACK --wait=false 2>/dev/null

# Wait for all pods gone
for attempt in $(seq 1 120); do
  remaining=$(kubectl $CTX -n $NS get pods -l rack=e2e-$RACK --no-headers 2>/dev/null | wc -l || echo 0)
  if [ "$remaining" -eq 0 ]; then break; fi
  echo -ne "  Pods remaining: ${remaining} ($((attempt))s)\r"
  sleep 1
done
T_TEARDOWN=$(( $(now_ms) - T_START ))
echo "  Full teardown: ${T_TEARDOWN}ms                    "

# Check RS cleanup
sleep 3
rs_remaining=$(kubectl $CTX get resourceslices --no-headers 2>/dev/null | grep -c "compute-domain.nvidia.com" || true)
echo "  ResourceSlices remaining: ${rs_remaining}"
echo ""

echo "============================================"
echo "  RESULTS SUMMARY"
echo "============================================"
echo "  CD Create→Ready:          ${T_CD}ms"
echo "  Plugin pods submit:       ${T_SUBMIT_PLUGIN}ms"
echo "  Plugin pods all Running:  ${T_PLUGIN_READY}ms"
echo "  Daemon pods submit:       ${T_SUBMIT_DAEMON}ms"
echo "  Daemon pods all Running:  ${T_DAEMON_READY}ms"
echo "  All nodes registered:     ${T_ALL_REGISTERED}ms"
echo "  CD final status:          ${cd_status}"
echo "  Full teardown:            ${T_TEARDOWN}ms"
echo "============================================"
echo ""

echo "=== Resource usage ==="
docker stats --no-stream --format "  {{.Name}}: {{.MemUsage}} ({{.CPUPerc}} CPU)" 2>/dev/null | grep dra-perf
free -h | grep Mem | awk '{print "  Host: "$3" used / "$7" available"}'
