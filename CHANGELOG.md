# 更新记录

本文件记录 zcode-agent-squad 的显著变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

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
