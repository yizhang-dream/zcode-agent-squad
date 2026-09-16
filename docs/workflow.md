# 工作流深度说明

本文是 [README](../README.md) 的展开版，面向想理解或魔改这套流程的人。

## 1. 角色与契约

### 主会话（不写代码）

职责只有四件：拆任务、写派发指令（含可检查的验收标准）、验收、汇总答复。

派发指令模板：

```
目标：<一句话说清要什么>
涉及文件/路径：<点名文件，缩小摸范围>
验收标准（可检查）：
1. <跑什么命令、期望什么输出>
2. <看什么行为/diff 应长什么样>
已知坑位：<本机环境、历史雷区>
```

验收标准是整条链路的锚点：coder 自审从它逐条对照开始，reviewer 的核对表就是它。**写不出验收标准的任务说明还没拆清楚，先拆再派。**

### coder（实现，第一道质量门）

- 交付前自审：验收标准逐条给"结论 + 证据（命令输出/文件:行号）"；重读全部 diff 确认无范围外改动；验证真跑过。
- 汇报四节：改动清单 / 验证结果 / **Review 记录** / 假设与未尽事项。
- 歧义不反问：选最合理解释直接干，汇报里声明假设。

### watcher（蹲守，只观察不干预）

- 两种模式：启动并蹲守（run_in_background + 周期读增量）/ 附着蹲守（ssh tail / 日志 tail）。
- 收尾条件：进程退出、报错堆栈、NaN、指标异常、连续 3 轮零变化（疑似卡死）、到时、叫停。
- 汇报：结论一行 + 日志尾部 20-50 行（报错必附堆栈）+ 最新指标 + 建议。

### reviewer（独立验收，第二道质量门）

- 输入三样：原派发指令全文、执行 agent 的汇报、改动文件清单。缺了先要，不瞎猜。
- 顺序：① 验收标准逐条核对（结论 + 证据）→ ② 审 diff（越界改动 / 回归 / 明显 bug）→ ③ 复跑验证 → ④ 汇报与 diff 对照（谎报漏报直接 fail）。
- 输出：verdict（pass / pass-with-notes / fail）+ 核对表 + 问题清单（blocker / should-fix / note）+ 可直接转发的重做指令。
- 只读不改；只对本次改动负责；无法验证的结论标注"未验证"。

## 2. 门禁流转

```
coder 交付
   │
   ▼
reviewer 独立验收 ── pass / pass-with-notes ──► 主会话终审（对照 verdict 抽查）──► 答复用户
   │
   fail / blocker
   ▼
问题清单转发回 coder 重做（同任务最多 2 轮）
   │
   ▼
仍 fail ──► 带问题清单升级用户决策
```

豁免（不派 reviewer）：一行级小改、纯格式调整、纯调研/蹲守类——主会话自己扫一眼即可。

## 3. 并行策略（快模型主会话）

目标不是"允许并行"，而是**吃满并发**——串行是最大的浪费：

- **饱和拆分**：动手前估总工作量，按文件/模块/目录/命令切成独立执行单元，一直拆到接近并发上限（默认渲染为 50）才停。拆不动的只有两类：同一文件的改动（归同一个子 agent，防写冲突）和强依赖的前后步骤。只派了三五个，先自问是不是拆得不够狠。

### 3.1 扇出铁律（最常见浪费源：同类任务习惯性打包给一个子 agent）

写派发指令时出现以下任一信号，立即改为扇出：

- 对象是复数：N 个文件 / N 个目录 / N 条命令 / N 个候选 / N 个数据集
- 你正在写"逐个""依次""然后处理下一个""以及顺便"这类流程描述
- 一个 prompt 里装了多个各自需要"读→改→验"完整循环的对象

扇出操作模板（让批量派发的书写成本低于写一个大 prompt）：

1. **先把整批清单列全**（N 个对象一行一个），再一次性发 N 个 Agent 调用（同一条消息）——绝不发一个等一个
2. N 个 prompt 共用同一模板，只换对象参数：「对象：<路径 i>；任务：<同一句话>；验收标准：<同一句话>」
3. 大批量用后台模式（run_in_background）发，发完继续拆下一批

