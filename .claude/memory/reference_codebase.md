---
name: reference_codebase
description: 代码库位置、MT5路径、symlink同步方式、权限配置、日志读取
type: reference
---

所有EA策略代码统一管理在 `/Users/gabrielg/Trading-project/` 目录，该目录已配置Git同步。
写代码时直接在此目录创建/修改文件。

**MT5数据目录（Mac/Wine版）：**
`/Users/gabrielg/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/`

**软链接方式同步EA：**
Trading-project/Experts 下每个EA文件夹通过软链接挂载到MT5 Experts目录。
新增EA时运行：
```bash
ln -s ~/Trading-project/Experts/<EA名> "/Users/gabrielg/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/<EA名>"
```
已链接：XAUUSD_Trend_v1

**修改文件后只需在MT5按F7编译，无需手动复制文件。**

**回测日志路径（UTF-16LE编码）：**
```
/Users/gabrielg/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/Tester/Agent-127.0.0.1-3000/logs/YYYYMMDD.log
```
读取命令：`iconv -f UTF-16 -t UTF-8 <log文件>`
快速分析命令：`iconv -f UTF-16 -t UTF-8 <log> > /tmp/mt5_log.txt` 后用grep/sed处理
主日志（连接信息）：`Tester/logs/YYYYMMDD.log`

**项目权限配置（已设置，无需每次授权）：**
`.claude/settings.local.json` 已配置MT5目录的Read/Bash权限。
文件位置：`/Users/gabrielg/Trading-project/.claude/settings.local.json`
