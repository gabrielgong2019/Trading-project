---
name: MT5回测日志路径
description: MT5回测日志和优化报告的文件路径，用于快速读取回测结果
type: reference
---

## 单次回测日志（最常用）

```
~/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/Tester/Agent-127.0.0.1-3000/logs/YYYYMMDD.log
```

- 编码：UTF-16，需用 `content.decode('utf-16')` 读取
- 用户说"跑完了"时，直接读今天日期的 Agent-3000 日志
- 关键字段：`final balance`、`order performed buy/sell`、`HARD STOP TRIGGERED`、`CIRCUIT BREAKER TRIGGERED`

## 优化结果报告

```
~/Trading-project/Backtest/ReportOptimizer-XXXXXXX.xml
```

- 格式：XML（Excel SpreadsheetML），可直接用 `xml.etree.ElementTree` 解析
- 列：Pass, Result, Profit, Expected Payoff, Profit Factor, Recovery Factor, Sharpe Ratio, Custom, Equity DD%, Trades, 各参数列

## 其他日志位置

- Tester Manager日志：`Tester/Manager/logs/YYYYMMDD.log`
- 多Agent优化日志：`Tester/Agent-127.0.0.1-300X/logs/YYYYMMDD.log`（3000-3009）
- 主终端日志：`MQL5/Logs/YYYYMMDD.log`
