# NVIDIA DRA Driver 大规模性能测试方案

> 基于 nvidia-dra-driver-gpu v26.4.0-dev 代码分析
> 由 Claude Code planner 模式深度分析项目代码后生成

## 1. 架构理解与测试目标

### 1.1 五大组件总览

| 组件 | 驱动名称 | 角色 | 关键性能路径 |
|------|----------|------|-------------|
| `gpu-kubelet-plugin` | `gpu.nvidia.com` | 节点级 GPU 资源发布与分配 | `NodePrepareResources`/`NodeUnprepareResources` gRPC, ResourceSlice 发布, CDI 生成, Checkpoint I/O |
| `compute-domain-kubelet-plugin` | `compute-domain.nvidia.com` | 节点级 ComputeDomain 资源管理 | Channel/Daemon 设备分配, CDI 生成 |
| `compute-domain-controller` | `compute-domain.nvidia.com` | 集群级编排控制器 | Work queue 处理, ComputeDomain reconcile, DaemonSet 管理 |
| `compute-domain-daemon` | - | 节点级 IMEX 守护进程 | IMEX 进程生命周期, nodes.cfg 更新, 故障恢复 |
| `webhook` | - | ResourceClaim 参数验证 | AdmissionReview 延迟, TLS 开销 |

### 1.2 关键性能指标 (KPI)

| 指标 | 目标值 (P99) | 说明 |
|------|-------------|------|
| ResourceClaim 创建到分配延迟 | < 5s | 含调度器决策 |
| NodePrepareResources 延迟 | < 2s | kubelet plugin gRPC |
| NodeUnprepareResources 延迟 | < 1s | 资源释放 |
| ResourceSlice 发布延迟 | < 3s | 设备信息上报 |
| ComputeDomain Ready 延迟 | < 30s | 全部节点 Ready |
| Webhook 验证延迟 | < 50ms | 准入控制 |
| 控制器 reconcile 延迟 | < 500ms | work queue 处理 |
| 驱动重启恢复时间 | < 15s | 含 checkpoint 恢复 |

### 1.3 代码分析发现的性能瓶颈点

1. **文件锁串行化** (`pkg/flock/`): `NodePrepareResources`/`NodeUnprepareResources` 使用 `syscall.Flock(LOCK_EX)` 串行化，并发请求会排队
2. **速率限制器参数**:
   - gpu-kubelet-plugin Prepare/Unprepare: 指数回退 250ms-3s + 令牌桶 5/s burst 10
   - compute-domain-daemon: 指数回退 5ms-6s + 0.5 jitter
   - controller: K8s 标准控制器限速器
3. **CDI 规范生成**: 依赖 `nvidia-container-toolkit` 的多次文件操作
4. **Informer resync**: 10 分钟 resync 周期可能导致状态延迟
5. **MIG 重配置**: DynamicMIG 需要与 NVIDIA driver 交互，延迟可达数秒

---

详细测试场景和代码模板请参见完整输出文档。
