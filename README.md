# zcode-agent-squad

一套 ZCode 用户级工作流配置：主会话当架构师，一群快模型子 agent 并行干活，独立 reviewer 把关质量——**没有过 review 的东西不端给用户**。

为"单线慢、并发高"的快模型设计（如 GLM-5.3-Flash）：既然一个子 agent 跑不快，就把并发吃满——饱和拆分 + 扇出派发 + 后台流水线，用并行换吞吐。

## 三个角色 + 一个门禁

| 角色 | 干什么 | 工具约束 |
|---|---|---|
| `coder` | 写代码、改文件、修 bug、补测试；交付前必须过自审清单 | 无 Agent 工具（不会套娃） |
| `watcher` | 蹲守实验训练、长命令、远程 ssh、日志轮询、GPU 健康 | 无 Agent 工具 |
| `reviewer` | 文件改动的独立验收：验收标准逐条核对 → 审 diff → 复跑验证，输出 verdict | 只读（无 Write/Edit） |

```
用户 ──► 主会话（拆任务、写可检查的验收标准、终审、汇总）
            │
            ├─► coder ×N（并行，同一文件的改动归同一个 coder）
            │      └─ 自审：验收标准逐条对照 + 重读 diff + 真跑验证
            ├─► watcher ×N（并行蹲守）
            │
            └─► reviewer（改动交付前必过）
                   ├─ pass / pass-with-notes ──► 主会话终审 ──► 答复用户
                   └─ fail ──► 问题清单打回原 agent（最多 2 轮，仍 fail 升级用户）
```

review 的起点是**派发指令里的验收标准**（跑什么命令、看什么行为、diff 应长什么样）——写不出验收标准的任务先拆清楚再派。这让快模型子 agent 照单核对，不需要自己猜"从哪开始 review"。

## 快速开始

```bash
git clone <本仓库地址>
cd zcode-agent-squad
./scripts/install.sh        # Git Bash / Linux / macOS
# 或：pwsh -File scripts/install.ps1    # Windows PowerShell 5.1+ / pwsh 7

# 自定义模型与并发（默认 GLM-5.3 / GLM-5.3-Flash / 50）：
./scripts/install.sh --strong GLM-5.3 --fast GLM-5.3-Flash --concurrency 50
```

安装脚本做三件事（幂等，可用 `--uninstall` 干净移除，不影响你 AGENTS.md 里的其他内容）：

1. 拷贝 `agents/{coder,watcher,reviewer}.md` 到 `~/.zcode/agents/`（frontmatter 的 `model:` 按你的 `--fast` 参数写入；覆盖前有差异会备份 `.bak`）
2. 把 `rules/AGENTS.snippet.md` 按参数渲染后，以标记块形式合并进 `~/.zcode/AGENTS.md`（块外内容原样保留，重复执行=升级替换）
3. 打印后续手动步骤

**还差一步（手动）**：ZCode 桌面端 Settings → Subagents 里，把内置 `general-purpose` 与 `Explore` 的模型切到你的快模型（或备份后编辑 `~/.zcode/v2/agents-state.json` 的 `builtInModelOverrides`）。这样全链路子任务都跑快模型。改完**新会话生效**。

## 注入的规则做了什么

- **主力模型（贵）**：只做规划、拆任务、终审、答复用户；实现/蹲守/调研整段外包。
- **快模型（便宜量大）**：铁律是**吃满并发**——饱和拆分到接近并发上限（扇出而非循环：N 个对象 = N 个子 agent）、后台流水线不空等、单波重 agent 约 20 个分波防顶爆；同一文件的改动归同一个子 agent 避免写冲突。
- **防套娃**：子 agent 只许一层。`coder`/`watcher`/`reviewer`/`Explore` 工具列表里没有 Agent，天然不会嵌套；唯一全工具的 `general-purpose`，派它时指令必须写明"不得再派发任何子 agent"。
- **Review 门禁**：凡子 agent 改了文件，答复用户前必须过 `reviewer` 独立验收；fail 打回重做，最多 2 轮，仍 fail 升级用户。轻量豁免：一行级小改、纯格式、调研/蹲守类。

深度说明见 [docs/workflow.md](docs/workflow.md)。

## 设计决策（为什么这样而不是那样）

- **reviewer 只读但保留 Bash**：复跑测试是 review 的核心价值；不给 Write/Edit 降低越界改动的便利性，配合系统提示纪律"只读不改，发现问题走问题清单"。
- **打回上限 2 轮**：fail→重做→复审 的循环没有上限会烧穿 token；两轮修不好通常是任务定义有问题，该升级用户而不是继续循环。
- **自审（第一道）+ 独立 review（第二道）**：coder 的自审清单从验收标准逐条对照开始，把"不知道从哪 review"变成照单执行；reviewer 独立于执行者，负责抓谎报、漏报、越界改动。
- **修改已有 agent 定义即时生效；新增 agent 类型要新会话**（实测结论）：ZCode 在派发时读取 agent 定义文件，所以打磨 coder.md 立刻可见；但会话可用的类型列表在会话启动时快照，新增 reviewer 必须开新会话。

## 自定义

- **机器坑位**：往 `agents/coder.md` 的"工作方式"里加你本机的事项（示例：`Windows + Git Bash 的 python 可能被 Anaconda shim 劫持，报错先怀疑环境`），重新 install 或直接改 `~/.zcode/agents/coder.md`（注意后者会在升级时被仓库版覆盖）。
- **并发数与模型名**：都是 install 参数，AGENTS.md 标记块内会相应渲染。
- **豁免粒度**：觉得 review 门禁太重，改 `rules/AGENTS.snippet.md` 里的豁免清单后重跑 install。

## 上线前实测记录

2026-09-11，本机（Windows + Git Bash，GLM-5.3 主会话 + GLM-5.3-Flash 子 agent）：

- 派 coder 做带明确验收标准的小任务：四节汇报（改动清单/验证结果/Review 记录/假设与未尽事项）齐全，自审逐条给证据 ✓
- 新会话派 reviewer：验收标准核对表 + verdict 输出符合定义 ✓（详见 docs/workflow.md 的实测记录）
- install.sh / install.ps1 双平台沙箱：全新安装、幂等重装（含参数变更）、块外内容保留、卸载、备份、特殊字符模型值，全部通过；期间发现并修复 Git Bash bash 5.2 `patsub_replacement` 导致 `&` 展开的真 bug，以及 snippet 自带标记行会与脚本包裹产生双层标记的真 bug ✓
- 全流程 dogfooding：install 脚本本身由 coder 实现（含一次打回补占位符替换），再由 reviewer 独立审计——verdict **pass-with-notes**（7 条验收标准全过、无 blocker、复跑双平台测试矩阵、复核声称的修复属实）后才入库 ✓

## License

[MIT](LICENSE)
