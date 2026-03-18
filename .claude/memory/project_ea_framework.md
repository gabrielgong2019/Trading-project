---
name: project_ea_framework
description: EA策略框架项目：选定品种、年化目标、各EA开发状态与回测结果
type: project
---

正在构建EA策略框架。

**品种与策略分配（确认版）：**
| 品种 | 策略类型 | 状态 |
|------|----------|------|
| XAUUSD | 趋势跟随 | v1.3 已完成并锁定 |
| USDJPY | 趋势跟随 | v1.0 已创建，回测中 |
| USOIL | 趋势跟随 | 待开发 |
| NAS100 | 趋势跟随（多头偏向）| 待开发 |
| EURUSD | 均值回归 | 待开发 |

**组合目标：** 年化15%
**相关性设计：** 五品种整体低相关，XAUUSD/USOIL/NAS100彼此低-负相关，FX两对相关性低。

**Why:** 低相关品种组合可平滑单一策略的回撤周期，整体年化更稳定。
**How to apply:** 复用XAUUSD趋势框架（H4+H1）开发USOIL/USDJPY/NAS100；单独开发EURUSD均值回归。

---

## XAUUSD_Trend_v1（参数已锁定，2026-03-15）

**代码文件：** `/Users/gabrielg/Trading-project/Experts/XAUUSD_Trend_v1/XAUUSD_Trend_v1.mq5`

**最终参数（v1.2 代码框架）：**
| 参数 | 值 |
|------|-----|
| H4_EMA_Fast | 50 |
| H4_EMA_Slow | 200 |
| H4_ADX_Min | 25.0 |
| H1_EMA_Period | 40 |
| EMA_Touch_Buffer | 0.5 |
| TP_RR | 2.0 |
| ATR_Trail_Multi | 2.0 |
| RiskPercent | 1.0 |
| MaxUnprotected | 2 |
| SwingLookback | 10 |
| MaxDrawdownPct | 20.0 |
| CBCooldownDays | 21 |

**回测结果（2016-2024，初始$5,000）：**
| 年份 | 净利 |
|------|------|
| 2016 | -$54 |
| 2017 | +$722 |
| 2018 | +$279 |
| 2019 | -$210 |
| 2020 | +$749 |
| 2021 | -$85 |
| 2022 | +$1,698 |
| 2023 | +$2,623 |
| 2024 | +$5,455 |
| **合计** | **+$11,175** → 最终余额 $16,175 |

- 年化约 11.4%，总开仓 859 笔
- 2016-2021 仅 +$1,401（行情结构问题，非参数问题）
- 2022-2024 贡献 87% 利润（黄金大牛市）

**已测试并否决：**
- ADX=30：余额 $4,831（大趋势行情被过滤）
- TP_RR=2.5：余额 $15,301（前几年无改善）
- TP_RR=2.3：余额 $12,225（全面变差）
- ATR_Trail_Multi=2.5：比 2.0 差

---

## USDJPY_Trend_v1（策略重新评估中）

**代码文件：** `/Users/gabrielg/Trading-project/Experts/USDJPY_Trend_v1/USDJPY_Trend_v1.mq5`

**已修复 bug：** `CalculateLotSize()` 新增 JPY→USD 汇率换算（`SYMBOL_CURRENCY_PROFIT` 检测），由另一个AI完成，逻辑正确。

**基准回测结果（2010-2024，初始$5,000，EMA 50/200，ATR_Trail=2.0）：**
- 最终余额：**$394**（亏损 92%）
- 总开仓：1,578 笔（~105笔/年）
- 达到 1:2 半平仓：414 笔（胜率仅 **26.2%**，盈亏平衡需 33%）
- CB 触发：22 次（平均每年 1.5 次），风控正常但无法救回负期望策略

**结论：** XAUUSD 趋势框架不适合 USDJPY。USDJPY 2010-2020 长达 10 年震荡，H4+H1 粒度太细，假信号极多。

**改造方向（已讨论，待决策）：**
1. 上移时间周期：D1 趋势过滤 + H4 入场，ADX 阈值提高到 30+
2. 在现有框架加 D1 EMA 作为第三层过滤（改动最小）
3. 放弃趋势，改做均值回归

---

## 待完成

- **USDJPY：** 决定改造方向（D1+H4 框架 或 加D1过滤 或 改均值回归）
- 开发 USOIL 趋势策略
- 开发 NAS100 趋势策略（多头偏向）
- 开发 EURUSD 均值回归策略
