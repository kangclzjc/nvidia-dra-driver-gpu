#!/bin/bash
# E2E Performance Test v3: 1 Rack (18 nodes)
# Two modes:
#   --setup    Deploy plugins (infrastructure warmup, not timed)
#   --test     Run CD lifecycle benchmark (requires setup done first)
#   --cleanup  Tear everything down
#   (no args)  Run setup + test + cleanup in sequence
set -euo pipefail

CTX="--context kind-dra-perf"
NS="nvidia-dra-driver"
RACK="rack0001"
CD_NAME="cd-e2e-$RACK"

now_ms() { date +%s%3N; }

do_setup() {
  echo "============================================"
  echo "  SETUP: Deploy plugins (not timed)"
  echo "============================================"
  echo ""

  # Clean old plugins
  kubectl $CTX -n $NS delete pods -l role=plugin,rack=e2e-$RACK --wait=false 2>/dev/null || true
  sleep 3

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
      - --cd-name=$CD_NAME
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
PLUGINEOF
    echo -ne "\r  Plugin: $i/18"
  done
  echo ""

  # Wait for all running
  for attempt in $(seq 1 90); do
    running=$(kubectl $CTX -n $NS get pods -l role=plugin,rack=e2e-$RACK --no-headers 2>/dev/null | grep -c Running || true)
    if [ "$running" -ge 18 ]; then break; fi
    echo -ne "  Waiting: ${running}/18 Running (${attempt}s)\r"
    sleep 1
  done

  rs_count=$(kubectl $CTX get resourceslices --no-headers 2>/dev/null | grep -c "compute-domain.nvidia.com" || true)
  echo "  ✅ 18 plugins Running, ${rs_count} ResourceSlices published"
  echo ""
}

