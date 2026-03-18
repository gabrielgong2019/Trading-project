---
name: feedback_mt5_sync
description: MT5 EA文件同步方式：使用软链接而非复制
type: feedback
---

MT5 EA文件通过软链接同步，不要用cp复制文件。

**Why:** 复制文件需要每次手动同步，软链接让Git仓库与MT5目录实时一致，改一处两边自动同步。

**How to apply:** 新建EA时，在MT5 Experts目录创建软链接指向Trading-project：
```bash
ln -s "/Users/gabrielg/Trading-project/Experts/<EA_NAME>" \
  "/Users/gabrielg/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/<EA_NAME>"
```

**重要：** 新建EA文件后必须立即建软链接，否则MT5找不到文件。这是容易遗漏的步骤。

已建立软链接的EA：
- XAUUSD_Trend_v1 → Trading-project/Experts/XAUUSD_Trend_v1
- USDJPY_Trend_v1 → Trading-project/Experts/USDJPY_Trend_v1
- USOIL_Trend_v1 → Trading-project/Experts/USOIL_Trend_v1
