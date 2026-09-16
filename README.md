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

**模型引用写完整限定格式**：`--fast` 的值会写进子 agent frontmatter 的 `model:`，建议直接传 `<providerId>/<modelId>`（providerId 是 `~/.zcode/v2/config.json` 里 provider 映射的 key）——裸模型 ID（如 `GLM-5.3-Flash`）的解析会随会话抖动，失败时**静默回退到账号默认模型**（实测全量审计 312 个子 agent，103 个跑成了非预期的贵模型，详见 [docs/workflow.md](docs/workflow.md) 的机制实测结论）。最稳的配置途径仍是桌面端 Settings → Subagents 界面选择。

安装脚本做四件事（幂等，可用 `--uninstall` 干净移除，不影响你 AGENTS.md 里的其他内容；**已注册的模型切换计划任务不会被自动删除**，卸载时若发现生成的任务 XML 仍在，会提示手动 `schtasks /delete`）：

1. 拷贝 `agents/{coder,watcher,reviewer}.md` 到 `~/.zcode/agents/`（frontmatter 的 `model:` 按你的 `--fast` 参数写入；覆盖前有差异会备份 `.bak`）
2. 把 `rules/AGENTS.snippet.md` 按参数渲染后，以标记块形式合并进 `~/.zcode/AGENTS.md`（块外内容原样保留，重复执行=升级替换）
3. 拷贝 `scripts/model_switch.py` 到 `~/.zcode/scripts/`（时段路由用，见下文进阶节；差异先备份 `.bak`）
4. 打印后续手动步骤

**还差一步（手动）**：ZCode 桌面端 Settings → Subagents 里，把内置 `general-purpose` 与 `Explore` 的模型切到你的快模型（或备份后编辑 `~/.zcode/v2/agents-state.json` 的 `builtInModelOverrides`，覆盖值格式为 `custom:<providerId>:<modelId>`）。这样全链路子任务都跑快模型。改完**新会话生效**。

## 注入的规则做了什么

- **主力模型（贵）**：只做规划、拆任务、终审、答复用户；实现/蹲守/调研整段外包。
- **快模型（便宜量大）**：铁律是**吃满并发**——饱和拆分到接近并发上限、按**扇出铁律**批量派发（复数对象 = N 个子 agent，触发信号与操作模板见 workflow.md）、后台流水线不空等、单波重 agent 约 20 个分波防顶爆；同一文件的改动归同一个子 agent 避免写冲突。
- **防套娃（最多两层）**：主会话 → 子 agent → 孙 agent 封顶。`coder`/`watcher`/`reviewer`/`Explore` 工具列表里没有 Agent，天然是叶子；唯一全工具的 `general-purpose` 是二层扇出入口——大任务（≥3 个独立单元）授权它再扇出 `coder`/`Explore`/`watcher`（单波 ≤10，收工前自派 reviewer 局部验收），小任务维持"不得再派发"；任何情况禁止派 `general-purpose`、禁止第三层（详见 workflow.md）。
- **Review 门禁**：凡子 agent 改了文件，答复用户前必须过 `reviewer` 独立验收；fail 打回重做，最多 2 轮，仍 fail 升级用户。轻量豁免：一行级小改、纯格式、调研/蹲守类。

深度说明见 [docs/workflow.md](docs/workflow.md)。

## 设计决策（为什么这样而不是那样）

- **reviewer 只读但保留 Bash**：复跑测试是 review 的核心价值；不给 Write/Edit 降低越界改动的便利性，配合系统提示纪律"只读不改，发现问题走问题清单"。
- **打回上限 2 轮**：fail→重做→复审 的循环没有上限会烧穿 token；两轮修不好通常是任务定义有问题，该升级用户而不是继续循环。
- **自审（第一道）+ 独立 review（第二道）**：coder 的自审清单从验收标准逐条对照开始，把"不知道从哪 review"变成照单执行；reviewer 独立于执行者，负责抓谎报、漏报、越界改动。
- **所有 agent 定义改动都要新会话才可靠生效**（实测结论，2026-09-16 修正）：曾测得"定义在派发时读取、改完即时生效"，桌面版 3.12.1 复核将其推翻——agent 定义的 `model` 与 `systemPrompt` 都在**会话启动时快照**，长会话里改定义文件（哪怕换成有效的模型引用）后，同会话派发仍走旧配置。新增 agent 类型要新会话这条依旧成立，两者同因：会话启动时定下配置，之后不再重读。

## 自定义

- **机器坑位**：往 `agents/coder.md` 的"工作方式"里加你本机的事项（示例：`Windows + Git Bash 的 python 可能被 Anaconda shim 劫持，报错先怀疑环境`），重新 install 或直接改 `~/.zcode/agents/coder.md`（注意后者会在升级时被仓库版覆盖）。
- **并发数与模型名**：都是 install 参数，AGENTS.md 标记块内会相应渲染。
- **豁免粒度**：觉得 review 门禁太重，改 `rules/AGENTS.snippet.md` 里的豁免清单后重跑 install。

