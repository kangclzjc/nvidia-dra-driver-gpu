# DRA ComputeDomain 性能测试 — 完整复现指南

> **给 AI 的提示：** 这份文档包含了完整的复现步骤和所有已知坑点。请严格按照文档操作，特别注意 "⚠️ 关键修复" 和 "⚠️ 已知问题" 章节。

## 概述

在没有 GPU 硬件的环境下，使用 kind/k3s 集群 + fake node + 真实 DRA driver binary (dry-run) 测试 ComputeDomain 端到端性能。

### 架构

```
┌─────────────────────────────────────────────────────────┐
│  kind 或 k3s cluster (K8s 1.34+ with DRA enabled)      │
│                                                          │
│  control-plane (apiserver + etcd + scheduler)            │
│  real worker node (或 k3s 单节点同时充当 CP+worker)     │
│  ├── compute-domain-controller (Deployment)              │
│  ├── N × fake-cd-kubelet-plugin pods (per fake node)    │
│  └── N × compute-domain-daemon --dry-run pods           │
│  └── N × compute-domain-daemon --dry-run pods           │
│                                                          │
│  1000 × fake Node objects (API only, no kubelet)        │
│  1000 × ResourceSlice (由 fake plugin 通过 DRA API 发布) │
└─────────────────────────────────────────────────────────┘
```

### 组件说明

| 组件 | 来源 | 作用 |
|------|------|------|
| `compute-domain-controller` | k8s-dra-driver repo 编译 | 管理 CD 生命周期，创建 DaemonSet |
| `compute-domain-daemon --dry-run` | k8s-dra-driver repo 编译 | 模拟真实 daemon，注册 node 到 CD status |
| `fake-cd-kubelet-plugin` | k8s-dra-driver repo 编译 | 通过 DRA API 为 fake node 发布 ResourceSlice |

---

## 前置要求

- Linux 机器（推荐 GCP/AWS VM）
- Docker
- kind (v0.27+)
- kubectl
- Go 1.25+ (编译 driver)
- 资源需求参考:

| 规模 | 推荐 vCPU | 推荐内存 |
|------|----------|---------|
| 2 rack (36 node) | 4+ | 16 GB |
| 10 rack (180 node) | 8+ | 32 GB |
| 30 rack (540 node) | 16+ | 64 GB |
| 56 rack (1008 node) | 32+ | 128 GB |

瓶颈主要是 **apiserver CPU**（daemon 每 2s sync 一次 CD status）。

---

## Step 1: 创建 kind 集群

```bash
# 安装 kind (如果没有)
go install sigs.k8s.io/kind@latest

# 创建集群
kind create cluster --config dra-perf-test/kind-config.yaml
```

`kind-config.yaml` 关键配置:
- `DynamicResourceAllocation: true` — 开启 DRA
- `max-requests-inflight: 800` — 提高 apiserver 并发
- `max-pods: 600` — worker 允许更多 pod (根据需要调大)
- etcd quota 8GB — 支持大量对象

---

## Step 2: 创建 fake Node 对象

```bash
# 创建 1000 个 fake node (56 rack × 18 node/rack)
bash dra-perf-test/scripts/create-fake-nodes.sh 1000
```

Fake node 的特点:
- 有 `node.kubernetes.io/fake=true` label 和 taint
- Status 被 patch 为 Ready
- 有 topology label `topology.kubernetes.io/rack`
- 没有 kubelet，pod 不能真正调度上去

---

## Step 3: 编译 DRA driver binary

```bash
# Clone k8s-dra-driver repo (需要在 repo 内)
cd k8s-dra-driver

# 编译三个组件
CGO_ENABLED=0 go build -o /tmp/compute-domain-daemon ./cmd/compute-domain-daemon/
CGO_ENABLED=0 go build -o /tmp/compute-domain-controller ./cmd/compute-domain-controller/
CGO_ENABLED=0 go build -o /tmp/fake-cd-kubelet-plugin ./cmd/fake-cd-kubelet-plugin/
```

---