合理打包例外（允许合给一个子 agent）：单对象只是一行级/几行级小改；或对象间强共享上下文（同一文件的多个函数、同一模块的紧耦合改动）。

- **后台流水线，不空等**：批量派发用后台模式（run_in_background），多个派发放在同一条消息里并发发出；发完立刻拆下一批，结果逐个收割验收，收齐再汇总。主会话空等 = 并行度为零。
- **分波保护**：单波重 agent（coder 类，带完整工具集与长上下文）约 20 个封顶，收割一波再放下一波——几十个子 agent 同时驻留可能把内存和主会话上下文顶爆；Explore 这类轻 agent 可以更密。
- **指令短而自包含**：目标 / 文件路径 / 可检查的验收标准 / 坑位一行。指令越长，主会话 token 成本越高、越不敢多派——模板化是高并发的前提。

## 4. 防套娃（最多两层）

- 深度上限两层：主会话 → 一层子 agent → 二层孙 agent，禁止第三层。
- `coder` / `watcher` / `reviewer` / `Explore` 的工具列表没有 Agent 工具，结构性不可能嵌套，天然是叶子。
- `general-purpose` 是唯一带 Agent 工具的类型，也是唯一的二层扇出入口，主会话派它时按任务形态二选一写入指令：
  - 可拆出 ≥3 个独立单元 → 授权二层扇出：再派 `coder` / `Explore` / `watcher`（单波 ≤10、后台模式），收工前自己派 `reviewer` 对孙辈改动局部验收；禁止派 `general-purpose`；孙辈指令写明"你不得再派发任何 agent"。
  - 单一单元任务 → "你不得再派发任何子 agent"。
- "禁派 general-purpose + 孙辈不得再派发"两条共同保证链条在两层收口；即使主会话忘了写授权边界，注入兜底条也会生效。
- 注入兜底条（用户级 AGENTS.md 注入子会话）："general-purpose 仅在主会话明确授权时可二层扇出，任何身份任何情况禁止派 general-purpose、禁止第三层"。
- 分波保护延伸：1 个授权扇出的 general-purpose ≈ 最多 10 个孙 agent；主会话同时驻留的授权扇出 general-purpose ≤3 个，把放大量计入单波预算。

## 5. 机制实测结论（2026-09-11 起，多项实测；覆盖 ZCode CLI 0.16.5 与桌面版 3.12.1）

1. **所有 agent 定义改动都要新会话才可靠生效**（2026-09-16 桌面版 3.12.1 实测，推翻 09-11 结论）：09-11 曾测得"改完 `coder.md` 立刻派 coder，新自审节已生效"，据此以为定义在派发时读取；09-16 复核推翻——agent 定义的 `model` 与 `systemPrompt` 都在**会话启动时快照**，长会话里改定义文件（包括把 `model` 改成有效的完整限定引用）后，同会话派发仍用旧配置。第 2 条（新增类型要新会话）与此同因，依旧成立。
2. **新增 agent 类型要新会话**：新建 `reviewer.md` 后，旧会话的 Agent 工具报 `Agent type 'reviewer' not found`；新会话可正常派发——可用类型列表在会话启动时快照。
3. **CLI headless 的 `--max-turns` 解析有坑**：`zcode --prompt ... --max-turns 25` 报 `Unknown option '--max-turns'`（help 里却列着），去掉即可。
4. **Git Bash bash 5.2 的 `patsub_replacement`**：`${var//pat/rep}` 替换串里的裸 `&` 会展开为匹配文本，写替换逻辑时要 `shopt -u patsub_replacement` 或避开（install.sh 已处理）。
5. **coder 实测**：带 3 条验收标准的小任务，四节汇报齐全，自审含手算验证与 `pytest.approx` 决策说明，验收标准逐条给证据。
6. **install 实测**：bash（Git Bash）与 PowerShell（5.1 / pwsh 7）双引擎，覆盖全新安装、幂等重装、参数变更升级、块外内容保留、卸载、.bak 备份、含 `&` 与 `/` 的模型值、CRLF 文件、路径含空格。
7. **模型引用格式会抖动**（2026-09-16 实测）：frontmatter 的 `model:` 写裸模型 ID（如 `GLM-5.3-Flash`）时，解析结果随会话变化，解析失败会**静默回退到账号默认模型**、不报错——全量审计 312 个子 agent，其中 103 个跑成了非预期的贵模型。修复用完整限定引用 `<providerId>/<modelId>`（providerId 是 `~/.zcode/v2/config.json` provider 映射的 key）；`agents-state.json` 的覆盖值格式为 `custom:<providerId>:<modelId>`；最稳的配置方式是桌面端 Settings → Subagents 界面选择。
8. **CLI 无头不能当模型探针**（2026-09-16 实测）：`zcode --prompt` 起的新会话，主会话模型与 `config.json` 的 `model.main` 无关（那是 legacy 导入源，不生效）。要确认某个模型引用实际生效与否，得开桌面版新会话观察。