do_test() {
  local ITERATIONS=${1:-3}

  echo "============================================"
  echo "  BENCHMARK: CD Lifecycle ($ITERATIONS iterations)"
  echo "  Pre-condition: plugins already running"
  echo "============================================"
  echo ""

  # Verify plugins are up
  running=$(kubectl $CTX -n $NS get pods -l role=plugin,rack=e2e-$RACK --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$running" -lt 18 ]; then
    echo "  ❌ Only ${running}/18 plugins running. Run --setup first."
    exit 1
  fi

  declare -a T_CREATE T_DAEMON_SUBMIT T_DAEMON_RUN T_READY T_TEARDOWN T_TOTAL

  for iter in $(seq 1 $ITERATIONS); do
    echo "--- Iteration $iter/$ITERATIONS ---"

    # Clean any leftover
    kubectl $CTX -n $NS delete pods -l role=daemon,rack=e2e-$RACK --wait=false 2>/dev/null || true
    kubectl $CTX -n $NS delete computedomain $CD_NAME --wait=false 2>/dev/null || true
    sleep 3

    # === Create CD ===
    T0=$(now_ms)
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
    CD_UUID=$(kubectl $CTX -n $NS get computedomain $CD_NAME -o jsonpath='{.metadata.uid}')
    T1=$(now_ms)
    T_CREATE[$iter]=$(( T1 - T0 ))
    echo "  CD created: ${T_CREATE[$iter]}ms (UUID: $CD_UUID)"

    # Delete auto-DaemonSet
    sleep 1
    kubectl $CTX -n $NS delete daemonset "computedomain-daemon-${CD_UUID}" --wait=false 2>/dev/null || true

    # === Deploy daemon pods ===
    T2=$(now_ms)
    # Delete DS again in case controller recreated it
    kubectl $CTX -n $NS delete daemonset "computedomain-daemon-${CD_UUID}" --wait=false 2>/dev/null || true

    for i in $(seq 1 18); do
      node_name=$(printf "fake-${RACK}-node%02d" $i)
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
      - --compute-domain-name=$CD_NAME
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
    T3=$(now_ms)
    T_DAEMON_SUBMIT[$iter]=$(( T3 - T2 ))

    # Wait for daemons Running
    for attempt in $(seq 1 90); do
      r=$(kubectl $CTX -n $NS get pods -l role=daemon,rack=e2e-$RACK --no-headers 2>/dev/null | grep -c Running || true)
      if [ "$r" -ge 18 ]; then break; fi
      sleep 1
    done
    T4=$(now_ms)
    T_DAEMON_RUN[$iter]=$(( T4 - T2 ))

    # === Wait for CD Ready ===
    for attempt in $(seq 1 120); do
      nc=$(kubectl $CTX -n $NS get computedomain $CD_NAME -o jsonpath='{.status.nodes}' 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
      cs=$(kubectl $CTX -n $NS get computedomain $CD_NAME -o jsonpath='{.status.status}' 2>/dev/null || echo "?")
      if [ "$nc" -ge 18 ] && [ "$cs" = "Ready" ]; then break; fi
      sleep 1
    done
    T5=$(now_ms)
    T_READY[$iter]=$(( T5 - T0 ))

    final=$(kubectl $CTX -n $NS get computedomain $CD_NAME -o jsonpath='{.status.status}' 2>/dev/null)
    echo "  Daemon submit: ${T_DAEMON_SUBMIT[$iter]}ms | Running: ${T_DAEMON_RUN[$iter]}ms | E2E Ready: ${T_READY[$iter]}ms (${final})"

    # === Teardown ===
    T6=$(now_ms)
    kubectl $CTX -n $NS delete pods -l role=daemon,rack=e2e-$RACK --wait=false 2>/dev/null
    kubectl $CTX -n $NS delete computedomain $CD_NAME --wait=false 2>/dev/null
    for attempt in $(seq 1 60); do
      rem=$(kubectl $CTX -n $NS get pods -l role=daemon,rack=e2e-$RACK --no-headers 2>/dev/null | grep -c . || true)
      cd_exists=$(kubectl $CTX -n $NS get computedomain $CD_NAME --no-headers 2>/dev/null | grep -c . || true)
      if [ "${rem:-0}" -eq 0 ] && [ "${cd_exists:-0}" -eq 0 ]; then break; fi
      sleep 1
    done
    T7=$(now_ms)
    T_TEARDOWN[$iter]=$(( T7 - T6 ))
    T_TOTAL[$iter]=$(( T7 - T0 ))
    echo "  Teardown: ${T_TEARDOWN[$iter]}ms | Total cycle: ${T_TOTAL[$iter]}ms"
    echo ""
  done

  # Summary
  echo "============================================"
  echo "  RESULTS ($ITERATIONS iterations)"
  echo "============================================"
  printf "  %-6s %-10s %-12s %-12s %-12s %-10s\n" "Iter" "CD_Create" "Daemon_Run" "E2E_Ready" "Teardown" "Total"
  for iter in $(seq 1 $ITERATIONS); do
    printf "  %-6s %-10s %-12s %-12s %-12s %-10s\n" \
      "$iter" "${T_CREATE[$iter]}ms" "${T_DAEMON_RUN[$iter]}ms" "${T_READY[$iter]}ms" "${T_TEARDOWN[$iter]}ms" "${T_TOTAL[$iter]}ms"
  done
  echo ""

  # Averages
  sum_create=0; sum_daemon=0; sum_ready=0; sum_teardown=0; sum_total=0
  for iter in $(seq 1 $ITERATIONS); do
    sum_create=$((sum_create + T_CREATE[$iter]))
    sum_daemon=$((sum_daemon + T_DAEMON_RUN[$iter]))
    sum_ready=$((sum_ready + T_READY[$iter]))
    sum_teardown=$((sum_teardown + T_TEARDOWN[$iter]))
    sum_total=$((sum_total + T_TOTAL[$iter]))
  done
  printf "  %-6s %-10s %-12s %-12s %-12s %-10s\n" \
    "AVG" "$((sum_create/ITERATIONS))ms" "$((sum_daemon/ITERATIONS))ms" "$((sum_ready/ITERATIONS))ms" "$((sum_teardown/ITERATIONS))ms" "$((sum_total/ITERATIONS))ms"
  echo "============================================"
  echo ""
  docker stats --no-stream --format "  {{.Name}}: {{.MemUsage}} ({{.CPUPerc}} CPU)" 2>/dev/null | grep dra-perf
  free -h | grep Mem | awk '{print "  Host: "$3" used / "$7" available"}'
}

do_cleanup() {
  echo "=== Cleanup ==="
  kubectl $CTX -n $NS delete pods -l rack=e2e-$RACK --wait=false 2>/dev/null || true
  kubectl $CTX -n $NS delete computedomain $CD_NAME --wait=false 2>/dev/null || true
  echo "Done"
}

case "${1:-all}" in
  --setup)   do_setup ;;
  --test)    do_test "${2:-3}" ;;
  --cleanup) do_cleanup ;;
  all)       do_setup; do_test 3; do_cleanup ;;
  *)         echo "Usage: $0 [--setup|--test [N]|--cleanup|all]"; exit 1 ;;
esac