## Step 4: 构建 Docker image 并加载到 kind

```bash
# Daemon image
cat > /tmp/Dockerfile.daemon <<'EOF'
FROM debian:bookworm-slim
COPY compute-domain-daemon /usr/bin/compute-domain-daemon
ENTRYPOINT ["/usr/bin/compute-domain-daemon"]
EOF
docker build -f /tmp/Dockerfile.daemon -t compute-domain-daemon:dry-run /tmp/
kind load docker-image compute-domain-daemon:dry-run --name dra-perf

# Controller image
cat > /tmp/Dockerfile.controller <<'EOF'
FROM debian:bookworm-slim
COPY compute-domain-controller /usr/bin/compute-domain-controller
ENTRYPOINT ["/usr/bin/compute-domain-controller"]
EOF
docker build -f /tmp/Dockerfile.controller -t compute-domain-controller:perf /tmp/
kind load docker-image compute-domain-controller:perf --name dra-perf

# Fake kubelet plugin image
cat > /tmp/Dockerfile.fakeplugin <<'EOF'
FROM debian:bookworm-slim
COPY fake-cd-kubelet-plugin /usr/bin/fake-cd-kubelet-plugin
ENTRYPOINT ["/usr/bin/fake-cd-kubelet-plugin"]
EOF
docker build -f /tmp/Dockerfile.fakeplugin -t fake-cd-kubelet-plugin:perf /tmp/
kind load docker-image fake-cd-kubelet-plugin:perf --name dra-perf
```

---

## Step 5: 安装 CRD 和部署 Controller

```bash
CTX="--context kind-dra-perf"

# 安装 CRD
kubectl $CTX apply -f k8s-dra-driver/deployments/helm/nvidia-dra-driver-gpu/crds/resource.nvidia.com_computedomains.yaml
kubectl $CTX apply -f k8s-dra-driver/deployments/helm/nvidia-dra-driver-gpu/crds/resource.nvidia.com_computedomaincliques.yaml

# 创建 namespace 和 RBAC
kubectl $CTX create namespace nvidia-dra-driver
kubectl $CTX -n nvidia-dra-driver create serviceaccount nvidia-dra-driver-gpu-controller
kubectl $CTX -n nvidia-dra-driver create serviceaccount compute-domain-daemon-service-account
kubectl $CTX create clusterrolebinding nvidia-controller-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=nvidia-dra-driver:nvidia-dra-driver-gpu-controller
kubectl $CTX create clusterrolebinding nvidia-daemon-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=nvidia-dra-driver:compute-domain-daemon-service-account

# 创建 controller templates ConfigMap
kubectl $CTX -n nvidia-dra-driver create configmap controller-templates \
  --from-file=k8s-dra-driver/cmd/compute-domain-controller/templates/

# 部署 controller (注意 nodeAffinity 避免调度到 fake node)
kubectl $CTX -n nvidia-dra-driver apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: compute-domain-controller
  namespace: nvidia-dra-driver
spec:
  replicas: 1
  selector:
    matchLabels:
      app: compute-domain-controller
  template:
    metadata:
      labels:
        app: compute-domain-controller
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
      serviceAccountName: nvidia-dra-driver-gpu-controller
      containers:
      - name: controller
        image: compute-domain-controller:perf
        imagePullPolicy: Never
        command:
          - compute-domain-controller
          - --image-name=compute-domain-daemon:dry-run
          - --max-nodes-per-imex-domain=18
          - -v=2
        volumeMounts:
        - name: templates
          mountPath: /templates
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
      volumes:
      - name: templates
        configMap:
          name: controller-templates
EOF

# 等待 controller Ready
kubectl $CTX -n nvidia-dra-driver rollout status deployment/compute-domain-controller --timeout=60s
```

---

## Step 6: 运行端到端测试

### 方式 A: 单 rack 测试 (推荐先跑)

```bash
bash dra-perf-test/scripts/test-e2e-rack-v3.sh all
```

这会:
1. 部署 18 个 plugin pod (预热，不计时)
2. 跑 3 轮 CD lifecycle benchmark
3. 清理