## 进阶：子 agent 模型按时段路由

按时间段给全部子 agent 换模型——白天用免费无限额度的 API，夜间切到套餐免费时段的模型（反过来也行）。

切换脚本改两处，缺一处就会有 agent 不跟着切：

- `agents/{coder,reviewer,watcher}.md` frontmatter 的 `model:` 行（安装后即 `~/.zcode/agents/` 下的定义）
- `~/.zcode/v2/agents-state.json` 的 `builtInModelOverrides` / `builtInModelSelectionOverrides` / `pluginAgentModelSelectionOverrides` 三段

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `ZCODE_DAY_MODEL_REF` | 无 | 白天模型，完整限定引用 `<providerId>/<modelId>` |
| `ZCODE_NIGHT_MODEL_REF` | 无 | 夜间模型，同上 |
| `ZCODE_DAY_START` | `9` | 白天起始小时 |
| `ZCODE_NIGHT_START` | `23` | 夜间起始小时 |
| `ZCODE_HOME` | `~/.zcode` | 配置目录（脚本与日志都在其下） |

用法（安装脚本会把 `model_switch.py` 装到 `$ZCODE_HOME/scripts/`）：

```bash
export ZCODE_DAY_MODEL_REF="<providerId>/<day-model-id>"
export ZCODE_NIGHT_MODEL_REF="<providerId>/<night-model-id>"

python ~/.zcode/scripts/model_switch.py            # 无参：按当前时间判断切 day 还是 night
python ~/.zcode/scripts/model_switch.py night      # 强制切夜间
python ~/.zcode/scripts/model_switch.py --dry-run  # 试运行，只打印不落盘
```

脚本幂等、原子写；日志在 `$ZCODE_HOME/logs/model-switch.log`。**定时执行读不到交互 shell 里 `export` 的变量**：cron 不读 shell profile，变量要写在 crontab 条目本身（`crontab -e` 顶部加 `ZCODE_DAY_MODEL_REF=...` / `ZCODE_NIGHT_MODEL_REF=...` 行；示例里显式传了 `day`/`night`，只需这两个）；Windows 计划任务则把变量设为用户级环境变量（`setx ZCODE_DAY_MODEL_REF "<providerId>/<modelId>"`，注销重登后生效）。

每天自动切两个触发点：

```powershell
pwsh -File scripts/register_model_switch_task.ps1   # Windows：注册计划任务（StartWhenAvailable）
```

```cron
# Linux / macOS：cron 两条即可（触发时间与 ZCODE_DAY_START / ZCODE_NIGHT_START 对齐）
0 9  * * * python3 "$HOME/.zcode/scripts/model_switch.py" day
0 23 * * * python3 "$HOME/.zcode/scripts/model_switch.py" night
```

**切换只对新会话生效**：agent 定义的 `model` 在会话启动时快照（见"设计决策"），切换点之前开着的会话仍跑旧模型——定时任务把触发点设在换班时刻，长会话要手动重开才会换。

## 上线前实测记录

2026-09-11，本机（Windows + Git Bash，GLM-5.3 主会话 + GLM-5.3-Flash 子 agent）：

- 派 coder 做带明确验收标准的小任务：四节汇报（改动清单/验证结果/Review 记录/假设与未尽事项）齐全，自审逐条给证据 ✓
- 新会话派 reviewer：验收标准核对表 + verdict 输出符合定义 ✓（详见 docs/workflow.md 的实测记录）
- install.sh / install.ps1 双平台沙箱：全新安装、幂等重装（含参数变更）、块外内容保留、卸载、备份、特殊字符模型值，全部通过；期间发现并修复 Git Bash bash 5.2 `patsub_replacement` 导致 `&` 展开的真 bug，以及 snippet 自带标记行会与脚本包裹产生双层标记的真 bug ✓
- 全流程 dogfooding：install 脚本本身由 coder 实现（含一次打回补占位符替换），再由 reviewer 独立审计——verdict **pass-with-notes**（7 条验收标准全过、无 blocker、复跑双平台测试矩阵、复核声称的修复属实）后才入库 ✓

## 更新记录

- **v0.2.0**（2026-09-16）：新增子 agent 模型时段路由（`model_switch.py` + Windows 计划任务注册脚本）；修正"修改 agent 定义即时生效"的旧结论，补模型引用格式与 CLI 无头探针的实测坑。
- **v0.1.0**（2026-09-11）：初版——coder / watcher / reviewer 三角色、Review 门禁、扇出铁律、两层防套娃、双平台安装器。

详见 [CHANGELOG.md](CHANGELOG.md)。

## License

[MIT](LICENSE)
