# ComputeDomain 性能测试方案

## 目录

- [1. 概述](#1-概述)
- [2. 测试环境要求](#2-测试环境要求)
- [3. 公共基础设施](#3-公共基础设施)
- [4. 测试场景](#4-测试场景)
- [5. kube-burner 配置](#5-kube-burner-配置)
- [6. Prometheus 监控配置](#6-prometheus-监控配置)
- [7. CI Workflow](#7-ci-workflow)
- [8. 基线目标汇总](#8-基线目标汇总)

---

## 1. 概述

本方案针对 NVIDIA DRA Driver 的 ComputeDomain (CD) 子系统进行全面性能测试，覆盖从创建到就绪、故障恢复、大规模调度、级联删除等 12 个关键路径。

**架构关键路径：**

```
CD Created → Controller 5-step Reconcile → DaemonSet → IMEX Daemon Pods
    → Clique Creation → Channel Injection → nodes.cfg Propagation → Ready
```

**关键时间常量：**

| 参数 | 值 | 影响 |
|------|-----|------|
| cdStatusSyncInterval | 2s | 状态同步最小周期 |
| informerResyncPeriod | 10min | 全量 reconcile 周期 |
| mutationCacheTTL | 1h | 缓存失效上限 |
| IMEX watchdog | 1s | 进程健康检查周期 |
| Kubelet retry timeout | 45s | prepare/unprepare 超时 |
| flock 串行化 | N/A | 同节点操作串行 |

---

## 2. 测试环境要求

```yaml
# test-environment.yaml
cluster:
  nodes: 20           # 最少；场景7需要100+模拟
  gpu_per_node: 8     # NVIDIA GPU
  k8s_version: ">=1.31"
  features:
    - DynamicResourceAllocation
    - ComputeDomain

software:
  - nvidia-dra-driver: "latest"
  - prometheus: ">=2.45"
  - kube-burner: ">=1.7"
  - jq: ">=1.6"
  - kubectl: ">=1.31"
  - bc: "any"

namespaces:
  - cd-perf-test        # 主测试命名空间
  - cd-perf-monitoring  # 监控命名空间
```

---

## 3. 公共基础设施

### 3.1 common.sh

```bash
#!/usr/bin/env bash
# common.sh — ComputeDomain 性能测试公共函数库
set -euo pipefail

#=============================================================================
# 配置
#=============================================================================
export NAMESPACE="${CD_PERF_NAMESPACE:-cd-perf-test}"
export RESULTS_DIR="${CD_PERF_RESULTS:-./results/$(date +%Y%m%d-%H%M%S)}"
export TIMEOUT_DEFAULT=300
export POLL_INTERVAL=0.5
export CD_API_GROUP="gpu.resource.nvidia.com"
export CD_API_VERSION="v1alpha1"
export CD_RESOURCE="computedomains"

#=============================================================================
# 初始化
#=============================================================================
init_test() {
    local test_name="$1"
    export TEST_NAME="$test_name"
    export TEST_DIR="${RESULTS_DIR}/${test_name}"
    mkdir -p "$TEST_DIR"
    echo "================================================================"
    echo "[$(date -Iseconds)] START: ${test_name}"
    echo "================================================================"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

cleanup_test() {
    echo "[$(date -Iseconds)] CLEANUP: ${TEST_NAME}"
    kubectl delete "${CD_RESOURCE}.${CD_API_GROUP}" --all -n "$NAMESPACE" --wait=false 2>/dev/null || true
    kubectl delete resourceclaims --all -n "$NAMESPACE" --wait=false 2>/dev/null || true
    # 等待所有CD完全删除
    wait_for_condition "no remaining CDs" 120 \
        "[ \$(kubectl get ${CD_RESOURCE}.${CD_API_GROUP} -n ${NAMESPACE} --no-headers 2>/dev/null | wc -l) -eq 0 ]"
    echo "[$(date -Iseconds)] CLEANUP DONE"
}

#=============================================================================
# 计时工具
#=============================================================================
now_ms() {
    date +%s%3N
}

elapsed_ms() {
    local start_ms="$1"
    local end_ms
    end_ms=$(now_ms)
    echo $(( end_ms - start_ms ))
}

elapsed_s() {
    local ms
    ms=$(elapsed_ms "$1")
    echo "scale=3; $ms / 1000" | bc
}

#=============================================================================
# 等待条件
#=============================================================================
wait_for_condition() {
    local description="$1"
    local timeout_s="${2:-$TIMEOUT_DEFAULT}"
    local condition_cmd="$3"
    local poll="${4:-$POLL_INTERVAL}"

    local start
    start=$(now_ms)
    local deadline=$(( $(date +%s) + timeout_s ))

    while ! eval "$condition_cmd" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "TIMEOUT waiting for: ${description} (${timeout_s}s)"
            return 1
        fi
        sleep "$poll"
    done

    local elapsed
    elapsed=$(elapsed_ms "$start")
    echo "$elapsed"
}

#=============================================================================
# CD 状态等待
#=============================================================================
wait_cd_ready() {
    local cd_name="$1"
    local timeout_s="${2:-$TIMEOUT_DEFAULT}"

    wait_for_condition "CD/${cd_name} Ready" "$timeout_s" \
        "[ \"\$(kubectl get ${CD_RESOURCE}.${CD_API_GROUP} ${cd_name} -n ${NAMESPACE} \
            -o jsonpath='{.status.status}' 2>/dev/null)\" = 'Ready' ]"
}

wait_cd_deleted() {
    local cd_name="$1"
    local timeout_s="${2:-$TIMEOUT_DEFAULT}"

    wait_for_condition "CD/${cd_name} deleted" "$timeout_s" \
        "! kubectl get ${CD_RESOURCE}.${CD_API_GROUP} ${cd_name} -n ${NAMESPACE} &>/dev/null"
}

wait_daemon_pods_ready() {
    local cd_name="$1"
    local expected_count="$2"
    local timeout_s="${3:-$TIMEOUT_DEFAULT}"

    wait_for_condition "CD/${cd_name} ${expected_count} daemon pods ready" "$timeout_s" \
        "[ \$(kubectl get pods -n ${NAMESPACE} \
            -l nvidia.com/compute-domain.name=${cd_name} \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l) -ge ${expected_count} ]"
}

#=============================================================================
# CD YAML 生成
#=============================================================================
generate_cd_yaml() {
    local name="$1"
    local node_count="${2:-2}"
    local alloc_mode="${3:-Single}"
    local channel_devices="${4:-2048}"

    cat <<EOF
apiVersion: ${CD_API_GROUP}/${CD_API_VERSION}
kind: ComputeDomain
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
spec:
  channel:
    allocationMode: ${alloc_mode}
    resourceClaimTemplate:
      spec:
        devices:
          requests:
          - name: channel
            exactly:
              count: ${channel_devices}
          config:
          - opaque:
              driver: gpu.resource.nvidia.com
              parameters:
                apiVersion: ${CD_API_GROUP}/${CD_API_VERSION}
                kind: ImexChannelConfiguration
  daemon:
    resourceClaimTemplate:
      spec:
        devices:
          requests:
          - name: imex-daemon
            exactly:
              count: 1
          config:
          - opaque:
              driver: gpu.resource.nvidia.com
              parameters:
                apiVersion: ${CD_API_GROUP}/${CD_API_VERSION}
                kind: ImexDaemonConfiguration
  nodeSelector:
    matchLabels:
      nvidia.com/gpu.present: "true"
EOF
}

#=============================================================================
# 结果记录
#=============================================================================
record_result() {
    local metric_name="$1"
    local value="$2"
    local unit="${3:-ms}"
    local extra="${4:-}"

    local line
    line="$(date -Iseconds),${TEST_NAME},${metric_name},${value},${unit},${extra}"
    echo "$line" | tee -a "${TEST_DIR}/results.csv" >> "${RESULTS_DIR}/all_results.csv"
}

record_summary() {
    local metric_name="$1"
    shift
    local values=("$@")

    local count=${#values[@]}
    if [ "$count" -eq 0 ]; then
        echo "WARN: no values for ${metric_name}"
        return
    fi

    # 计算 min/max/avg/p50/p95/p99
    local sorted
    sorted=$(printf '%s\n' "${values[@]}" | sort -n)

    local min max sum avg
    min=$(echo "$sorted" | head -1)
    max=$(echo "$sorted" | tail -1)
    sum=0
    for v in "${values[@]}"; do sum=$(( sum + v )); done
    avg=$(( sum / count ))

    local p50_idx=$(( count * 50 / 100 ))
    local p95_idx=$(( count * 95 / 100 ))
    local p99_idx=$(( count * 99 / 100 ))
    [ "$p50_idx" -ge "$count" ] && p50_idx=$(( count - 1 ))
    [ "$p95_idx" -ge "$count" ] && p95_idx=$(( count - 1 ))
    [ "$p99_idx" -ge "$count" ] && p99_idx=$(( count - 1 ))

    local p50 p95 p99
    p50=$(echo "$sorted" | sed -n "$(( p50_idx + 1 ))p")
    p95=$(echo "$sorted" | sed -n "$(( p95_idx + 1 ))p")
    p99=$(echo "$sorted" | sed -n "$(( p99_idx + 1 ))p")

    echo "--- ${metric_name} Summary (n=${count}) ---"
    echo "  min=${min}ms  max=${max}ms  avg=${avg}ms"
    echo "  p50=${p50}ms  p95=${p95}ms  p99=${p99}ms"

    cat >> "${TEST_DIR}/summary.json" <<EOF
{"metric":"${metric_name}","count":${count},"min":${min},"max":${max},"avg":${avg},"p50":${p50},"p95":${p95},"p99":${p99}}
EOF
}

#=============================================================================
# 断言
#=============================================================================
assert_le() {
    local actual="$1"
    local expected="$2"
    local msg="$3"

    if [ "$actual" -le "$expected" ]; then
        echo "PASS: ${msg} (${actual} <= ${expected})"
        return 0
    else
        echo "FAIL: ${msg} (${actual} > ${expected})"
        return 1
    fi
}

echo "[common.sh] Loaded. NAMESPACE=${NAMESPACE} RESULTS_DIR=${RESULTS_DIR}"
```

### 3.2 CD YAML 模板

```yaml
# templates/compute-domain-basic.yaml
apiVersion: gpu.resource.nvidia.com/v1alpha1
kind: ComputeDomain
metadata:
  name: ${CD_NAME}
  namespace: ${NAMESPACE}
spec:
  channel:
    allocationMode: ${ALLOC_MODE:-Single}
    resourceClaimTemplate:
      spec:
        devices:
          requests:
          - name: channel
            exactly:
              count: ${CHANNEL_DEVICES:-2048}
          config:
          - opaque:
              driver: gpu.resource.nvidia.com
              parameters:
                apiVersion: gpu.resource.nvidia.com/v1alpha1
                kind: ImexChannelConfiguration
  daemon:
    resourceClaimTemplate:
      spec:
        devices:
          requests:
          - name: imex-daemon
            exactly:
              count: 1
          config:
          - opaque:
              driver: gpu.resource.nvidia.com
              parameters:
                apiVersion: gpu.resource.nvidia.com/v1alpha1
                kind: ImexDaemonConfiguration
  nodeSelector:
    matchLabels:
      nvidia.com/gpu.present: "true"
```

---

## 4. 测试场景

### 场景 1: CD Creation-to-Ready 延迟

**目标：** 测量单个及批量 ComputeDomain 从创建到 status=Ready 的端到端延迟。

**关键路径：** `kubectl apply` → Controller watch → 5-step reconcile → DaemonSet create → Daemon pods Running → Clique ready → Channel injected → status sync (2s) → Ready

**基线目标：**
| 指标 | 目标 |
|------|------|
| 单CD Ready (2节点) | p95 < 30s |
| 单CD Ready (10节点) | p95 < 60s |
| 批量10 CD Ready | 全部 p95 < 90s |
| 批量10 CD Ready | 最后一个 < 120s |

```bash
#!/usr/bin/env bash
# test_01_creation_to_ready.sh — CD Creation-to-Ready 延迟测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "01_creation_to_ready"

NODE_COUNT=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers | wc -l)
echo "GPU nodes available: ${NODE_COUNT}"

#=============================================================================
# 子测试 1a: 单CD创建延迟 (多次迭代取统计值)
#=============================================================================
echo ""
echo "=== 1a: Single CD Creation Latency ==="
ITERATIONS=10
single_latencies=()

for i in $(seq 1 "$ITERATIONS"); do
    cd_name="cd-single-${i}"
    echo -n "  Iteration ${i}/${ITERATIONS}: "

    generate_cd_yaml "$cd_name" 2 "Single" | kubectl apply -f - > /dev/null

    start=$(now_ms)
    latency=$(wait_cd_ready "$cd_name" 120)

    if [ $? -eq 0 ]; then
        single_latencies+=("$latency")
        record_result "single_cd_ready_latency" "$latency" "ms" "nodes=2,iter=${i}"
        echo "${latency}ms"
    else
        echo "TIMEOUT"
        record_result "single_cd_ready_latency" "TIMEOUT" "ms" "nodes=2,iter=${i}"
    fi

    # 清理单个CD
    kubectl delete "${CD_RESOURCE}.${CD_API_GROUP}" "$cd_name" -n "$NAMESPACE" --wait=false > /dev/null
    sleep 5
done

if [ ${#single_latencies[@]} -gt 0 ]; then
    record_summary "single_cd_ready" "${single_latencies[@]}"
fi

#=============================================================================
# 子测试 1b: 批量CD创建延迟
#=============================================================================
echo ""
echo "=== 1b: Batch CD Creation Latency ==="
BATCH_SIZE=10
batch_latencies=()
batch_start=$(now_ms)

# 同时创建所有CD
for i in $(seq 1 "$BATCH_SIZE"); do
    cd_name="cd-batch-${i}"
    generate_cd_yaml "$cd_name" 2 "Single" | kubectl apply -f - > /dev/null &
done
wait

echo "  All ${BATCH_SIZE} CDs submitted at $(date -Iseconds)"

# 逐个等待就绪并记录
for i in $(seq 1 "$BATCH_SIZE"); do
    cd_name="cd-batch-${i}"
    latency=$(wait_cd_ready "$cd_name" 180)
    if [ $? -eq 0 ]; then
        batch_latencies+=("$latency")
        record_result "batch_cd_ready_latency" "$latency" "ms" "batch=${BATCH_SIZE},idx=${i}"
        echo "  CD ${cd_name}: ${latency}ms"
    else
        echo "  CD ${cd_name}: TIMEOUT"
    fi
done

total_batch_time=$(elapsed_ms "$batch_start")
record_result "batch_total_time" "$total_batch_time" "ms" "batch=${BATCH_SIZE}"
echo "  Total batch time: ${total_batch_time}ms"

if [ ${#batch_latencies[@]} -gt 0 ]; then
    record_summary "batch_cd_ready" "${batch_latencies[@]}"
fi

#=============================================================================
# 子测试 1c: 不同节点规模下的创建延迟
#=============================================================================
echo ""
echo "=== 1c: CD Ready Latency by Node Scale ==="
# 通过 nodeSelector 控制节点数 (需要预先标记节点)
for target_nodes in 2 5 10; do
    if [ "$target_nodes" -gt "$NODE_COUNT" ]; then
        echo "  Skipping ${target_nodes}-node test (only ${NODE_COUNT} nodes available)"
        continue
    fi

    cd_name="cd-scale-n${target_nodes}"
    echo -n "  ${target_nodes} nodes: "

    generate_cd_yaml "$cd_name" "$target_nodes" "Single" | kubectl apply -f - > /dev/null

    start=$(now_ms)
    latency=$(wait_cd_ready "$cd_name" 180)

    if [ $? -eq 0 ]; then
        record_result "scale_cd_ready_latency" "$latency" "ms" "nodes=${target_nodes}"
        echo "${latency}ms"
    else
        echo "TIMEOUT"
    fi

    kubectl delete "${CD_RESOURCE}.${CD_API_GROUP}" "$cd_name" -n "$NAMESPACE" --wait=false > /dev/null
    sleep 10
done

#=============================================================================
# 验证
#=============================================================================
echo ""
echo "=== Assertions ==="
if [ ${#single_latencies[@]} -gt 0 ]; then
    p95_single=$(printf '%s\n' "${single_latencies[@]}" | sort -n | sed -n "$(( ${#single_latencies[@]} * 95 / 100 + 1 ))p")
    assert_le "${p95_single:-0}" 30000 "Single CD p95 < 30s" || true
fi

cleanup_test
echo "[$(date -Iseconds)] TEST 01 COMPLETE. Results: ${TEST_DIR}/"
```

---

### 场景 2: 并发创建吞吐量

**目标：** 测量系统在高并发下的 CD 创建吞吐量和成功率。

**基线目标：**
| 指标 | 目标 |
|------|------|
| 50 CD/min 吞吐量 | 成功率 > 95% |
| 100 CD 全部 Ready | < 10min |
| Controller CPU 峰值 | < 2 cores |
| Controller 内存峰值 | < 1Gi |

```bash
#!/usr/bin/env bash
# test_02_concurrent_throughput.sh — 并发创建吞吐量测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "02_concurrent_throughput"

#=============================================================================
# 参数
#=============================================================================
CONCURRENCY_LEVELS=(10 25 50)
MAX_CONCURRENT="${CD_PERF_MAX_CONCURRENT:-50}"

for CONCURRENT in "${CONCURRENCY_LEVELS[@]}"; do
    if [ "$CONCURRENT" -gt "$MAX_CONCURRENT" ]; then
        echo "Skipping concurrency=${CONCURRENT} (max=${MAX_CONCURRENT})"
        continue
    fi

    echo ""
    echo "=== Concurrency Level: ${CONCURRENT} ==="

    # 记录 controller 资源起始状态
    ctrl_pod=$(kubectl get pods -n nvidia-system -l app=nvidia-dra-controller \
        --no-headers -o name 2>/dev/null | head -1)
    if [ -n "$ctrl_pod" ]; then
        echo "  Controller pod: ${ctrl_pod}"
    fi

    # 发射所有CD
    start_time=$(now_ms)
    pids=()
    for i in $(seq 1 "$CONCURRENT"); do
        cd_name="cd-conc-${CONCURRENT}-${i}"
        (
            generate_cd_yaml "$cd_name" 2 "Single" | kubectl apply -f - > /dev/null 2>&1
        ) &
        pids+=($!)
    done

    # 等待所有 apply 完成
    apply_failures=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            apply_failures=$(( apply_failures + 1 ))
        fi
    done
    apply_time=$(elapsed_ms "$start_time")
    echo "  Apply phase: ${apply_time}ms (failures: ${apply_failures})"
    record_result "concurrent_apply_time" "$apply_time" "ms" "n=${CONCURRENT}"
    record_result "concurrent_apply_failures" "$apply_failures" "count" "n=${CONCURRENT}"

    # 等待所有 CD Ready (并行轮询)
    ready_count=0
    ready_latencies=()
    timeout_count=0

    for i in $(seq 1 "$CONCURRENT"); do
        cd_name="cd-conc-${CONCURRENT}-${i}"
        latency=$(wait_cd_ready "$cd_name" 300) && {
            ready_count=$(( ready_count + 1 ))
            ready_latencies+=("$latency")
        } || {
            timeout_count=$(( timeout_count + 1 ))
        }
    done

    total_time=$(elapsed_ms "$start_time")

    success_rate=0
    if [ "$CONCURRENT" -gt 0 ]; then
        success_rate=$(( ready_count * 100 / CONCURRENT ))
    fi

    echo "  Results: ready=${ready_count}/${CONCURRENT} timeout=${timeout_count} total=${total_time}ms"
    echo "  Success rate: ${success_rate}%"
    echo "  Throughput: $(echo "scale=2; ${ready_count} * 60000 / ${total_time}" | bc) CD/min"

    record_result "concurrent_total_time" "$total_time" "ms" "n=${CONCURRENT}"
    record_result "concurrent_success_rate" "$success_rate" "%" "n=${CONCURRENT}"
    record_result "concurrent_ready_count" "$ready_count" "count" "n=${CONCURRENT}"

    if [ ${#ready_latencies[@]} -gt 0 ]; then
        record_summary "concurrent_ready_latency_n${CONCURRENT}" "${ready_latencies[@]}"
    fi

    # 记录 controller 资源使用峰值
    if [ -n "$ctrl_pod" ]; then
        ctrl_metrics=$(kubectl top "$ctrl_pod" -n nvidia-system --no-headers 2>/dev/null || echo "N/A N/A N/A")
        echo "  Controller resources: ${ctrl_metrics}"
        record_result "controller_resources" "$(echo $ctrl_metrics | awk '{print $2}')" "cpu" "n=${CONCURRENT}"
    fi

    # 清理本轮
    for i in $(seq 1 "$CONCURRENT"); do
        kubectl delete "${CD_RESOURCE}.${CD_API_GROUP}" "cd-conc-${CONCURRENT}-${i}" \
            -n "$NAMESPACE" --wait=false 2>/dev/null &
    done
    wait
    sleep 30  # 等待完全清理

    # 断言
    assert_le "$(( 100 - success_rate ))" 5 "Failure rate <= 5% at concurrency=${CONCURRENT}" || true
done

cleanup_test
echo "[$(date -Iseconds)] TEST 02 COMPLETE."
```

---

### 场景 3: IMEX Daemon 启动延迟

**目标：** 测量 IMEX Daemon Pod 从 Pending 到 Running 并完成初始化的延迟，含 ProcessManager watchdog 就绪。

**基线目标：**
| 指标 | 目标 |
|------|------|
| Daemon pod scheduling | p95 < 5s |
| Daemon container ready | p95 < 15s |
| IMEX process healthy (watchdog) | p95 < 20s |
| 全节点 daemon 就绪 (10 nodes) | < 45s |

```bash
#!/usr/bin/env bash
# test_03_imex_daemon_startup.sh — IMEX Daemon 启动延迟测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "03_imex_daemon_startup"

NODE_COUNT=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers | wc -l)
echo "GPU nodes: ${NODE_COUNT}"

ITERATIONS=5
schedule_latencies=()
ready_latencies=()
all_daemons_latencies=()

for iter in $(seq 1 "$ITERATIONS"); do
    echo ""
    echo "=== Iteration ${iter}/${ITERATIONS} ==="

    cd_name="cd-daemon-test-${iter}"
    generate_cd_yaml "$cd_name" "$NODE_COUNT" "Single" | kubectl apply -f - > /dev/null

    creation_time=$(now_ms)

    #-------------------------------------------------------------------------
    # 阶段 1: 等待第一个 daemon pod 被调度
    #-------------------------------------------------------------------------
    schedule_ms=$(wait_for_condition "first daemon pod scheduled" 60 \
        "kubectl get pods -n ${NAMESPACE} -l nvidia.com/compute-domain.name=${cd_name} \
            --no-headers 2>/dev/null | grep -qvE 'Pending|ContainerCreating'")

    if [ $? -eq 0 ]; then
        schedule_latencies+=("$schedule_ms")
        record_result "daemon_first_scheduled" "$schedule_ms" "ms" "iter=${iter}"
        echo "  First daemon scheduled: ${schedule_ms}ms"
    fi

    #-------------------------------------------------------------------------
    # 阶段 2: 等待所有 daemon pods Ready
    #-------------------------------------------------------------------------
    all_ready_ms=$(wait_daemon_pods_ready "$cd_name" "$NODE_COUNT" 120)

    if [ $? -eq 0 ]; then
        all_daemons_latencies+=("$all_ready_ms")
        record_result "all_daemons_ready" "$all_ready_ms" "ms" "iter=${iter},nodes=${NODE_COUNT}"
        echo "  All ${NODE_COUNT} daemons ready: ${all_ready_ms}ms"
    else
        echo "  All daemons ready: TIMEOUT"
    fi

    #-------------------------------------------------------------------------
    # 阶段 3: 检查各 daemon pod 的调度和启动时间
    #-------------------------------------------------------------------------
    daemon_pods=$(kubectl get pods -n "$NAMESPACE" \
        -l "nvidia.com/compute-domain.name=${cd_name}" \
        -o jsonpath='{.items[*].metadata.name}')

    for pod in $daemon_pods; do
        # 获取 pod 创建时间和容器启动时间
        created=$(kubectl get pod "$pod" -n "$NAMESPACE" \
            -o jsonpath='{.metadata.creationTimestamp}')
        started=$(kubectl get pod "$pod" -n "$NAMESPACE" \
            -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null || echo "")

        if [ -n "$created" ] && [ -n "$started" ]; then
            created_epoch=$(date -d "$created" +%s%3N 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$created" +%s000)
            started_epoch=$(date -d "$started" +%s%3N 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$started" +%s000)
            pod_startup=$(( started_epoch - created_epoch ))
            ready_latencies+=("$pod_startup")
            record_result "daemon_pod_startup" "$pod_startup" "ms" "pod=${pod}"
        fi

        # 检查 IMEX watchdog — 检查daemon容器日志中是否出现 "healthy" 标记
        if kubectl logs "$pod" -n "$NAMESPACE" --tail=50 2>/dev/null | grep -qi "imex.*ready\|healthy\|watchdog.*ok"; then
            echo "    ${pod}: IMEX watchdog confirmed healthy"
        fi
    done

    # 清理
    kubectl delete "${CD_RESOURCE}.${CD_API_GROUP}" "$cd_name" -n "$NAMESPACE" --wait=false > /dev/null
    sleep 15
done

#=============================================================================
# 汇总
#=============================================================================
echo ""
echo "=== Summary ==="
[ ${#schedule_latencies[@]} -gt 0 ] && record_summary "daemon_first_scheduled" "${schedule_latencies[@]}"
[ ${#ready_latencies[@]} -gt 0 ] && record_summary "daemon_pod_startup" "${ready_latencies[@]}"
[ ${#all_daemons_latencies[@]} -gt 0 ] && record_summary "all_daemons_ready" "${all_daemons_latencies[@]}"

# 断言
if [ ${#ready_latencies[@]} -gt 0 ]; then
    p95=$(printf '%s\n' "${ready_latencies[@]}" | sort -n | sed -n "$(( ${#ready_latencies[@]} * 95 / 100 + 1 ))p")
    assert_le "${p95:-0}" 15000 "Daemon pod startup p95 < 15s" || true
fi

cleanup_test
echo "[$(date -Iseconds)] TEST 03 COMPLETE."
```

---

### 场景 4: Channel 注入延迟

**目标：** 测量从 CD Ready 到 Channel ResourceClaim 被注入到工作负载 Pod 的延迟，含 Kubelet plugin 的 flock 串行化 prepare 阶段。

**基线目标：**
| 指标 | 目标 |
|------|------|
| Channel claim creation | p95 < 5s |
| Channel prepare (kubelet flock) | p95 < 10s |
| 端到端 channel 可用 | p95 < 20s |
| 串行 prepare 同节点 2 channel | < 25s |

```bash
#!/usr/bin/env bash
# test_04_channel_injection.sh — Channel 注入延迟测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "04_channel_injection"

#=============================================================================
# 先创建一个 CD 并等待 Ready
#=============================================================================
CD_NAME="cd-channel-test"
generate_cd_yaml "$CD_NAME" 2 "Single" | kubectl apply -f - > /dev/null

echo "Waiting for CD to become Ready..."
wait_cd_ready "$CD_NAME" 120
echo "CD is Ready."

#=============================================================================
# 子测试 4a: 单 channel 注入延迟
#=============================================================================
echo ""
echo "=== 4a: Single Channel Injection ==="

generate_channel_workload() {
    local name="$1"
    local cd_name="$2"
    cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  labels:
    nvidia.com/compute-domain.name: ${cd_name}
spec:
  containers:
  - name: worker
    image: nvidia/cuda:12.4.0-base-ubuntu22.04
    command: ["sleep", "infinity"]
    resources:
      claims:
      - name: channel
  resourceClaims:
  - name: channel
    resourceClaimTemplateName: ${cd_name}-channel
  restartPolicy: Never
  nodeSelector:
    nvidia.com/gpu.present: "true"
EOF
}

ITERATIONS=5
inject_latencies=()

for i in $(seq 1 "$ITERATIONS"); do
    pod_name="channel-test-${i}"
    echo -n "  Iteration ${i}: "

    start=$(now_ms)
    generate_channel_workload "$pod_name" "$CD_NAME" | kubectl apply -f - > /dev/null

    # 等待 pod Running（表示 channel 已 prepare 成功）
    latency=$(wait_for_condition "pod/${pod_name} Running" 90 \
        "[ \"\$(kubectl get pod ${pod_name} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null)\" = 'Running' ]")

    if [ $? -eq 0 ]; then
        inject_latencies+=("$latency")
        record_result "channel_inject_latency" "$latency" "ms" "iter=${i}"
        echo "${latency}ms"
    else
        echo "TIMEOUT"
        # 诊断
        kubectl describe pod "$pod_name" -n "$NAMESPACE" 2>/dev/null | tail -20
    fi

    kubectl delete pod "$pod_name" -n "$NAMESPACE" --wait=false > /dev/null 2>&1
    sleep 5
done

[ ${#inject_latencies[@]} -gt 0 ] && record_summary "single_channel_inject" "${inject_latencies[@]}"

#=============================================================================
# 子测试 4b: 同节点串行 prepare (flock 竞争)
#=============================================================================
echo ""
echo "=== 4b: Same-Node Serial Prepare (flock contention) ==="

# 获取一个 GPU 节点
target_node=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers \
    -o jsonpath='{.items[0].metadata.name}')
echo "  Target node: ${target_node}"

PARALLEL_PODS=3
serial_start=$(now_ms)
serial_pids=()

for i in $(seq 1 "$PARALLEL_PODS"); do
    pod_name="channel-serial-${i}"
    cat <<EOF | kubectl apply -f - > /dev/null 2>&1 &
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${NAMESPACE}
  labels:
    nvidia.com/compute-domain.name: ${CD_NAME}
spec:
  nodeName: ${target_node}
  containers:
  - name: worker
    image: nvidia/cuda:12.4.0-base-ubuntu22.04
    command: ["sleep", "infinity"]
    resources:
      claims:
      - name: channel
  resourceClaims:
  - name: channel
    resourceClaimTemplateName: ${CD_NAME}-channel
  restartPolicy: Never
EOF
    serial_pids+=($!)
done
wait

# 等待所有 pod Running
serial_latencies=()
for i in $(seq 1 "$PARALLEL_PODS"); do
    pod_name="channel-serial-${i}"
    latency=$(wait_for_condition "pod/${pod_name} Running" 120 \
        "[ \"\$(kubectl get pod ${pod_name} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null)\" = 'Running' ]")
    if [ $? -eq 0 ]; then
        serial_latencies+=("$latency")
        record_result "serial_prepare_latency" "$latency" "ms" "pod=${i},node=${target_node}"
        echo "  Pod ${i}: ${latency}ms"
    else
        echo "  Pod ${i}: TIMEOUT"
    fi
done

serial_total=$(elapsed_ms "$serial_start")
echo "  Total serial prepare time: ${serial_total}ms"
record_result "serial_prepare_total" "$serial_total" "ms" "pods=${PARALLEL_PODS}"

# flock 串行化预期：总时间 ≈ N × 单次时间
if [ ${#inject_latencies[@]} -gt 0 ] && [ ${#serial_latencies[@]} -gt 0 ]; then
    avg_single=$(( $(printf '%s\n' "${inject_latencies[@]}" | paste -sd+ | bc) / ${#inject_latencies[@]} ))
    echo "  Expected serial (${PARALLEL_PODS} × ${avg_single}ms) = $(( PARALLEL_PODS * avg_single ))ms"
    echo "  Actual: ${serial_total}ms"
fi

#=============================================================================
# 清理
#=============================================================================
for i in $(seq 1 "$PARALLEL_PODS"); do
    kubectl delete pod "channel-serial-${i}" -n "$NAMESPACE" --wait=false 2>/dev/null &
done
wait

cleanup_test
echo "[$(date -Iseconds)] TEST 04 COMPLETE."
```

---

### 场景 5: 节点故障 Failover

**目标：** 测量 GPU 节点故障后，Controller 2s 同步检测到缺失 pod 并触发 cleanupClique() 的恢复延迟。

**基线目标：**
| 指标 | 目标 |
|------|------|
| 故障检测 (pod 消失到 controller 感知) | < 4s (2× sync interval) |
| Clique 清理完成 | < 15s |
| CD 状态恢复到 Ready | < 30s |
| 无数据丢失 | 100% |

```bash
#!/usr/bin/env bash
# test_05_node_failover.sh — 节点故障 Failover 延迟测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "05_node_failover"

NODE_COUNT=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers | wc -l)
if [ "$NODE_COUNT" -lt 3 ]; then
    echo "SKIP: Need at least 3 GPU nodes for failover test (have ${NODE_COUNT})"
    exit 0
fi

#=============================================================================
# 准备：创建 CD 并等待 Ready
#=============================================================================
CD_NAME="cd-failover-test"
generate_cd_yaml "$CD_NAME" "$NODE_COUNT" "Single" | kubectl apply -f - > /dev/null

echo "Waiting for CD Ready..."
wait_cd_ready "$CD_NAME" 120
echo "CD Ready with ${NODE_COUNT} nodes."

# 记录初始状态
initial_ready=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" "$CD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyNodeCount}')
echo "Initial readyNodeCount: ${initial_ready}"

# 获取 daemon pods 和它们的节点
daemon_info=$(kubectl get pods -n "$NAMESPACE" \
    -l "nvidia.com/compute-domain.name=${CD_NAME}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}')
echo "Daemon pods:"
echo "$daemon_info"

# 选择要模拟故障的节点（取最后一个）
target_node=$(echo "$daemon_info" | tail -1 | awk '{print $2}')
target_pod=$(echo "$daemon_info" | tail -1 | awk '{print $1}')
echo ""
echo "Target node for failure: ${target_node}"
echo "Target daemon pod: ${target_pod}"

# 记录 Clique 状态
clique_before=$(kubectl get cliques -n "$NAMESPACE" \
    -l "nvidia.com/compute-domain.name=${CD_NAME}" --no-headers 2>/dev/null | wc -l)
echo "Cliques before failure: ${clique_before}"

#=============================================================================
# 模拟故障: 使节点不可调度并删除 daemon pod
#=============================================================================
echo ""
echo "=== Simulating node failure ==="
failure_start=$(now_ms)

# 方法 1: cordon + 删除 daemon pod（模拟节点离线）
kubectl cordon "$target_node" > /dev/null
kubectl delete pod "$target_pod" -n "$NAMESPACE" --grace-period=0 --force > /dev/null 2>&1

echo "Node cordoned, daemon pod deleted at $(date -Iseconds)"

#=============================================================================
# 测量阶段 1: 故障检测延迟
#=============================================================================
echo ""
echo "=== Phase 1: Failure Detection ==="

# Controller 应在 2s 同步周期内检测到缺失 pod
# 通过观察 CD 状态变化来检测
detect_ms=$(wait_for_condition "CD status change (not Ready)" 30 \
    "[ \"\$(kubectl get ${CD_RESOURCE}.${CD_API_GROUP} ${CD_NAME} -n ${NAMESPACE} \
        -o jsonpath='{.status.status}' 2>/dev/null)\" != 'Ready' ] || \
     [ \"\$(kubectl get ${CD_RESOURCE}.${CD_API_GROUP} ${CD_NAME} -n ${NAMESPACE} \
        -o jsonpath='{.status.readyNodeCount}' 2>/dev/null)\" != '${initial_ready}' ]")

if [ $? -eq 0 ]; then
    echo "  Failure detected in: ${detect_ms}ms"
    record_result "failover_detect_latency" "$detect_ms" "ms"
    assert_le "$detect_ms" 4000 "Detection within 2× cdStatusSyncInterval (4s)" || true
else
    echo "  Detection: TIMEOUT — controller may not have detected failure"
fi

#=============================================================================
# 测量阶段 2: Clique 清理
#=============================================================================
echo ""
echo "=== Phase 2: Clique Cleanup ==="

clique_cleanup_ms=$(wait_for_condition "clique entries cleaned" 60 \
    "[ \$(kubectl get cliques -n ${NAMESPACE} \
        -l nvidia.com/compute-domain.name=${CD_NAME} --no-headers 2>/dev/null | wc -l) -lt ${clique_before} ] || \
     ! kubectl get cliques -n ${NAMESPACE} 2>/dev/null | grep -q '${target_node}'")

if [ $? -eq 0 ]; then
    echo "  Clique cleanup in: ${clique_cleanup_ms}ms"
    record_result "failover_clique_cleanup" "$clique_cleanup_ms" "ms"
else
    echo "  Clique cleanup: could not confirm"
fi

#=============================================================================
# 恢复节点并测量恢复时间
#=============================================================================
echo ""
echo "=== Phase 3: Recovery ==="

kubectl uncordon "$target_node" > /dev/null
recovery_start=$(now_ms)
echo "Node uncordoned at $(date -Iseconds)"

recovery_ms=$(wait_cd_ready "$CD_NAME" 120)
if [ $? -eq 0 ]; then
    echo "  CD recovered to Ready in: ${recovery_ms}ms (from uncordon)"
    record_result "failover_recovery_latency" "$recovery_ms" "ms"
else
    echo "  Recovery: TIMEOUT"
fi

# 端到端 failover 时间
total_failover=$(elapsed_ms "$failure_start")
echo "  Total failover cycle: ${total_failover}ms"
record_result "failover_total_cycle" "$total_failover" "ms"

# 验证最终状态
final_ready=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" "$CD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyNodeCount}')
echo "  Final readyNodeCount: ${final_ready} (was: ${initial_ready})"

cleanup_test
echo "[$(date -Iseconds)] TEST 05 COMPLETE."
```

---

### 场景 6: Daemon 重启恢复

**目标：** 测量单个 IMEX Daemon Pod 被杀死后的重启恢复时间，验证 1s watchdog 的行为。

**基线目标：**
| 指标 | 目标 |
|------|------|
| Daemon Pod 重新调度 | < 5s |
| IMEX process restart (watchdog) | < 3s |
| CD 状态恢复 | < 10s |
| nodes.cfg 重新传播 | < 5s |

```bash
#!/usr/bin/env bash
# test_06_daemon_restart.sh — Daemon 重启恢复测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "06_daemon_restart"

CD_NAME="cd-restart-test"
generate_cd_yaml "$CD_NAME" 2 "Single" | kubectl apply -f - > /dev/null

echo "Waiting for CD Ready..."
wait_cd_ready "$CD_NAME" 120
echo "CD Ready."

#=============================================================================
# 获取 daemon pods
#=============================================================================
daemon_pods=$(kubectl get pods -n "$NAMESPACE" \
    -l "nvidia.com/compute-domain.name=${CD_NAME}" \
    -o jsonpath='{.items[*].metadata.name}')
daemon_arr=($daemon_pods)
echo "Daemon pods: ${daemon_arr[*]}"

ITERATIONS=3
restart_latencies=()
cd_recovery_latencies=()

for iter in $(seq 1 "$ITERATIONS"); do
    target_pod="${daemon_arr[0]}"
    echo ""
    echo "=== Iteration ${iter}: Killing ${target_pod} ==="

    # 记录 restart count
    restarts_before=$(kubectl get pod "$target_pod" -n "$NAMESPACE" \
        -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")

    kill_start=$(now_ms)

    # 杀死 daemon pod
    kubectl delete pod "$target_pod" -n "$NAMESPACE" --grace-period=0 --force > /dev/null 2>&1

    #-------------------------------------------------------------------------
    # 测量 1: 新 daemon pod 出现
    #-------------------------------------------------------------------------
    new_pod_ms=$(wait_for_condition "replacement daemon pod" 60 \
        "kubectl get pods -n ${NAMESPACE} -l nvidia.com/compute-domain.name=${CD_NAME} \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | \
            wc -l | grep -q '^[0-9]*$' && \
         [ \$(kubectl get pods -n ${NAMESPACE} -l nvidia.com/compute-domain.name=${CD_NAME} \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l) -ge 2 ]")

    if [ $? -eq 0 ]; then
        restart_latencies+=("$new_pod_ms")
        record_result "daemon_restart_latency" "$new_pod_ms" "ms" "iter=${iter}"
        echo "  New daemon Running: ${new_pod_ms}ms"
    else
        echo "  New daemon: TIMEOUT"
    fi

    #-------------------------------------------------------------------------
    # 测量 2: CD 恢复到 Ready
    #-------------------------------------------------------------------------
    cd_ready_ms=$(wait_cd_ready "$CD_NAME" 60)
    if [ $? -eq 0 ]; then
        total_recovery=$(elapsed_ms "$kill_start")
        cd_recovery_latencies+=("$total_recovery")
        record_result "daemon_restart_cd_recovery" "$total_recovery" "ms" "iter=${iter}"
        echo "  CD back to Ready: ${total_recovery}ms"
    else
        echo "  CD recovery: TIMEOUT"
    fi

    # 更新 pod 列表（可能有新 pod 名）
    daemon_pods=$(kubectl get pods -n "$NAMESPACE" \
        -l "nvidia.com/compute-domain.name=${CD_NAME}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[*].metadata.name}')
    daemon_arr=($daemon_pods)

    sleep 10
done

#=============================================================================
# 汇总
#=============================================================================
echo ""
echo "=== Summary ==="
[ ${#restart_latencies[@]} -gt 0 ] && record_summary "daemon_restart_latency" "${restart_latencies[@]}"
[ ${#cd_recovery_latencies[@]} -gt 0 ] && record_summary "daemon_restart_cd_recovery" "${cd_recovery_latencies[@]}"

cleanup_test
echo "[$(date -Iseconds)] TEST 06 COMPLETE."
```

---

### 场景 7: Controller 大规模 Reconcile

**目标：** 测量 Controller 在 100+ ComputeDomain 并存时的 reconcile 性能，含 informerResyncPeriod=10min 的全量同步。

**基线目标：**
| 指标 | 目标 |
|------|------|
| 100 CD 全部 Ready | < 15min |
| 单次 reconcile 延迟 | p99 < 500ms |
| 全量 resync (10min) 期间降级 | 0 |
| Controller 内存 (100 CD) | < 2Gi |
| Controller CPU (reconcile 峰值) | < 4 cores |

```bash
#!/usr/bin/env bash
# test_07_large_scale_reconcile.sh — 大规模 Reconcile 性能测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "07_large_scale_reconcile"

TOTAL_CDS="${CD_PERF_SCALE_CDS:-100}"
BATCH_SIZE=20
NODE_COUNT=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers | wc -l)

echo "Scale test: ${TOTAL_CDS} CDs, batch size ${BATCH_SIZE}, ${NODE_COUNT} GPU nodes"

#=============================================================================
# 阶段 1: 分批创建 CD
#=============================================================================
echo ""
echo "=== Phase 1: Batch Creation ==="
creation_start=$(now_ms)

created=0
while [ "$created" -lt "$TOTAL_CDS" ]; do
    batch_end=$(( created + BATCH_SIZE ))
    [ "$batch_end" -gt "$TOTAL_CDS" ] && batch_end="$TOTAL_CDS"

    echo -n "  Creating CDs $(( created + 1 ))-${batch_end}..."
    for i in $(seq $(( created + 1 )) "$batch_end"); do
        cd_name="cd-scale-$(printf '%04d' $i)"
        generate_cd_yaml "$cd_name" 2 "Single" | kubectl apply -f - > /dev/null 2>&1 &
    done
    wait
    echo " done"

    created=$batch_end
    # 小间隔避免 API server 过载
    sleep 2
done

creation_time=$(elapsed_ms "$creation_start")
echo "All ${TOTAL_CDS} CDs created in ${creation_time}ms"
record_result "scale_creation_time" "$creation_time" "ms" "n=${TOTAL_CDS}"

#=============================================================================
# 阶段 2: 等待所有 CD Ready
#=============================================================================
echo ""
echo "=== Phase 2: Wait All Ready ==="
ready_start=$(now_ms)
ready_count=0
check_interval=10

while true; do
    current_ready=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" -n "$NAMESPACE" \
        -o jsonpath='{range .items[*]}{.status.status}{"\n"}{end}' 2>/dev/null | grep -c "Ready" || echo "0")
    current_error=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" -n "$NAMESPACE" \
        -o jsonpath='{range .items[*]}{.status.status}{"\n"}{end}' 2>/dev/null | grep -c "Error" || echo "0")

    elapsed=$(elapsed_ms "$ready_start")
    echo "  [+${elapsed}ms] Ready: ${current_ready}/${TOTAL_CDS}  Error: ${current_error}"
    record_result "scale_progress" "$current_ready" "count" "elapsed=${elapsed}"

    if [ "$current_ready" -ge "$TOTAL_CDS" ]; then
        break
    fi

    if [ "$elapsed" -gt 900000 ]; then  # 15min 超时
        echo "  TIMEOUT: Only ${current_ready}/${TOTAL_CDS} Ready after 15min"
        break
    fi

    sleep "$check_interval"
done

all_ready_time=$(elapsed_ms "$ready_start")
echo "Final: ${current_ready}/${TOTAL_CDS} Ready in ${all_ready_time}ms"
record_result "scale_all_ready_time" "$all_ready_time" "ms" "n=${TOTAL_CDS}"
record_result "scale_ready_count" "$current_ready" "count" "n=${TOTAL_CDS}"

#=============================================================================
# 阶段 3: 稳态资源监控
#=============================================================================
echo ""
echo "=== Phase 3: Steady-State Resource Usage ==="

ctrl_pod=$(kubectl get pods -n nvidia-system -l app=nvidia-dra-controller \
    --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)

if [ -n "$ctrl_pod" ]; then
    for sample in $(seq 1 5); do
        metrics=$(kubectl top pod "$ctrl_pod" -n nvidia-system --no-headers 2>/dev/null || echo "N/A N/A N/A")
        echo "  Sample ${sample}: ${metrics}"
        record_result "controller_resources_steady" "$(echo $metrics | awk '{print $2}')" "cpu" "sample=${sample}"
        record_result "controller_memory_steady" "$(echo $metrics | awk '{print $3}')" "mem" "sample=${sample}"
        sleep 10
    done
fi

#=============================================================================
# 阶段 4: 触发全量 Resync 并测量影响
#=============================================================================
echo ""
echo "=== Phase 4: Full Resync Simulation ==="
echo "Waiting for informerResyncPeriod (10min) or simulating via controller restart..."

# 通过重启 controller 触发全量 resync
if [ -n "$ctrl_pod" ]; then
    resync_start=$(now_ms)
    kubectl delete pod "$ctrl_pod" -n nvidia-system --grace-period=10 > /dev/null

    echo "  Controller pod restarted, measuring reconcile storm..."

    # 监控所有 CD 是否保持 Ready
    degraded=0
    for check in $(seq 1 30); do
        ready_now=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" -n "$NAMESPACE" \
            -o jsonpath='{range .items[*]}{.status.status}{"\n"}{end}' 2>/dev/null | grep -c "Ready" || echo "0")
        if [ "$ready_now" -lt "$current_ready" ]; then
            degraded=1
            echo "  [check ${check}] DEGRADED: ${ready_now}/${current_ready}"
        fi
        sleep 2
    done

    resync_time=$(elapsed_ms "$resync_start")
    record_result "resync_time" "$resync_time" "ms"
    record_result "resync_degraded" "$degraded" "bool"

    if [ "$degraded" -eq 0 ]; then
        echo "  No degradation during resync (${resync_time}ms)"
    else
        echo "  DEGRADATION detected during resync"
    fi
fi

#=============================================================================
# 清理
#=============================================================================
echo ""
echo "=== Cleanup (${TOTAL_CDS} CDs) ==="
delete_start=$(now_ms)

for i in $(seq 1 "$TOTAL_CDS"); do
    cd_name="cd-scale-$(printf '%04d' $i)"
    kubectl delete "${CD_RESOURCE}.${CD_API_GROUP}" "$cd_name" -n "$NAMESPACE" --wait=false > /dev/null 2>&1 &
    # 控制并发
    [ $(( i % 50 )) -eq 0 ] && wait
done
wait

delete_time=$(elapsed_ms "$delete_start")
echo "All delete commands issued in ${delete_time}ms"

# 等待完全清理
wait_for_condition "all CDs deleted" 300 \
    "[ \$(kubectl get ${CD_RESOURCE}.${CD_API_GROUP} -n ${NAMESPACE} --no-headers 2>/dev/null | wc -l) -eq 0 ]"

cleanup_test
echo "[$(date -Iseconds)] TEST 07 COMPLETE."
```

---

### 场景 8: Clique 创建/清理

**目标：** 测量 Clique 资源的创建（gap-filling 索引分配）和清理（owner-referenced to daemon pods）性能。

**基线目标：**
| 指标 | 目标 |
|------|------|
| Clique 创建 (per node) | < 2s |
| Gap-filling 索引重分配 | < 5s |
| Owner-reference 级联删除 | < 10s |
| 10节点 clique 全创建 | < 15s |

```bash
#!/usr/bin/env bash
# test_08_clique_lifecycle.sh — Clique 创建/清理性能测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "08_clique_lifecycle"

NODE_COUNT=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers | wc -l)

#=============================================================================
# 子测试 8a: Clique 创建延迟
#=============================================================================
echo "=== 8a: Clique Creation ==="

CD_NAME="cd-clique-test"
generate_cd_yaml "$CD_NAME" "$NODE_COUNT" "Single" | kubectl apply -f - > /dev/null

creation_start=$(now_ms)

# 等待 CD Ready (意味着所有 clique 已创建)
wait_cd_ready "$CD_NAME" 120

clique_creation_time=$(elapsed_ms "$creation_start")
echo "CD Ready (all cliques created): ${clique_creation_time}ms"
record_result "clique_creation_total" "$clique_creation_time" "ms" "nodes=${NODE_COUNT}"

# 检查 clique 命名格式和数量
cliques=$(kubectl get cliques -n "$NAMESPACE" \
    -l "nvidia.com/compute-domain.name=${CD_NAME}" --no-headers 2>/dev/null)
clique_count=$(echo "$cliques" | wc -l)
echo "Cliques created: ${clique_count}"
echo "Clique list:"
echo "$cliques" | head -20

# 验证命名格式: <cdUID>.<cliqueID>
cd_uid=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" "$CD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.uid}')
echo "CD UID: ${cd_uid}"

if echo "$cliques" | head -1 | grep -q "${cd_uid}"; then
    echo "  Naming format verified: <cdUID>.<cliqueID>"
else
    echo "  WARNING: Clique naming does not match expected format"
fi

record_result "clique_count" "$clique_count" "count"

#=============================================================================
# 子测试 8b: Gap-filling 索引分配
#=============================================================================
echo ""
echo "=== 8b: Gap-Filling Index Assignment ==="

# 选择一个 daemon pod 并删除它以创建间隙
daemon_pods=$(kubectl get pods -n "$NAMESPACE" \
    -l "nvidia.com/compute-domain.name=${CD_NAME}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}')
daemon_arr=($daemon_pods)

if [ ${#daemon_arr[@]} -ge 2 ]; then
    # 删除中间的 daemon pod 创建索引间隙
    middle_idx=$(( ${#daemon_arr[@]} / 2 ))
    gap_pod="${daemon_arr[$middle_idx]}"
    echo "  Deleting daemon pod ${gap_pod} to create index gap..."

    # 记录删除前的 clique 索引
    clique_indices_before=$(kubectl get cliques -n "$NAMESPACE" \
        -l "nvidia.com/compute-domain.name=${CD_NAME}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)

    gap_start=$(now_ms)
    kubectl delete pod "$gap_pod" -n "$NAMESPACE" --grace-period=0 --force > /dev/null 2>&1

    # 等待新 daemon pod 出现并且 clique 重新分配
    gap_fill_ms=$(wait_for_condition "gap filled (daemon count restored)" 60 \
        "[ \$(kubectl get pods -n ${NAMESPACE} -l nvidia.com/compute-domain.name=${CD_NAME} \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l) -ge ${#daemon_arr[@]} ]")

    if [ $? -eq 0 ]; then
        echo "  Gap filled in: ${gap_fill_ms}ms"
        record_result "clique_gap_fill" "$gap_fill_ms" "ms"
    else
        echo "  Gap fill: TIMEOUT"
    fi

    # 验证索引连续性
    clique_indices_after=$(kubectl get cliques -n "$NAMESPACE" \
        -l "nvidia.com/compute-domain.name=${CD_NAME}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
    echo "  Clique indices after gap-fill:"
    echo "$clique_indices_after" | head -10

    sleep 10
fi

#=============================================================================
# 子测试 8c: Owner-reference 级联删除
#=============================================================================
echo ""
echo "=== 8c: Owner-Reference Cascade Cleanup ==="

# 删除 CD，观察 clique 通过 owner-reference 级联删除
cascade_start=$(now_ms)
kubectl delete "${CD_RESOURCE}.${CD_API_GROUP}" "$CD_NAME" -n "$NAMESPACE" > /dev/null

# 等待所有 clique 被删除
cascade_ms=$(wait_for_condition "all cliques deleted" 60 \
    "[ \$(kubectl get cliques -n ${NAMESPACE} \
        -l nvidia.com/compute-domain.name=${CD_NAME} --no-headers 2>/dev/null | wc -l) -eq 0 ]")

if [ $? -eq 0 ]; then
    echo "  Cascade cleanup in: ${cascade_ms}ms"
    record_result "clique_cascade_cleanup" "$cascade_ms" "ms" "cliques=${clique_count}"
else
    echo "  Cascade cleanup: TIMEOUT"
    remaining=$(kubectl get cliques -n "$NAMESPACE" \
        -l "nvidia.com/compute-domain.name=${CD_NAME}" --no-headers 2>/dev/null | wc -l)
    echo "  Remaining cliques: ${remaining}"
fi

cleanup_test
echo "[$(date -Iseconds)] TEST 08 COMPLETE."
```

---

### 场景 9: 升降级中断时间

**目标：** 测量 DRA Driver 升降级期间 ComputeDomain 的中断时间（controller 和 daemon 重启窗口）。

**基线目标：**
| 指标 | 目标 |
|------|------|
| Controller 重启中断 | < 30s |
| Daemon rolling update 中断 | 0s (rolling) |
| 新 CD 创建在升级中 | 可接受延迟 < 60s |
| 升级后 CD 状态一致性 | 100% |

```bash
#!/usr/bin/env bash
# test_09_upgrade_disruption.sh — 升降级中断时间测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "09_upgrade_disruption"

DRA_NAMESPACE="${DRA_NAMESPACE:-nvidia-system}"

#=============================================================================
# 准备：创建多个 CD 并等待就绪
#=============================================================================
NUM_CDS=5
echo "Creating ${NUM_CDS} CDs for upgrade test..."

for i in $(seq 1 "$NUM_CDS"); do
    cd_name="cd-upgrade-${i}"
    generate_cd_yaml "$cd_name" 2 "Single" | kubectl apply -f - > /dev/null
done

all_ready=0
for i in $(seq 1 "$NUM_CDS"); do
    wait_cd_ready "cd-upgrade-${i}" 120 && all_ready=$(( all_ready + 1 ))
done
echo "CDs Ready: ${all_ready}/${NUM_CDS}"

#=============================================================================
# 子测试 9a: Controller 重启中断
#=============================================================================
echo ""
echo "=== 9a: Controller Restart Disruption ==="

ctrl_deploy=$(kubectl get deployment -n "$DRA_NAMESPACE" \
    -l app=nvidia-dra-controller -o name 2>/dev/null | head -1)

if [ -z "$ctrl_deploy" ]; then
    echo "  SKIP: Cannot find controller deployment"
else
    restart_start=$(now_ms)

    # 触发 controller 重启
    kubectl rollout restart "$ctrl_deploy" -n "$DRA_NAMESPACE" > /dev/null

    # 持续监控 CD 状态
    disruption_detected=false
    disruption_start_ms=0
    disruption_end_ms=0
    max_checks=60

    for check in $(seq 1 "$max_checks"); do
        ready_count=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" -n "$NAMESPACE" \
            -o jsonpath='{range .items[*]}{.status.status}{"\n"}{end}' 2>/dev/null | grep -c "Ready" || echo "0")

        if [ "$ready_count" -lt "$NUM_CDS" ] && [ "$disruption_detected" = false ]; then
            disruption_detected=true
            disruption_start_ms=$(now_ms)
            echo "  [check ${check}] Disruption started: ${ready_count}/${NUM_CDS} Ready"
        fi

        if [ "$ready_count" -ge "$NUM_CDS" ] && [ "$disruption_detected" = true ]; then
            disruption_end_ms=$(now_ms)
            disruption_ms=$(( disruption_end_ms - disruption_start_ms ))
            echo "  [check ${check}] Disruption ended: ${disruption_ms}ms"
            record_result "controller_restart_disruption" "$disruption_ms" "ms"
            break
        fi

        sleep 1
    done

    if [ "$disruption_detected" = false ]; then
        echo "  No disruption detected during controller restart"
        record_result "controller_restart_disruption" "0" "ms"
    fi

    # 等待 rollout 完成
    kubectl rollout status "$ctrl_deploy" -n "$DRA_NAMESPACE" --timeout=120s > /dev/null

    total_restart=$(elapsed_ms "$restart_start")
    echo "  Controller restart total time: ${total_restart}ms"
    record_result "controller_restart_total" "$total_restart" "ms"
fi

#=============================================================================
# 子测试 9b: 升级期间新 CD 创建
#=============================================================================
echo ""
echo "=== 9b: CD Creation During Upgrade ==="

# 再次触发 controller rolling update
if [ -n "$ctrl_deploy" ]; then
    kubectl rollout restart "$ctrl_deploy" -n "$DRA_NAMESPACE" > /dev/null
    sleep 2  # 让 rolling update 开始

    # 在升级过程中创建新 CD
    new_cd_name="cd-upgrade-during"
    create_start=$(now_ms)
    generate_cd_yaml "$new_cd_name" 2 "Single" | kubectl apply -f - > /dev/null

    new_cd_latency=$(wait_cd_ready "$new_cd_name" 180)
    if [ $? -eq 0 ]; then
        echo "  New CD during upgrade: ${new_cd_latency}ms"
        record_result "cd_creation_during_upgrade" "$new_cd_latency" "ms"
        assert_le "$new_cd_latency" 60000 "New CD during upgrade < 60s" || true
    else
        echo "  New CD during upgrade: TIMEOUT"
    fi

    kubectl rollout status "$ctrl_deploy" -n "$DRA_NAMESPACE" --timeout=120s > /dev/null 2>&1
fi

#=============================================================================
# 子测试 9c: 升级后状态一致性
#=============================================================================
echo ""
echo "=== 9c: Post-Upgrade Consistency ==="

sleep 10  # 等待状态稳定

total_cds=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" -n "$NAMESPACE" --no-headers | wc -l)
ready_cds=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.status.status}{"\n"}{end}' 2>/dev/null | grep -c "Ready" || echo "0")

echo "  Post-upgrade: ${ready_cds}/${total_cds} Ready"
record_result "post_upgrade_consistency" "$ready_cds" "count" "total=${total_cds}"

if [ "$ready_cds" -eq "$total_cds" ]; then
    echo "  PASS: 100% consistency"
else
    echo "  FAIL: $(( total_cds - ready_cds )) CDs not Ready"
fi

cleanup_test
echo "[$(date -Iseconds)] TEST 09 COMPLETE."
```

---

### 场景 10: 多 CD 资源争抢

**目标：** 测量多个 ComputeDomain 竞争相同 GPU 节点资源时的分配行为和性能。

**基线目标：**
| 指标 | 目标 |
|------|------|
| 资源竞争下 CD Ready | p95 < 60s |
| Channel 分配冲突解决 | < 10s |
| allocationMode=All vs Single | All延迟 < 2× Single |
| 资源耗尽正确报 Error | < 5s |

```bash
#!/usr/bin/env bash
# test_10_resource_contention.sh — 多 CD 资源争抢测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "10_resource_contention"

NODE_COUNT=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers | wc -l)

#=============================================================================
# 子测试 10a: 多 CD 竞争相同节点
#=============================================================================
echo "=== 10a: Multiple CDs Competing for Same Nodes ==="

NUM_COMPETING=5
compete_latencies=()
compete_start=$(now_ms)

for i in $(seq 1 "$NUM_COMPETING"); do
    cd_name="cd-compete-${i}"
    generate_cd_yaml "$cd_name" 2 "Single" | kubectl apply -f - > /dev/null &
done
wait

echo "  ${NUM_COMPETING} CDs submitted simultaneously"

for i in $(seq 1 "$NUM_COMPETING"); do
    cd_name="cd-compete-${i}"
    latency=$(wait_cd_ready "$cd_name" 180)
    status=$?
    actual_status=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" "$cd_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.status}' 2>/dev/null)

    if [ $status -eq 0 ]; then
        compete_latencies+=("$latency")
        echo "  ${cd_name}: Ready in ${latency}ms"
    else
        echo "  ${cd_name}: ${actual_status} (not Ready)"
    fi
    record_result "contention_latency" "${latency:-TIMEOUT}" "ms" "cd=${cd_name},status=${actual_status}"
done

compete_total=$(elapsed_ms "$compete_start")
echo "  Total contention time: ${compete_total}ms"
echo "  Ready: ${#compete_latencies[@]}/${NUM_COMPETING}"

[ ${#compete_latencies[@]} -gt 0 ] && record_summary "contention_ready_latency" "${compete_latencies[@]}"

# 清理
for i in $(seq 1 "$NUM_COMPETING"); do
    kubectl delete "${CD_RESOURCE}.${CD_API_GROUP}" "cd-compete-${i}" -n "$NAMESPACE" --wait=false > /dev/null 2>&1 &
done
wait
sleep 15

#=============================================================================
# 子测试 10b: allocationMode Single vs All 对比
#=============================================================================
echo ""
echo "=== 10b: Single vs All Allocation Mode ==="

for mode in "Single" "All"; do
    cd_name="cd-mode-$(echo $mode | tr '[:upper:]' '[:lower:]')"
    echo -n "  ${mode} mode: "

    start=$(now_ms)
    generate_cd_yaml "$cd_name" 2 "$mode" | kubectl apply -f - > /dev/null

    latency=$(wait_cd_ready "$cd_name" 120)
    if [ $? -eq 0 ]; then
        echo "${latency}ms"
        record_result "alloc_mode_latency" "$latency" "ms" "mode=${mode}"
    else
        echo "TIMEOUT"
    fi

    kubectl delete "${CD_RESOURCE}.${CD_API_GROUP}" "$cd_name" -n "$NAMESPACE" --wait=false > /dev/null
    sleep 10
done

#=============================================================================
# 子测试 10c: 资源耗尽检测
#=============================================================================
echo ""
echo "=== 10c: Resource Exhaustion Detection ==="

# 创建足够多的 CD 以耗尽 channel 资源
EXHAUST_COUNT=$(( NODE_COUNT * 3 ))  # 超额请求
echo "  Creating ${EXHAUST_COUNT} CDs to exhaust resources..."

for i in $(seq 1 "$EXHAUST_COUNT"); do
    cd_name="cd-exhaust-${i}"
    generate_cd_yaml "$cd_name" "$NODE_COUNT" "All" 2048 | kubectl apply -f - > /dev/null 2>&1 &
done
wait

sleep 30  # 等待状态稳定

# 统计状态
ready_count=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.status.status}{"\n"}{end}' 2>/dev/null | grep -c "Ready" || echo "0")
error_count=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.status.status}{"\n"}{end}' 2>/dev/null | grep -c "Error" || echo "0")
not_ready=$(kubectl get "${CD_RESOURCE}.${CD_API_GROUP}" -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.status.status}{"\n"}{end}' 2>/dev/null | grep -c "NotReady" || echo "0")

echo "  Results: Ready=${ready_count} Error=${error_count} NotReady=${not_ready}"
record_result "exhaustion_ready" "$ready_count" "count"
record_result "exhaustion_error" "$error_count" "count"

# 验证系统正确报告了资源耗尽（Error 状态）
if [ "$error_count" -gt 0 ]; then
    echo "  PASS: System correctly reports resource exhaustion"
else
    echo "  WARN: No Error status detected — may need more CDs to exhaust resources"
fi

cleanup_test
echo "[$(date -Iseconds)] TEST 10 COMPLETE."
```

---

### 场景 11: CD 删除级联延迟

**目标：** 测量 ComputeDomain 删除时的级联清理延迟，包括 DaemonSet、Daemon Pods、Cliques、ResourceClaims 的删除。

**基线目标：**
| 指标 | 目标 |
|------|------|
| 单 CD 级联删除 (2 nodes) | < 30s |
| 单 CD 级联删除 (10 nodes) | < 60s |
| 批量 10 CD 删除 | < 90s |
| ResourceClaim 释放 | < 15s |
| 无残留资源 | 100% |

```bash
#!/usr/bin/env bash
# test_11_cascade_delete.sh — CD 删除级联延迟测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "11_cascade_delete"

NODE_COUNT=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers | wc -l)

#=============================================================================
# 子测试 11a: 单 CD 删除级联
#=============================================================================
echo "=== 11a: Single CD Cascade Delete ==="

ITERATIONS=5
delete_latencies=()

for iter in $(seq 1 "$ITERATIONS"); do
    cd_name="cd-delete-${iter}"
    echo -n "  Iteration ${iter}: create..."
    generate_cd_yaml "$cd_name" 2 "Single" | kubectl apply -f - > /dev/null
    wait_cd_ready "$cd_name" 120 > /dev/null

    # 记录删除前的关联资源
    daemon_pods=$(kubectl get pods -n "$NAMESPACE" \
        -l "nvidia.com/compute-domain.name=${cd_name}" --no-headers 2>/dev/null | wc -l)
    claims=$(kubectl get resourceclaims -n "$NAMESPACE" --no-headers 2>/dev/null | \
        grep "${cd_name}" | wc -l)
    cliques=$(kubectl get cliques -n "$NAMESPACE" \
        -l "nvidia.com/compute-domain.name=${cd_name}" --no-headers 2>/dev/null | wc -l)

    echo -n "delete (pods=${daemon_pods},claims=${claims},cliques=${cliques})..."

    # 删除并计时
    delete_start=$(now_ms)
    kubectl delete "${CD_RESOURCE}.${CD_API_GROUP}" "$cd_name" -n "$NAMESPACE" > /dev/null

    # 等待所有关联资源消失
    cascade_ms=$(wait_for_condition "all cascade resources deleted" 120 \
        "[ \$(kubectl get pods -n ${NAMESPACE} -l nvidia.com/compute-domain.name=${cd_name} \
            --no-headers 2>/dev/null | wc -l) -eq 0 ] && \
         [ \$(kubectl get cliques -n ${NAMESPACE} -l nvidia.com/compute-domain.name=${cd_name} \
            --no-headers 2>/dev/null | wc -l) -eq 0 ]")

    if [ $? -eq 0 ]; then
        delete_latencies+=("$cascade_ms")
        record_result "single_cascade_delete" "$cascade_ms" "ms" "iter=${iter}"
        echo " ${cascade_ms}ms"
    else
        echo " TIMEOUT"
    fi

    sleep 5
done

[ ${#delete_latencies[@]} -gt 0 ] && record_summary "single_cascade_delete" "${delete_latencies[@]}"

#=============================================================================
# 子测试 11b: 批量 CD 删除
#=============================================================================
echo ""
echo "=== 11b: Batch CD Cascade Delete ==="

BATCH_SIZE=10
echo "  Creating ${BATCH_SIZE} CDs..."

for i in $(seq 1 "$BATCH_SIZE"); do
    cd_name="cd-batch-del-${i}"
    generate_cd_yaml "$cd_name" 2 "Single" | kubectl apply -f - > /dev/null &
done
wait

# 等待所有就绪
for i in $(seq 1 "$BATCH_SIZE"); do
    wait_cd_ready "cd-batch-del-${i}" 120 > /dev/null || true
done

echo "  All ${BATCH_SIZE} CDs ready. Starting batch delete..."

batch_delete_start=$(now_ms)
for i in $(seq 1 "$BATCH_SIZE"); do
    kubectl delete "${CD_RESOURCE}.${CD_API_GROUP}" "cd-batch-del-${i}" \
        -n "$NAMESPACE" --wait=false > /dev/null 2>&1 &
done
wait

# 等待全部清理完成
batch_cascade_ms=$(wait_for_condition "all batch CDs fully deleted" 180 \
    "[ \$(kubectl get ${CD_RESOURCE}.${CD_API_GROUP} -n ${NAMESPACE} --no-headers 2>/dev/null | \
        grep 'cd-batch-del' | wc -l) -eq 0 ] && \
     [ \$(kubectl get pods -n ${NAMESPACE} -l nvidia.com/compute-domain.name --no-headers 2>/dev/null | \
        grep 'cd-batch-del' | wc -l) -eq 0 ]")

if [ $? -eq 0 ]; then
    echo "  Batch cascade delete: ${batch_cascade_ms}ms"
    record_result "batch_cascade_delete" "$batch_cascade_ms" "ms" "batch=${BATCH_SIZE}"
else
    echo "  Batch cascade: TIMEOUT"
fi

#=============================================================================
# 子测试 11c: 残留资源检查
#=============================================================================
echo ""
echo "=== 11c: Residual Resource Check ==="
sleep 10

residual_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
residual_claims=$(kubectl get resourceclaims -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
residual_cliques=$(kubectl get cliques -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)

echo "  Residual pods: ${residual_pods}"
echo "  Residual claims: ${residual_claims}"
echo "  Residual cliques: ${residual_cliques}"

record_result "residual_pods" "$residual_pods" "count"
record_result "residual_claims" "$residual_claims" "count"
record_result "residual_cliques" "$residual_cliques" "count"

total_residual=$(( residual_pods + residual_claims + residual_cliques ))
if [ "$total_residual" -eq 0 ]; then
    echo "  PASS: No residual resources"
else
    echo "  FAIL: ${total_residual} residual resources found"
fi

cleanup_test
echo "[$(date -Iseconds)] TEST 11 COMPLETE."
```

---

### 场景 12: nodes.cfg 传播延迟

**目标：** 测量 nodes.cfg（DNS/IP 双模式）在节点加入/离开时的传播和更新延迟。

**基线目标：**
| 指标 | 目标 |
|------|------|
| 新节点加入 nodes.cfg 更新 | < 10s |
| 节点移除 nodes.cfg 更新 | < 10s |
| nodes.cfg 全节点一致性 | < 15s |
| DNS 模式解析验证 | 100% |

```bash
#!/usr/bin/env bash
# test_12_nodes_cfg_propagation.sh — nodes.cfg 传播延迟测试
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

init_test "12_nodes_cfg_propagation"

NODE_COUNT=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers | wc -l)
if [ "$NODE_COUNT" -lt 3 ]; then
    echo "SKIP: Need at least 3 GPU nodes (have ${NODE_COUNT})"
    exit 0
fi

#=============================================================================
# 准备
#=============================================================================
CD_NAME="cd-nodescfg-test"
generate_cd_yaml "$CD_NAME" "$NODE_COUNT" "Single" | kubectl apply -f - > /dev/null

echo "Waiting for CD Ready..."
wait_cd_ready "$CD_NAME" 120
echo "CD Ready with ${NODE_COUNT} nodes."

# 获取 daemon pods 及其节点
daemon_pods_json=$(kubectl get pods -n "$NAMESPACE" \
    -l "nvidia.com/compute-domain.name=${CD_NAME}" \
    --field-selector=status.phase=Running \
    -o json)

daemon_pods=$(echo "$daemon_pods_json" | jq -r '.items[].metadata.name')
echo "Daemon pods:"
echo "$daemon_pods"

#=============================================================================
# 子测试 12a: 读取并验证当前 nodes.cfg
#=============================================================================
echo ""
echo "=== 12a: Verify Current nodes.cfg ==="

first_pod=$(echo "$daemon_pods" | head -1)

# 读取 nodes.cfg 内容
nodes_cfg=$(kubectl exec "$first_pod" -n "$NAMESPACE" -- \
    cat /etc/imex/nodes.cfg 2>/dev/null || echo "NOT_FOUND")

if [ "$nodes_cfg" = "NOT_FOUND" ]; then
    # 尝试其他常见路径
    nodes_cfg=$(kubectl exec "$first_pod" -n "$NAMESPACE" -- \
        cat /var/run/imex/nodes.cfg 2>/dev/null || echo "NOT_FOUND")
fi

echo "  nodes.cfg content:"
echo "$nodes_cfg" | head -20
echo "  Lines: $(echo "$nodes_cfg" | wc -l)"

# 检测模式：DNS 或 IP
if echo "$nodes_cfg" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
    cfg_mode="IP"
elif echo "$nodes_cfg" | grep -qE '^[a-zA-Z]'; then
    cfg_mode="DNS"
else
    cfg_mode="UNKNOWN"
fi
echo "  Mode: ${cfg_mode}"
record_result "nodes_cfg_mode" "$cfg_mode" "mode"

# 验证所有节点都在 cfg 中
expected_nodes=$(echo "$daemon_pods_json" | jq -r '.items[].spec.nodeName' | sort)
cfg_entries=$(echo "$nodes_cfg" | grep -v '^$' | sort)
echo "  Expected nodes: $(echo $expected_nodes | wc -w)"
echo "  Config entries: $(echo $cfg_entries | wc -w)"

#=============================================================================
# 子测试 12b: 节点移除后的 nodes.cfg 更新
#=============================================================================
echo ""
echo "=== 12b: Node Removal — nodes.cfg Update ==="

# Cordon 一个节点模拟移除
remove_node=$(echo "$daemon_pods_json" | jq -r '.items[-1].spec.nodeName')
remove_pod=$(echo "$daemon_pods_json" | jq -r '.items[-1].metadata.name')
echo "  Removing node: ${remove_node} (pod: ${remove_pod})"

original_entry_count=$(echo "$nodes_cfg" | grep -v '^$' | wc -l)

remove_start=$(now_ms)
kubectl cordon "$remove_node" > /dev/null
kubectl delete pod "$remove_pod" -n "$NAMESPACE" --grace-period=0 --force > /dev/null 2>&1

# 监控 nodes.cfg 变化
check_pod=$(echo "$daemon_pods" | head -1)
if [ "$check_pod" = "$remove_pod" ]; then
    check_pod=$(echo "$daemon_pods" | sed -n '2p')
fi

propagation_ms=$(wait_for_condition "nodes.cfg updated (entry removed)" 60 \
    "[ \$(kubectl exec ${check_pod} -n ${NAMESPACE} -- cat /etc/imex/nodes.cfg 2>/dev/null | \
        grep -v '^$' | wc -l) -lt ${original_entry_count} ]" "1")

if [ $? -eq 0 ]; then
    echo "  nodes.cfg updated in: ${propagation_ms}ms"
    record_result "nodes_cfg_remove_propagation" "$propagation_ms" "ms"
else
    echo "  nodes.cfg update: TIMEOUT or path not accessible"
fi

#=============================================================================
# 子测试 12c: 节点重新加入后的 nodes.cfg 更新
#=============================================================================
echo ""
echo "=== 12c: Node Rejoin — nodes.cfg Update ==="

rejoin_start=$(now_ms)
kubectl uncordon "$remove_node" > /dev/null
echo "  Node ${remove_node} uncordoned"

# 等待 daemon pod 重新出现在该节点
wait_for_condition "daemon pod rescheduled on ${remove_node}" 60 \
    "kubectl get pods -n ${NAMESPACE} -l nvidia.com/compute-domain.name=${CD_NAME} \
        --field-selector=spec.nodeName=${remove_node},status.phase=Running \
        --no-headers 2>/dev/null | grep -q ." > /dev/null

# 等待 nodes.cfg 包含恢复的节点
rejoin_propagation_ms=$(wait_for_condition "nodes.cfg includes rejoined node" 60 \
    "[ \$(kubectl exec ${check_pod} -n ${NAMESPACE} -- cat /etc/imex/nodes.cfg 2>/dev/null | \
        grep -v '^$' | wc -l) -ge ${original_entry_count} ]" "1")

if [ $? -eq 0 ]; then
    echo "  nodes.cfg rejoin propagation: ${rejoin_propagation_ms}ms"
    record_result "nodes_cfg_rejoin_propagation" "$rejoin_propagation_ms" "ms"
else
    echo "  Rejoin propagation: TIMEOUT"
fi

#=============================================================================
# 子测试 12d: 全节点一致性检查
#=============================================================================
echo ""
echo "=== 12d: Cross-Node Consistency ==="

# 等待 CD 恢复 Ready
wait_cd_ready "$CD_NAME" 60 > /dev/null
sleep 5

# 从所有 daemon pods 读取 nodes.cfg 并比较
current_pods=$(kubectl get pods -n "$NAMESPACE" \
    -l "nvidia.com/compute-domain.name=${CD_NAME}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}')

configs=()
consistent=true
reference_cfg=""

for pod in $current_pods; do
    cfg=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
        cat /etc/imex/nodes.cfg 2>/dev/null | sort || echo "ERROR")

    if [ -z "$reference_cfg" ]; then
        reference_cfg="$cfg"
    elif [ "$cfg" != "$reference_cfg" ]; then
        consistent=false
        echo "  INCONSISTENCY on pod ${pod}"
    fi
done

if [ "$consistent" = true ]; then
    echo "  PASS: All nodes have consistent nodes.cfg"
    record_result "nodes_cfg_consistency" "1" "bool"
else
    echo "  FAIL: Inconsistent nodes.cfg across nodes"
    record_result "nodes_cfg_consistency" "0" "bool"
fi

#=============================================================================
# DNS 模式验证
#=============================================================================
if [ "$cfg_mode" = "DNS" ]; then
    echo ""
    echo "=== DNS Resolution Verification ==="
    for pod in $(echo "$current_pods" | tr ' ' '\n' | head -2); do
        echo "  From pod ${pod}:"
        first_entry=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
            head -1 /etc/imex/nodes.cfg 2>/dev/null)
        if [ -n "$first_entry" ]; then
            resolved=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
                getent hosts "$first_entry" 2>/dev/null || echo "FAILED")
            echo "    ${first_entry} -> ${resolved}"
        fi
    done
fi

cleanup_test
echo "[$(date -Iseconds)] TEST 12 COMPLETE."
```

---

## 5. kube-burner 配置

```yaml
# kube-burner-config.yaml
---
global:
  writeToFile: true
  metricsDirectory: ./kb-metrics
  indexerConfig:
    enabled: false
  measurements:
  - name: podLatency
    thresholds:
    - conditionType: Ready
      metric: P99
      threshold: 30s

jobs:
# Job 1: 批量 CD 创建
- name: cd-batch-creation
  namespace: cd-perf-test
  jobIterations: 100
  qps: 10
  burst: 20
  namespacedIterations: true
  cleanup: true
  waitWhenFinished: true
  maxWaitTimeout: 15m
  objects:
  - objectTemplate: templates/compute-domain-basic.yaml
    replicas: 1
    inputVars:
      ALLOC_MODE: Single
      CHANNEL_DEVICES: 2048

# Job 2: 高并发 CD 创建压力测试
- name: cd-stress-creation
  namespace: cd-perf-stress
  jobIterations: 50
  qps: 50
  burst: 50
  namespacedIterations: true
  cleanup: true
  waitWhenFinished: true
  maxWaitTimeout: 10m
  objects:
  - objectTemplate: templates/compute-domain-basic.yaml
    replicas: 1
    inputVars:
      ALLOC_MODE: Single
      CHANNEL_DEVICES: 2048

# Job 3: CD 删除吞吐量
- name: cd-deletion-throughput
  namespace: cd-perf-delete
  jobIterations: 50
  qps: 20
  burst: 20
  namespacedIterations: true
  cleanup: false
  jobType: delete
  waitForDeletion: true
  maxWaitTimeout: 5m
  objects:
  - kind: ComputeDomain
    apiVersion: gpu.resource.nvidia.com/v1alpha1
    labelSelector:
      matchLabels:
        kube-burner-job: cd-deletion-throughput
```

```yaml
# kube-burner-metrics.yaml
# Prometheus 查询配置
metrics:
- query: histogram_quantile(0.99, sum(rate(workqueue_queue_duration_seconds_bucket{name="computedomain"}[2m])) by (le))
  metricName: cd_reconcile_queue_latency_p99

- query: histogram_quantile(0.99, sum(rate(workqueue_work_duration_seconds_bucket{name="computedomain"}[2m])) by (le))
  metricName: cd_reconcile_work_latency_p99

- query: sum(workqueue_depth{name="computedomain"})
  metricName: cd_reconcile_queue_depth

- query: rate(workqueue_retries_total{name="computedomain"}[5m])
  metricName: cd_reconcile_retry_rate

- query: sum(rate(container_cpu_usage_seconds_total{namespace="nvidia-system",container="nvidia-dra-controller"}[5m]))
  metricName: controller_cpu_usage

- query: sum(container_memory_working_set_bytes{namespace="nvidia-system",container="nvidia-dra-controller"})
  metricName: controller_memory_usage

- query: count(kube_pod_status_phase{namespace=~"cd-perf.*",phase="Running"})
  metricName: cd_daemon_pods_running

- query: count by (status) (computedomain_status{namespace=~"cd-perf.*"})
  metricName: cd_status_distribution
```

---

## 6. Prometheus 监控配置

```yaml
# prometheus/cd-perf-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cd-perf-test-rules
  namespace: monitoring
spec:
  groups:
  - name: computedomain.perf
    interval: 10s
    rules:
    # CD 状态转换延迟
    - record: cd:creation_to_ready_seconds
      expr: |
        (
          max by (name) (kube_customresource_status_condition{
            group="gpu.resource.nvidia.com",
            resource="computedomains",
            condition="Ready",
            status="true"
          } * on(name) group_left()
          kube_customresource_created{
            group="gpu.resource.nvidia.com",
            resource="computedomains"
          })
        ) - (
          min by (name) (kube_customresource_created{
            group="gpu.resource.nvidia.com",
            resource="computedomains"
          })
        )

    # Controller reconcile 速率
    - record: cd:reconcile_rate_per_second
      expr: |
        sum(rate(controller_runtime_reconcile_total{
          controller="computedomain"
        }[5m]))

    # Reconcile 错误率
    - record: cd:reconcile_error_rate
      expr: |
        sum(rate(controller_runtime_reconcile_errors_total{
          controller="computedomain"
        }[5m]))
        /
        sum(rate(controller_runtime_reconcile_total{
          controller="computedomain"
        }[5m]))

    # Daemon pod 启动延迟
    - record: cd:daemon_startup_seconds
      expr: |
        histogram_quantile(0.95,
          sum(rate(kubelet_pod_start_duration_seconds_bucket{
            pod=~".*imex.*"
          }[5m])) by (le)
        )

    # Channel prepare 延迟
    - record: cd:channel_prepare_seconds
      expr: |
        histogram_quantile(0.95,
          sum(rate(kubelet_plugin_prepare_duration_seconds_bucket{
            driver="gpu.resource.nvidia.com"
          }[5m])) by (le)
        )

  - name: computedomain.alerts
    rules:
    - alert: CDReconcileLatencyHigh
      expr: |
        histogram_quantile(0.99,
          sum(rate(workqueue_work_duration_seconds_bucket{
            name="computedomain"
          }[5m])) by (le)
        ) > 0.5
      for: 2m
      labels:
        severity: warning
      annotations:
        summary: "CD reconcile p99 latency > 500ms"

    - alert: CDReconcileQueueBacklog
      expr: workqueue_depth{name="computedomain"} > 50
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "CD reconcile queue depth > 50"

    - alert: CDControllerMemoryHigh
      expr: |
        container_memory_working_set_bytes{
          namespace="nvidia-system",
          container="nvidia-dra-controller"
        } > 2147483648
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "DRA Controller memory > 2Gi"
```

```yaml
# prometheus/cd-perf-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nvidia-dra-controller
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: nvidia-dra-controller
  namespaceSelector:
    matchNames:
    - nvidia-system
  endpoints:
  - port: metrics
    interval: 10s
    path: /metrics
```

```yaml
# grafana/cd-perf-dashboard.json (核心 panels 配置)
# 导入到 Grafana 作为 dashboard
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cd-perf-grafana-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  cd-perf.json: |
    {
      "dashboard": {
        "title": "ComputeDomain Performance",
        "panels": [
          {
            "title": "CD Creation-to-Ready Latency",
            "type": "timeseries",
            "targets": [{"expr": "cd:creation_to_ready_seconds"}]
          },
          {
            "title": "Reconcile Rate",
            "type": "timeseries",
            "targets": [{"expr": "cd:reconcile_rate_per_second"}]
          },
          {
            "title": "Reconcile Error Rate",
            "type": "stat",
            "targets": [{"expr": "cd:reconcile_error_rate"}]
          },
          {
            "title": "Controller Resources",
            "type": "timeseries",
            "targets": [
              {"expr": "sum(rate(container_cpu_usage_seconds_total{namespace='nvidia-system',container='nvidia-dra-controller'}[5m]))"},
              {"expr": "container_memory_working_set_bytes{namespace='nvidia-system',container='nvidia-dra-controller'}"}
            ]
          },
          {
            "title": "Reconcile Queue Depth",
            "type": "timeseries",
            "targets": [{"expr": "workqueue_depth{name='computedomain'}"}]
          },
          {
            "title": "Daemon Pod Count",
            "type": "stat",
            "targets": [{"expr": "count(kube_pod_status_phase{namespace=~'cd-perf.*',phase='Running'})"}]
          }
        ]
      }
    }
```

---

## 7. CI Workflow

```yaml
# .github/workflows/cd-perf-test.yaml
name: ComputeDomain Performance Tests

on:
  schedule:
    - cron: '0 2 * * 1'  # 每周一 02:00 UTC
  workflow_dispatch:
    inputs:
      scale:
        description: 'Number of CDs for scale test'
        default: '100'
      scenarios:
        description: 'Comma-separated scenario numbers (e.g., 1,2,5) or "all"'
        default: 'all'
      cluster:
        description: 'Target cluster context'
        default: 'gpu-perf-cluster'

env:
  CD_PERF_NAMESPACE: cd-perf-test
  CD_PERF_RESULTS: ./results/${{ github.run_id }}
  CD_PERF_SCALE_CDS: ${{ github.event.inputs.scale || '100' }}

jobs:
  setup:
    runs-on: ubuntu-latest
    outputs:
      scenarios: ${{ steps.parse.outputs.scenarios }}
    steps:
    - uses: actions/checkout@v4
    - id: parse
      run: |
        input="${{ github.event.inputs.scenarios || 'all' }}"
        if [ "$input" = "all" ]; then
          echo "scenarios=[1,2,3,4,5,6,7,8,9,10,11,12]" >> "$GITHUB_OUTPUT"
        else
          echo "scenarios=[$(echo $input | tr ',' ',')]" >> "$GITHUB_OUTPUT"
        fi

  perf-test:
    needs: setup
    runs-on: [self-hosted, gpu]
    timeout-minutes: 180
    strategy:
      fail-fast: false
      matrix:
        scenario: ${{ fromJson(needs.setup.outputs.scenarios) }}
    steps:
    - uses: actions/checkout@v4

    - name: Configure kubectl
      run: |
        echo "${{ secrets.KUBECONFIG }}" | base64 -d > /tmp/kubeconfig
        export KUBECONFIG=/tmp/kubeconfig
        kubectl cluster-info
        kubectl get nodes -l nvidia.com/gpu.present=true

    - name: Install dependencies
      run: |
        sudo apt-get update && sudo apt-get install -y jq bc
        # Verify DRA driver is installed
        kubectl get crd computedomains.gpu.resource.nvidia.com

    - name: Setup monitoring
      run: |
        kubectl apply -f prometheus/cd-perf-rules.yaml || true
        kubectl apply -f prometheus/cd-perf-servicemonitor.yaml || true

    - name: Run scenario ${{ matrix.scenario }}
      run: |
        chmod +x tests/*.sh
        export KUBECONFIG=/tmp/kubeconfig
        mkdir -p "$CD_PERF_RESULTS"

        test_script="tests/test_$(printf '%02d' ${{ matrix.scenario }})_*.sh"
        script=$(ls $test_script 2>/dev/null | head -1)

        if [ -z "$script" ]; then
          echo "No script found for scenario ${{ matrix.scenario }}"
          exit 1
        fi

        echo "Running: $script"
        bash "$script" 2>&1 | tee "$CD_PERF_RESULTS/scenario_${{ matrix.scenario }}.log"
      timeout-minutes: 30

    - name: Collect results
      if: always()
      run: |
        # 收集 controller 日志
        kubectl logs -n nvidia-system -l app=nvidia-dra-controller \
          --tail=1000 > "$CD_PERF_RESULTS/controller_${{ matrix.scenario }}.log" 2>/dev/null || true

        # 收集事件
        kubectl get events -n cd-perf-test --sort-by=.lastTimestamp \
          > "$CD_PERF_RESULTS/events_${{ matrix.scenario }}.log" 2>/dev/null || true

    - name: Upload results
      if: always()
      uses: actions/upload-artifact@v4
      with:
        name: perf-results-scenario-${{ matrix.scenario }}
        path: ${{ env.CD_PERF_RESULTS }}/
        retention-days: 30

  report:
    needs: perf-test
    if: always()
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: Download all results
      uses: actions/download-artifact@v4
      with:
        path: all-results/
        pattern: perf-results-scenario-*
        merge-multiple: true

    - name: Generate report
      run: |
        echo "# ComputeDomain Performance Report" > report.md
        echo "Run: ${{ github.run_id }} | Date: $(date -Iseconds)" >> report.md
        echo "" >> report.md

        echo "## Results Summary" >> report.md
        echo '```' >> report.md
        cat all-results/all_results.csv 2>/dev/null || echo "No results found"
        echo '```' >> report.md

        echo "" >> report.md
        echo "## Per-Scenario Summary" >> report.md
        for f in all-results/*/summary.json; do
          if [ -f "$f" ]; then
            scenario=$(basename $(dirname "$f"))
            echo "### ${scenario}" >> report.md
            echo '```json' >> report.md
            cat "$f" >> report.md
            echo '```' >> report.md
          fi
        done

        cat report.md

    - name: Check baselines
      run: |
        exit_code=0

        check_baseline() {
          local metric="$1" threshold="$2" file="$3"
          if [ -f "$file" ]; then
            p95=$(jq -r "select(.metric==\"${metric}\") | .p95" "$file" 2>/dev/null)
            if [ -n "$p95" ] && [ "$p95" != "null" ]; then
              if [ "$p95" -gt "$threshold" ]; then
                echo "FAIL: ${metric} p95=${p95}ms > ${threshold}ms"
                exit_code=1
              else
                echo "PASS: ${metric} p95=${p95}ms <= ${threshold}ms"
              fi
            fi
          fi
        }

        for summary in all-results/*/summary.json; do
          [ -f "$summary" ] || continue
          check_baseline "single_cd_ready" 30000 "$summary"
          check_baseline "daemon_pod_startup" 15000 "$summary"
          check_baseline "single_channel_inject" 20000 "$summary"
          check_baseline "single_cascade_delete" 30000 "$summary"
        done

        exit $exit_code

    - name: Post comment on PR
      if: github.event_name == 'pull_request'
      uses: marocchino/sticky-pull-request-comment@v2
      with:
        path: report.md
```

---

## 8. 基线目标汇总

| # | 场景 | 关键指标 | p95 目标 | 硬上限 |
|---|------|----------|----------|--------|
| 1 | CD Creation-to-Ready | 单 CD (2 nodes) | < 30s | 60s |
| 1 | CD Creation-to-Ready | 批量 10 CD | < 90s | 120s |
| 2 | 并发吞吐量 | 50 并发成功率 | > 95% | — |
| 3 | IMEX Daemon 启动 | Pod startup | < 15s | 30s |
| 3 | IMEX Daemon 启动 | 全节点就绪 (10) | < 45s | 90s |
| 4 | Channel 注入 | 端到端可用 | < 20s | 45s |
| 4 | Channel 注入 | 同节点 flock 串行 | < 25s | 45s |
| 5 | 节点故障 Failover | 故障检测 | < 4s | 10s |
| 5 | 节点故障 Failover | 恢复到 Ready | < 30s | 60s |
| 6 | Daemon 重启 | Pod 恢复 | < 5s | 15s |
| 6 | Daemon 重启 | CD 状态恢复 | < 10s | 30s |
| 7 | 大规模 Reconcile | 100 CD 全 Ready | < 15min | 30min |
| 7 | 大规模 Reconcile | 单次 reconcile p99 | < 500ms | 2s |
| 7 | 大规模 Reconcile | Resync 期间降级 | 0 | 0 |
| 8 | Clique 生命周期 | 创建 (per node) | < 2s | 5s |
| 8 | Clique 生命周期 | Gap-filling | < 5s | 15s |
| 8 | Clique 生命周期 | 级联清理 | < 10s | 30s |
| 9 | 升降级中断 | Controller 重启 | < 30s | 60s |
| 9 | 升降级中断 | 升级中新建 CD | < 60s | 120s |
| 10 | 资源争抢 | 竞争下 Ready | < 60s | 120s |
| 10 | 资源争抢 | 资源耗尽检测 | < 5s | 15s |
| 11 | 级联删除 | 单 CD (2 nodes) | < 30s | 60s |
| 11 | 级联删除 | 批量 10 CD | < 90s | 180s |
| 11 | 级联删除 | 残留资源 | 0 | 0 |
| 12 | nodes.cfg 传播 | 节点加入/移除更新 | < 10s | 30s |
| 12 | nodes.cfg 传播 | 全节点一致性 | < 15s | 30s |

---

**文件结构：**

```
cd-perf-tests/
├── common.sh
├── templates/
│   └── compute-domain-basic.yaml
├── tests/
│   ├── test_01_creation_to_ready.sh
│   ├── test_02_concurrent_throughput.sh
│   ├── test_03_imex_daemon_startup.sh
│   ├── test_04_channel_injection.sh
│   ├── test_05_node_failover.sh
│   ├── test_06_daemon_restart.sh
│   ├── test_07_large_scale_reconcile.sh
│   ├── test_08_clique_lifecycle.sh
│   ├── test_09_upgrade_disruption.sh
│   ├── test_10_resource_contention.sh
│   ├── test_11_cascade_delete.sh
│   └── test_12_nodes_cfg_propagation.sh
├── kube-burner-config.yaml
├── kube-burner-metrics.yaml
├── prometheus/
│   ├── cd-perf-rules.yaml
│   └── cd-perf-servicemonitor.yaml
├── grafana/
│   └── cd-perf-dashboard.json
├── .github/workflows/
│   └── cd-perf-test.yaml
└── results/
    └── <timestamp>/
        ├── all_results.csv
        └── <test_name>/
            ├── results.csv
            └── summary.json
```