### 方式 B: 多 rack 串行 vs 并行对比

```bash
bash dra-perf-test/scripts/test-2rack-serial-vs-parallel.sh
```

### 方式 C: 自定义规模

参考脚本模板手动调整 rack 数量。核心流程:

```bash
# 1. 部署 plugin (每个 fake node 一个，基础设施层，不计时)
# 2. 创建 CD
# 3. 删除 controller 自动创建的 DaemonSet (!!重要)
# 4. 部署 daemon pod (带正确 label 和 fieldRef)
# 5. 等待 CD Ready
# 6. 清理
```

---

## ⚠️ 三个关键修复 (必须遵守)

不遵守这三点，CD 永远不会达到 Ready 状态:

### Fix 1: Daemon pod 必须带 CD label

```yaml
metadata:
  labels:
    resource.nvidia.com/computeDomain: "<CD-UUID>"
```

**原因:** Controller 的 CDStatusSync 通过这个 label 查找 daemon pod。没有 label → controller 认为无 daemon → 清空 CD status nodes 列表 → 覆盖 daemon 写入的 Ready 状态。

### Fix 2: 必须删除 controller 自动创建的 DaemonSet

```bash
CD_UUID=$(kubectl -n nvidia-dra-driver get computedomain <CD_NAME> -o jsonpath='{.metadata.uid}')
kubectl -n nvidia-dra-driver delete daemonset "computedomain-daemon-${CD_UUID}" --wait=false
```

**原因:** Controller 创建 CD 时会自动创建一个 DaemonSet，使用 `matchLabels: resource.nvidia.com/computeDomain: <CD-UUID>` 作为 selector。如果手动创建的 daemon pod 带同样的 label，DaemonSet controller 会把它当作"多余 pod"删掉（因为 DaemonSet DESIRED=0，fake node 匹配不到 nodeSelector）。

注意: 删除后 controller 会重建 DaemonSet，所以在部署 daemon 前可能需要删两次。

### Fix 3: Daemon 必须使用真实 Pod IP

```yaml
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
```

**不要**用 `--pod-ip=10.0.1.x` 传硬编码假 IP。

**原因:** Controller 的 CDStatusSync 用 `pod.Status.PodIP` 和 CD status 中 daemon 注册的 `node.IPAddress` 做匹配，来判断 node 是否 stale。如果 daemon 报的 IP 和 pod 真实 IP 不同 → 被认为 stale → 被过滤掉 → `total nodes=0`。

---

## Daemon Pod 完整模板

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: daemon-<NODE_NAME>
  namespace: nvidia-dra-driver
  labels:
    app: daemon-dry-run
    role: daemon
    resource.nvidia.com/computeDomain: "<CD_UUID>"   # Fix 1
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
    env:                                                # Fix 3
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
      - --node-name=<FAKE_NODE_NAME>
      - --compute-domain-name=<CD_NAME>
      - --compute-domain-namespace=nvidia-dra-driver
      - --compute-domain-uuid=<CD_UUID>
      - --cliqueid=<CD_UUID>
      - --max-nodes-per-imex-domain=18
      - -v=2
      - run
    resources:
      requests:
        memory: "16Mi"
        cpu: "5m"
      limits:
        memory: "64Mi"
```

---

## Plugin Pod 完整模板

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: plugin-<NODE_NAME>
  namespace: nvidia-dra-driver
  labels:
    app: fake-kubelet-plugin
    role: plugin
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
      - --node-name=<FAKE_NODE_NAME>
      - --num-channels=1
      - --cd-name=<CD_NAME>
      - --cd-namespace=nvidia-dra-driver
      - --cd-uid=<CD_UUID>
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
```

Plugin 需要 initContainer 创建 socket 目录，否则会 `bind: no such file or directory` 报错。

---

## 每组件资源消耗实测

