---
name: feedback_symlink
description: 创建新EA文件时必须同时建立MT5软链接
type: feedback
---

创建新 EA 文件后，必须同步在 MT5 MQL5/Experts 目录下建立软链接，否则 MT5 找不到文件。

**Why:** 用户提醒，之前创建 USOIL_Trend_v1 时差点遗漏这一步。

**How to apply:** 每次用 Write 或 sed 创建新 .mq5 文件后，立即执行：
```bash
mkdir -p "<MT5_PATH>/MQL5/Experts/<EA_NAME>"
ln -sf "<项目路径>/Experts/<EA_NAME>/<EA_NAME>.mq5" "<MT5_PATH>/MQL5/Experts/<EA_NAME>/<EA_NAME>.mq5"
```
MT5 路径：/Users/gabrielg/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5
