---
name: feedback_token_efficiency
description: 优先用省Token的方式操作，高消耗操作前需告知用户确认
type: feedback
---

默认使用最省Token的方式完成任务：优先用 Grep 搜关键词、Glob 找路径，避免不必要的整文件 Read 或 Agent 探索。

**Why:** 用户明确要求节省Token，高消耗操作需提前告知。

**How to apply:**
- 搜索文件/内容：优先 Grep/Glob，不直接 Read 整个文件
- 需要读大文件或开 Agent 前：先告知用户"这会消耗较多Token，确认继续？"
- 只在必要时才读取文件全文