| 组件 | 内存 | CPU (idle) |
|------|------|-----------|
| daemon dry-run | ~10.5 MB | 2-3% |
| fake-kubelet-plugin | ~10-15 MB | <1% |
| controller | ~23 MB | <1% |
| apiserver (baseline) | ~800 MB | 5% |
| apiserver (36 daemon sync) | ~2 GB | 50-90% |
| etcd | ~200 MB | 5-30% |

---

## 性能基线数据 (4 vCPU / 16 GB)

### 单 rack (18 node) E2E

| 指标 | 值 |
|------|-----|
| CD 创建 | ~2.5s |
| 18 daemon 提交 (串行 kubectl) | ~10s |
| 18 daemon Running | ~15s |
| 全部 Ready | **~20s** |
| 清理 | ~8s |

### 单 daemon 时间线

```
T+0ms      kubectl create
T+376ms    apiserver 返回
T+500ms    Scheduled
T+800ms    Image pulled (already present)
T+1000ms   Container created
T+1300ms   Container started
T+1700ms   Daemon 初始化完成
T+1900ms   首次注册到 CD status
T+2300ms   Node status → Ready
```

### 2 rack (36 node) E2E

| 指标 | 串行 | 并行 |
|------|------|------|
| 36 daemon 提交 | 19.7s | 8.1s |
| 36 daemon Running | 24.3s | 28.8s |
| 2 CD 全 Ready | **33.5s** | **36.5s** |

### 瓶颈分析

主要瓶颈是 **apiserver CPU**。每个 daemon 每 2s 做一次 CD status update:
- 36 daemon = 18 req/s → 4 vCPU 的 apiserver 用掉 ~90% CPU
- 扩到更多 rack 需要更多 CPU

---

## 扩展到更大规模

1. 调大 VM CPU (最直接)
2. 调大 kind-config.yaml 中 max-pods
3. 脚本中 RACKS 数组加更多 rack
4. 如果 pod 数 >600，需要修改 worker 的 `--max-pods`

```bash
# 重建集群时修改 kind-config.yaml:
# max-pods: "1200"  # 或更大
```

---

## 文件清单

```
dra-perf-test/
├── README.md                          # 本文件
├── kind-config.yaml                   # kind 集群配置
├── scripts/
│   ├── create-fake-nodes.sh           # 创建 fake node 对象
│   ├── create-resource-slices.sh      # 静态创建 RS (已被 plugin 替代)
│   ├── test-e2e-rack-v3.sh           # 单 rack E2E 测试 - kind (推荐)
│   ├── test-2rack-serial-vs-parallel.sh # 2 rack 串行 vs 并行对比 - kind
│   ├── test-k3s-2rack.sh             # 2 rack E2E 测试 - k3s
│   └── test-cd-full.sh               # controller-only 测试 (无 daemon)
└── results/
    ├── REPORT.md                      # 初版结果 (controller only)
    └── REPORT-v2.md                   # 完整 E2E 结果
```

---

## k3s 部署指南（替代 kind）

k3s 比 kind 更轻量（无 Docker-in-Docker），容器启动速度快 2-3x。

### 启动 k3s

```bash
# 安装 k3s (如果没有)
curl -sfL https://get.k3s.io | sh -

# 或者带 DRA feature gate 启动
sudo k3s server \
  --disable traefik \
  --disable servicelb \
  --disable local-storage \
  --kube-apiserver-arg="feature-gates=DynamicResourceAllocation=true" \
  --kube-apiserver-arg="runtime-config=resource.k8s.io/v1beta1=true" \
  --kube-scheduler-arg="feature-gates=DynamicResourceAllocation=true" \
  --kube-controller-manager-arg="feature-gates=DynamicResourceAllocation=true" \
  --kubelet-arg="feature-gates=DynamicResourceAllocation=true" \
  --kubelet-arg="max-pods=600" \
  --write-kubeconfig-mode=644
```

### k3s 特殊注意事项

**1. 导入 image 到 k3s containerd（不是 docker）：**
```bash
docker save compute-domain-daemon:dry-run | sudo k3s ctr images import -
docker save compute-domain-controller:perf | sudo k3s ctr images import -
docker save fake-cd-kubelet-plugin:perf | sudo k3s ctr images import -
docker save debian:bookworm-slim | sudo k3s ctr images import -  # initContainer 需要!
```

