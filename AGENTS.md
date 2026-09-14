# AGENTS.md

zcode-agent-squad 是一套 ZCode 用户级子 agent 工作流配置：主会话当架构师拆任务、写可检查的验收标准并派发，coder/watcher 等快模型子 agent 并行干活，reviewer 独立验收把关——没过 review 的东西不端给用户。

- 项目定位、角色表与快速开始：见 README.md
- 工作流与派发规则详解：见 docs/workflow.md
- 改动后必跑：`bash scripts/check.sh`（校验 agents frontmatter 必填字段、snippet BEGIN/END 标记配对、install.sh 语法）
- 结构红线：新增代码不得使任何文件超过 800 行（目标 500），触碰上限先拆再改。