## 6. 常见问题

**Q：为什么 reviewer 有 Bash 却说"只读"？**
复跑验证（pytest/build）需要 Bash；去掉 Write/Edit 是降低越界改动的便利性，真正的约束在系统提示纪律。要更严格可从 `agents/reviewer.md` 的 tools 里删掉 Bash，代价是失去复跑能力。

**Q：所有任务都要过门禁吗？**
不用。豁免清单：一行级小改、纯格式、调研/蹲守。判断权在主会话，规则里写死了这三类。

**Q：主力模型和快模型不是同一家怎么办？**
install 参数 `--strong` / `--fast` 各自填你家的模型即可；其中 `--fast` 会写进子 agent frontmatter 的 `model:`，建议用完整限定引用 `<providerId>/<modelId>`（裸模型 ID 解析会随会话抖动、失败静默回退账号默认模型，见 §5 第 7 条）。规则按模型名匹配身份（先匹配快模型——名字更具体，再匹配主力）。

**Q：子 agent 会读到我项目里的 AGENTS.md 吗？**
用户级 `~/.zcode/AGENTS.md` 会注入到（子）会话；注入块里的兜底条——"general-purpose 仅在主会话明确授权时可二层扇出，任何情况禁止派 general-purpose、禁止第三层"——正是为此兜底。

## 7. 模型时段路由（可选）

按时间段给全部子 agent 换模型——白天用免费无限额度的 API，夜间切到套餐免费时段的模型，或反过来。环境变量表、脚本用法与计划任务 / cron 命令见 [README](../README.md) 的「进阶：子 agent 模型按时段路由」；这里只讲机制与坑位。

**覆盖哪些位置**：`scripts/model_switch.py` 一次改写三处——`agents/{coder,reviewer,watcher}.md` frontmatter 的 `model:` 行，以及 `~/.zcode/v2/agents-state.json` 的 `builtInModelOverrides` / `builtInModelSelectionOverrides` / `pluginAgentModelSelectionOverrides` 三段。三段都要写：只改 frontmatter 会漏掉从 agents-state 取模型的内置与插件 agent，只改 agents-state 又会漏掉仓库模板定义的这三个。

**快照时机**：`model` 是 agent 定义的一部分，在会话启动时快照（§5 第 1 条），所以**切换只对新会话生效**——切换点之前开着的会话仍跑旧模型。定时任务把触发点设在换班时刻，正在跑的长会话要手动重开才会换。

**坑位**：Windows 计划任务走 `Register-ScheduledTask` 或 `LogonTrigger` 会报 0x80070005，所以注册脚本改用 XML + `schtasks /create /xml`；`StartWhenAvailable` 让睡眠错过的触发点开机补跑，而脚本按真实时间判断 day/night，补跑结果天然正确。脚本本身幂等、原子写，重复执行安全，日志在 `$ZCODE_HOME/logs/model-switch.log`。