**2. kubeconfig：**
```bash
sudo cp /etc/rancher/k3s/k3s.yaml /tmp/k3s-kubeconfig
sudo chmod 644 /tmp/k3s-kubeconfig
export KUBECONFIG=/tmp/k3s-kubeconfig
```

**3. 所有 pod 必须用 `nodeName` 指定 real node：**

k3s 是单节点（同时是 CP + worker）。如果只用 `tolerations: [{operator: Exists}]`，scheduler 会把 pod 调度到 fake node 上（fake node 的 taint 被 tolerate 了）。

**必须**在 pod spec 里加：
```yaml
spec:
  nodeName: <REAL_NODE_NAME>   # 用 kubectl get nodes -l '!node.kubernetes.io/fake' 获取
```

或者用 nodeAffinity：
```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node.kubernetes.io/fake
                operator: DoesNotExist
```

kind 里两种都行（有 real worker node），k3s 必须显式指定。

**4. Controller 需要额外 flag：**
```yaml
command:
  - compute-domain-controller
  - --image-name=compute-domain-daemon:dry-run
  - --max-nodes-per-imex-domain=18
  - --log-verbosity-cd-daemon=2   # 必须，否则启动报错
  - -v=2
env:
  - name: POD_NAME                 # 必须
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
```

**5. debian:bookworm-slim image 必须预先导入：**

Plugin pod 的 initContainer 使用 `debian:bookworm-slim` 创建目录。k3s containerd 不会自动从 Docker daemon 拉取——必须显式 pull 或 import。

---

## ⚠️ 已知问题：Write Contention Storm

### 现象

18 个 daemon 同时启动时，CD status 中的 node 全部停在 NotReady，或者在 Ready/NotReady 之间反复跳动。日志中大量 409 Conflict 错误。

### 根因

CD status 是一个 K8s 对象，18 个 daemon + 1 个 controller CDStatusSync **同时写同一个对象**：

```
每次写入改变 resourceVersion → 其他 17 个 writer 全部 409 Conflict → 重试
CDStatusSync 每 2s 用 pod 列表重建整个 nodes 列表 → 覆盖 daemon 的写入
→ daemon 发现 "我不在 CD 里了" → 重新 insert → 又被覆盖 → 无限循环
```

### 影响范围

- **kind (2 node cluster)：** 冲突较少，因为 CP 和 worker 在不同容器有网络延迟，自然分散写入
- **k3s (单节点)：** 冲突严重，所有进程共享 CPU，几乎同时发出 write
- **生产环境：** 通常不会遇到，因为 DaemonSet 渐进式调度，daemon 不会同时启动

### 缓解方案

**方案 1：串行部署 daemon（模拟真实 DaemonSet 行为）：**
```bash
for i in $(seq 1 18); do
  # 创建 daemon pod
  kubectl create -f daemon-pod-$i.yaml
  sleep 2  # 等上一个注册完成再启动下一个
done
```

**方案 2：给 daemon 加启动 jitter（推荐）：**

在 daemon pod command 前加一个随机延迟：
```yaml
command: ["sh", "-c", "sleep $((RANDOM % 10)); exec compute-domain-daemon --dry-run ..."]
```

**方案 3：使用 kind 而不是 k3s：**

kind 的 2 节点架构天然缓解了冲突。推荐用 kind 做性能测试。

---

## kind vs k3s 对比

| | kind | k3s |
|---|---|---|
| 容器启动速度 | 慢（Docker in Docker） | 快（原生 containerd） |
| apiserver 隔离 | 好（独立容器） | 差（共享进程） |
| Write contention | 较轻 | 严重 |
| 资源开销 | 较高（2 个 Docker 容器） | 低（单进程） |
| 推荐场景 | ✅ E2E 性能测试 | ✅ 快速验证 |

**推荐：** 用 kind 做正式性能测试，用 k3s 做快速功能验证。
