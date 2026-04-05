# ComputeDomain 性能测试发现的问题

## Bug 1: CD Status 写覆盖（非 CDClique 路径）

**条件**: `ComputeDomainCliques` feature gate 关闭

**现象**: 节点永远无法稳定在 Ready 状态

**根因**: Controller 的 2s 状态同步（`cdStatusSyncInterval`）用过时的 informer cache 读到空的节点列表，覆盖 daemon 写入的节点信息。多个 daemon + controller 竞争同一个 CD status subresource。

**影响**: 多节点 ComputeDomain 可能永远无法 Ready。

**建议**: 开启 `ComputeDomainCliques` feature gate 可规避。

---

## Bug 2: CDClique cleanupClique() 无条件覆盖

**条件**: `ComputeDomainCliques` feature gate 开启，多 daemon 并发写 CDClique

**现象**: 
- Daemon 写入 `status=Ready` 后被 controller 覆盖回 `NotReady`
- Daemon 注册（append）的条目被 controller 用旧数据覆盖丢失
- 注册数量在 N/18 和 18/18 之间反复波动

**根因**: Controller 的 `cleanupClique()` 即使没有需要删除的过期条目，仍然会把 **整个 daemons 数组用 informer cache 的旧版本替换回去**。

具体流程：
1. Daemon-A 写入 CDClique: `daemons=[...18 个, A.status=Ready]`, resourceVersion=100
2. Controller 的 informer cache 还停留在 resourceVersion=95（只有 15 个 daemon，都是 NotReady）
3. Controller 运行 cleanupClique(): 过滤后仍是 15 个（没有死 pod 需要清理）
4. Controller **无条件写回** 15 个 NotReady 的列表 → 覆盖了 Daemon-A 的 Ready 和另外 3 个 daemon 的注册

**建议修复**:
```go
// 当前代码（有问题）：
newClique.Daemons = updatedDaemons  // 总是替换
client.Update(ctx, newClique)

// 建议修复：没有变化就不写
if len(removedNodes) == 0 {
    return  // 没删掉任何条目，不要覆盖
}
```

或者更安全的做法：cleanupClique() 在执行前应该用 `client.Get()` 读最新版本而不是 informer cache。

**实测数据**:
- 1 rack (18 daemons, 真实 kind 节点): Ready 正常（竞争较少）
- 2 racks (36 daemons, 单节点模拟): 注册反复达到 36/36，但 Ready 始终 0
- 4 racks (72 daemons, 单节点模拟): 更严重，注册波动大

**说明**: 单节点模拟（所有 daemon 在同一 node）会放大竞争，因为没有网络延迟做天然 jitter。真实多节点场景下竞争较轻，但在大规模（56+ racks）场景下仍可能出现。
