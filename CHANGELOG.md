# 更新记录

本文件记录 zcode-agent-squad 的显著变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [0.3.0] - 2026-09-17

### 变更

- 派发规则统一为**不分主模型，一律拉满并发**（2026-09-17 起）：`rules/AGENTS.snippet.md` 原「快模型 / 主力模型 / 其他模型」三档合一为「并发派发与 Review 门禁（zcode-agent-squad）」——主会话只做拆任务、写派发指令、验收结果、汇总答复；饱和拆分 + 扇出铁律 + 后台流水线 + 分波保护 + 两层扇出授权对所有主会话生效，派发对象清单顺带补齐各角色职责边界（coder / watcher / reviewer / Explore / general-purpose）。
- 同文件的 `## 扇出铁律（两个模型通用，最常见浪费源）`、`### Review 门禁（两个模型通用）` 标题去掉「两个模型通用」后缀，正文不动。
- 文档口径同步：`docs/workflow.md` 并行策略一节改为「不分主模型，拉满并发」，FAQ 由「主力模型和快模型不是同一家怎么办」改为「`--strong` 参数还需要吗」；`README.md` 简介与「注入的规则做了什么」改为「主会话（不分模型）」+「派发力度：一律拉满并发」。
- `scripts/install.sh` / `scripts/install.ps1`：`--help` 中 `--strong` 标注为 deprecated（规则不再按主模型分支，取值被忽略），参数解析与替换逻辑保留以向后兼容。

### 移除

- 规则片段不再按模型名判断身份：`{{STRONG_MODEL}}` 占位符从 `rules/AGENTS.snippet.md` 移除（install 脚本的 Replace 逻辑保留为 no-op，无害）；`{{FAST_MODEL}}` 仍用于子 agent frontmatter 的 `model:`。

## [0.2.0] - 2026-09-16

### 新增

- 子 agent 模型时段路由：`scripts/model_switch.py` 按时间段切换 `agents/{coder,reviewer,watcher}.md` frontmatter 与 `agents-state.json` 三段的模型；幂等、原子写，日志落 `$ZCODE_HOME/logs/model-switch.log`。
- `scripts/register_model_switch_task.ps1`：Windows 计划任务注册脚本，注册每天两个触发点；`StartWhenAvailable` 支持睡眠错过后开机补跑。
- `agents/{coder,reviewer,watcher}.md` 模板补充 `thoughtLevel: max` 与 `injectAgentsMd: true`。
- `scripts/check.sh` 增加 `py_compile` 检查项。

### 变更

- `scripts/install.sh` / `scripts/install.ps1`：安装 `model_switch.py`；frontmatter 模型值为裸模型 ID 时给出警告。
- agent 模板的 `model:` 值改为带引号渲染（与时段切换脚本的匹配形态一致）；已有安装升级重装时会因该漂移自动备份 `.bak`。

### 修正

- 推翻"修改 agent 定义即时生效"的旧结论（2026-09-11 实测得出）：2026-09-16 桌面版 3.12.1 复核实为**会话启动时快照**，所有 agent 定义改动（含换成有效模型引用）都要新会话才可靠生效。
- 补充模型引用格式坑：裸模型 ID 解析随会话抖动、失败静默回退账号默认模型；应使用完整限定引用 `<providerId>/<modelId>`。
- 补充 CLI 无头探针坑：`zcode --prompt` 起的会话主模型与 `config.json` 的 `model.main` 无关，不宜用来验证子 agent 模型配置。

## [0.1.0] - 2026-09-11

### 新增

- 初版：`coder` / `watcher` / `reviewer` 三角色与独立 Review 门禁、扇出铁律、两层防套娃（`general-purpose` 为唯一二层扇出入口）、Windows（PowerShell）与 Unix（bash）双平台安装器。
