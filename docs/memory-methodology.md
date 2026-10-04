# 内存采样与口径

WattsUp 从本机系统读取物理总量和运行时页大小，未把 24 GB 或 16 KB 硬编码进采样器。物理内存五股遵守总量守恒。交换另列为磁盘溢出，绝不增加物理内存总量。

## 数据来源

- `hw.memsize`：物理内存字节数。若该调用失败，可回退到 `ProcessInfo.processInfo.physicalMemory`，同时保留原错误。
- `host_page_size(mach_host_self(), …)`：当前系统页大小。
- `host_statistics64(HOST_VM_INFO64)`：物理页计数。
- `vm.swapusage`：`xsw_usage.xsu_used` 与 `xsu_total`，它们已经是字节，无需乘页大小。
- `kern.memorystatus_vm_pressure_level`：系统压力等级。正常 `1`、警告 `2`、严重 `4` 分别显示绿、黄、红；其它值显示未知。
- 压力 sysctl 无法读取时，使用 `DispatchSourceMemoryPressure` 最近观察到的系统事件，并记录事件时间和来源。它不是初始状态查询；尚未收到事件时保留未知，不能默认绿色。合并事件按严重、警告、正常的顺序取最高等级。

所有调用都在用户态执行。无需 root、特权助手、网络或外部依赖。读取失败时交换为 `nil`、压力为 `unknown`，JSON 附带错误。不能把权限失败显示成 0 GB 交换或绿色压力。

## 五股物理内存公式

下面 `p` 是运行系统的字节/页：

| 图中项目 | 公式 | 说明 |
| --- | --- | --- |
| 联动 / wired | `wire_count × p` | 不能换出的物理页。 |
| 压缩 | `compressor_page_count × p` | 压缩器实际占据的物理页。压缩前页数 `total_uncompressed_pages_in_compressor` 仅保存在原始读数中，不能拿来画物理占用。 |
| 文件缓存 | `(external_page_count + purgeable_count) × p` | 文件支持页和可清除匿名页；移入缓存的可清除部分不再留在匿名 App 估计中。 |
| 空闲 | `(free_count − speculative_count) × p` | 推测预读页已计在 `free_count` 内，同时属于文件支持页；从空闲股扣除，防止两股重复计数。 |
| App 及系统余量 | `physicalBytes − wired − compressed − cache − free` | 为确保五股与物理总量守恒而得到的剩余数。界面应明确标注“含系统会计余量”。 |

另保留 `anonymousAppBytes = (internal_page_count − purgeable_count) × p` 与 `accountingAdjustmentBytes = appBytes − anonymousAppBytes`。差额公开在 `--dump-json` 中，避免把未公开的内核会计余量悄悄说成逐进程 App 之和。

`active_count` 与 `inactive_count` 是页队列维度，`external_page_count` 与 `internal_page_count` 是页来源维度，两组不能相加。可清除页是内部页的子集；推测页是空闲页的子集。坏计数、乘法溢出或非 App 分项超过物理总量时不绘制失真的分流，保留错误与原始数据。

## 与活动监视器的关系

分类名称、物理压缩口径以及“系统压力决定绿黄红”的方式以活动监视器的概念为目标。压力不是“已用 / 总量”的比例；使用大量可回收缓存时可以仍为绿色。

Apple 没有把活动监视器的全部实现、App 汇总算法及压力图时间历史作为稳定公开 API 提供。这里采用公开 VM 页计数和系统压力信号，不能声称与活动监视器同一时刻的每个数字或压力曲线完全相同。采样时间差、进程 footprint 口径以及现代系统标签存储/内核保留区域都可能形成差额。WattsUp 显示的 App 股是守恒余额，绝不是所有 App 进程的私有内存相加。

## 为什么有空闲却仍有交换

界面解释句：**交换保留先前换出的冷页面；即使现在有空闲内存，macOS 也通常等页面被访问时再换回，所以空闲与交换可以同时存在。**

交换已经存在不等于此刻压力严重。应结合当前系统压力与交换活动判断，不能仅看交换已用量；v0.1 展示的是交换占用量，尚未绘制换入/换出速率。

## 本机只读验证

2026-10-03 在开发机（Mac mini M6，24 GB，macOS 27）的受限执行环境中，以 Swift 直接调用上述 API：

- `host_page_size` 成功：16,384 字节/页。
- `host_statistics64` 成功：返回结构计数 104。
- `hw.memsize` 与 `ProcessInfo.physicalMemory` 均读到 25,769,803,776 字节，即 **24 GiB / 25.77 GB**。
- 一次原始快照：`free=12090`、`speculative=3683`、`external=294752`、`internal=597784`、`wired=281589`、`compressor=352814`、`purgeable=8023`，单位为页。
- 此次 `physicalPages − (free−speculative + external + internal + wired + compressor) = 37518` 页，即 614,694,912 字节（约 586.22 MiB）。这是此次采样的系统会计差额，不是固定常数，也不被宣称为某一部件的测量值。新 SDK 的 VM 结构含标签存储计数，说明现代系统还有额外物理会计维度；不能只凭此快照断言差额全部来自标签存储。
- `vm.swapusage` 与 `kern.memorystatus_vm_pressure_level` 均返回 `EPERM / Operation not permitted`。这验证了未知/错误路径；尚未证明常规桌面启动的签名 App 能否成功读取它们。需要在实际 App 执行环境下复查。
- 未读取活动监视器 GUI，也没有进行逐项数字对照或压力颜色视觉确认。

## 单位

内部始终存整数 **bytes**；页转换使用系统返回的 `p`。`1 GB = 10^9 bytes`，`1 GiB = 2^30 bytes`。本机常称的“24 GB 内存”在系统里是 24 GiB。图中若使用二进制缩放必须写 `GiB`，避免把 25.77 GB 写成 24 GB 后又按十进制计算。

## 本地原始依据

没有联网或复制第三方实现。以下路径是本机 Xcode SDK 的原始声明：

- `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/mach/vm_statistics.h`：142–173 行，`vm_statistics64` 字段定义；158–163 行明确说明 speculative 已包含在 free_count；170 行说明 compressor_page_count 为实际物理页；172–173 行说明文件支持页与匿名页。
- `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/sys/sysctl.h`：539–546 行，`xsw_usage` 结构。
- `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/dispatch/source.h`：234–256 行，系统内存压力事件及 normal/warn/critical 的 `0x01/0x02/0x04` 标志。

SDK 注释直接证明 speculative/free 包含关系和压缩物理口径。`external` 包含 speculative 的处理也与本机 `vm_stat` 快照的页队列关系一致：`external + internal = active + inactive + speculative`；这是本机观察，不是 SDK 对每种未来系统会计维度的长期承诺。

## 单元测试

`MemoryAccountingTests` 覆盖：物理五股守恒、可清除页不双计、推测页不双计、压缩使用物理页、会计差额公开、交换不影响物理总量、内核压力未知值、合并事件优先级、坏输入/溢出拒绝、JSON 保留未知语义。

2026-10-03 18:48:21（本机时间）运行 SwiftPM 内存测试子集：**10 项通过，0 失败**。首次尝试因默认 ModuleCache 在不可写的用户目录被拒；将 SwiftPM/Clang 模块缓存和 scratch 目录设在 `/private/tmp`，关闭 SwiftPM manifest 额外 sandbox 后成功。这不改变 App 数据源权限，swap/pressure 的 EPERM 仍如上记录（正常启动的 App 能读到，见 README）。
