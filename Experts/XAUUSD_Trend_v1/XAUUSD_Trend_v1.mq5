//+------------------------------------------------------------------+
//|                                             XAUUSD_Trend_v1.mq5 |
//|                                                                  |
//|  Strategy: H4 Trend Filter + H1 Price Action Entry              |
//|  Instruments: XAUUSD                                            |
//|  Version: 1.3 - Bug fixes + News Filter module                  |
//|                                                                  |
//|  Changes from v1.2:                                             |
//|  [FIX-1] OpenTrade: removed forced lot_min*2 override that      |
//|           silently exceeded RiskPercent on small accounts        |
//|  [FIX-2] ManageOpenPositions: ATR now reads bar[1] (closed)     |
//|           instead of bar[0] (live) for consistent trailing SL   |
//|  [FIX-3] OpenTrade: entry price slippage guard added -          |
//|           skip trade if market has moved > MaxEntrySlippage ATR  |
//|           away from bar[1] close since signal fired              |
//|           (default 5.0 = effectively disabled; tune after live  |
//|           data confirms typical slippage range)                 |
//|  [FIX-4] CountUnprotectedPositions: replaced ambiguous point    |
//|           proximity check with explicit per-position bool flag   |
//|           (g_position_protected map) to prevent false cooldown   |
//|  [NEW]   News Filter: blocks new entries and optionally closes   |
//|           positions within a configurable window around high-    |
//|           impact events (NFP, CPI, FOMC, BoJ). Uses a manually  |
//|           maintained schedule array - no external calendar feed  |
//|           required, works in Strategy Tester and live.          |
//+------------------------------------------------------------------+
#property copyright "Trading Project"
#property version   "1.30"
#property strict

input group "=== Trend Filter (H4) ==="
input int    H4_EMA_Fast        = 50;     // H4 Fast EMA period
input int    H4_EMA_Slow        = 200;    // H4 Slow EMA period
input int    H4_ADX_Period      = 14;     // H4 ADX period
input double H4_ADX_Min         = 25.0;  // Minimum ADX value to allow entry (0 = disabled)

input group "=== Entry (H1) ==="
input int    H1_EMA_Period      = 40;    // H1 EMA period for pullback
input double EMA_Touch_Buffer   = 0.5;  // ATR multiplier: price must be within N*ATR of H1 EMA40
input double H1_ATR_Min         = 0.0;   // Min H1 ATR to allow entry (0 = disabled)
input int    ATR_Ratio_Period   = 50;    // Bars to average for ATR ratio baseline
input double ATR_Min_Ratio      = 0.8;  // Min ratio of current ATR / avg ATR (0 = disabled)
input double MaxEntrySlippage   = 5.0;   // [FIX-3] Max ATR distance from bar[1] close to current price before skipping entry (5.0 = disabled; tune after live data)

input group "=== Risk Management ==="
input double RiskPercent        = 1.0;   // Risk per trade (% of equity)
input double TP_RR              = 2.0;   // Take profit risk:reward ratio (first target)
input double ATR_Trail_Multi    = 2.0;   // ATR multiplier for trailing stop
input double SL_ATR_Multi       = 2.5;   // ATR multiplier for initial stop loss
input int    ATR_Period         = 14;    // ATR period
input int    MaxUnprotected     = 2;     // Max positions not yet at breakeven

input group "=== Trade Settings ==="
input int    MagicNumber        = 20240001;
input string TradeComment       = "XAUUSD_Trend_v1";
input int    SwingLookback      = 10;    // Bars to look back for swing high/low
input int    StartHour          = 11;    // Trading start hour (server time) — London open (GMT+3 DST), filters Asian session noise
input int    EndHour            = 20;    // Trading end hour (server time) — covers London+NY overlap, filters late NY low-liquidity

input group "=== Circuit Breaker ==="
input double MaxDrawdownPct     = 20.0;  // Stop new trades if equity drops X% from peak
input double HardStopPct        = 30.0;  // Close ALL positions if equity drops X% from peak
input int    CBCooldownDays     = 21;    // Cooldown days before resuming after CB trigger

input group "=== News Filter ==="
input bool   NewsFilter_Enable         = true;  // Enable news blackout filter
input int    NewsFilter_MinutesBefore  = 60;    // Block entries N minutes before event
input int    NewsFilter_MinutesAfter   = 30;    // Block entries N minutes after event
input bool   NewsFilter_CloseOnEvent   = false; // Close ALL positions at event time (conservative)

//+------------------------------------------------------------------+
//| News event schedule                                              |
//| Format: year, month, day, hour, minute (server time)            |
//| Update this list before each month.                             |
//| All times in IC Markets SERVER TIME (GMT+2 winter / GMT+3 DST)  |
//| NFP/CPI: always 15:30 | FOMC: always 21:00                      |
//| BoJ: 05:00 winter / 06:00 summer                                |
//| REMEMBER: Update BoJ dates each year from boj.or.jp             |
//+------------------------------------------------------------------+
struct NewsEvent
  {
   int year, month, day, hour, minute;
   string label;
  };

NewsEvent g_news_schedule[] =
  {
   // ---- NFP 2026 ----
   {2026, 1,  9, 15, 30, "NFP Jan-26"},
   {2026, 2,  6, 15, 30, "NFP Feb-26"},
   {2026, 3,  6, 15, 30, "NFP Mar-26"},
   {2026, 4,  3, 15, 30, "NFP Apr-26"},
   {2026, 5,  8, 15, 30, "NFP May-26"},
   {2026, 6,  5, 15, 30, "NFP Jun-26"},
   {2026, 7, 10, 15, 30, "NFP Jul-26"},
   {2026, 8,  7, 15, 30, "NFP Aug-26"},
   {2026, 9,  4, 15, 30, "NFP Sep-26"},
   {2026,10,  2, 15, 30, "NFP Oct-26"},
   {2026,11,  6, 15, 30, "NFP Nov-26"},
   {2026,12,  4, 15, 30, "NFP Dec-26"},

   // ---- US CPI 2026 ----
   {2026, 1, 13, 15, 30, "CPI Jan-26"},
   {2026, 2, 11, 15, 30, "CPI Feb-26"},
   {2026, 3, 11, 15, 30, "CPI Mar-26"},
   {2026, 4, 10, 15, 30, "CPI Apr-26"},
   {2026, 5, 12, 15, 30, "CPI May-26"},
   {2026, 6, 11, 15, 30, "CPI Jun-26"},
   {2026, 7, 14, 15, 30, "CPI Jul-26"},
   {2026, 8, 12, 15, 30, "CPI Aug-26"},
   {2026, 9, 10, 15, 30, "CPI Sep-26"},
   {2026,10, 14, 15, 30, "CPI Oct-26"},
   {2026,11, 12, 15, 30, "CPI Nov-26"},
   {2026,12, 10, 15, 30, "CPI Dec-26"},

   // ---- FOMC 2026 ----
   {2026, 1, 28, 21,  0, "FOMC Jan-26"},
   {2026, 3, 18, 21,  0, "FOMC Mar-26"},
   {2026, 5,  6, 21,  0, "FOMC May-26"},
   {2026, 6, 17, 21,  0, "FOMC Jun-26"},
   {2026, 7, 29, 21,  0, "FOMC Jul-26"},
   {2026, 9, 16, 21,  0, "FOMC Sep-26"},
   {2026,10, 28, 21,  0, "FOMC Oct-26"},
   {2026,12,  9, 21,  0, "FOMC Dec-26"},

   // ---- BoJ 2026 ----
   {2026, 1, 24,  5,  0, "BoJ Jan-26"},
   {2026, 3, 19,  5,  0, "BoJ Mar-26"},
   {2026, 4, 30,  6,  0, "BoJ Apr-26"},
   {2026, 6, 17,  6,  0, "BoJ Jun-26"},
   {2026, 7, 31,  6,  0, "BoJ Jul-26"},
   {2026, 9, 19,  6,  0, "BoJ Sep-26"},
   {2026,10, 29,  6,  0, "BoJ Oct-26"},
   {2026,12, 19,  5,  0, "BoJ Dec-26"}
  };

//--- Global Variables
int      h4_ema_fast_handle, h4_ema_slow_handle;
int      h4_adx_handle;
int      h1_ema_handle, h1_atr_handle;
double   g_peak_equity     = 0.0;
bool     g_cb_active       = false;
datetime g_cb_trigger_time = 0;

//--- [FIX-4] Per-position protection flag map
#define MAX_POSITIONS 50
ulong  g_protected_tickets[MAX_POSITIONS];
bool   g_protected_flags[MAX_POSITIONS];
int    g_protected_count = 0;

//+------------------------------------------------------------------+
//| Protection flag helpers                                          |
//+------------------------------------------------------------------+
bool IsPositionProtected(ulong ticket)
  {
   for(int i = 0; i < g_protected_count; i++)
      if(g_protected_tickets[i] == ticket) return g_protected_flags[i];
   return false;
  }

void SetPositionProtected(ulong ticket, bool value)
  {
   for(int i = 0; i < g_protected_count; i++)
     {
      if(g_protected_tickets[i] == ticket)
        {
         g_protected_flags[i] = value;
         return;
        }
     }
   if(g_protected_count < MAX_POSITIONS)
     {
      g_protected_tickets[g_protected_count] = ticket;
      g_protected_flags[g_protected_count]   = value;
      g_protected_count++;
     }
  }

void CleanProtectedMap()
  {
   for(int i = g_protected_count - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_protected_tickets[i]))
        {
         for(int j = i; j < g_protected_count - 1; j++)
           {
            g_protected_tickets[j] = g_protected_tickets[j + 1];
            g_protected_flags[j]   = g_protected_flags[j + 1];
           }
         g_protected_count--;
        }
     }
  }

//+------------------------------------------------------------------+
//| News filter                                                      |
//+------------------------------------------------------------------+
bool IsNewsBlackout(string &out_label)
  {
   if(!NewsFilter_Enable) return false;

   datetime now        = TimeCurrent();
   int      n_events   = ArraySize(g_news_schedule);
   int      win_before = NewsFilter_MinutesBefore * 60;
   int      win_after  = NewsFilter_MinutesAfter  * 60;

   for(int i = 0; i < n_events; i++)
     {
      MqlDateTime ev_dt = {};
      ev_dt.year = g_news_schedule[i].year;
      ev_dt.mon  = g_news_schedule[i].month;
      ev_dt.day  = g_news_schedule[i].day;
      ev_dt.hour = g_news_schedule[i].hour;
      ev_dt.min  = g_news_schedule[i].minute;
      ev_dt.sec  = 0;

      datetime ev_time      = StructToTime(ev_dt);
      datetime window_start = ev_time - win_before;
      datetime window_end   = ev_time + win_after;

      if(now >= window_start && now <= window_end)
        {
         out_label = g_news_schedule[i].label;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   h4_ema_fast_handle = iMA(_Symbol, PERIOD_H4, H4_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   h4_ema_slow_handle = iMA(_Symbol, PERIOD_H4, H4_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   h4_adx_handle      = iADX(_Symbol, PERIOD_H4, H4_ADX_Period);
   h1_ema_handle      = iMA(_Symbol, PERIOD_H1, H1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   h1_atr_handle      = iATR(_Symbol, PERIOD_H1, ATR_Period);

   if(h4_ema_fast_handle == INVALID_HANDLE || h4_ema_slow_handle == INVALID_HANDLE ||
      h4_adx_handle      == INVALID_HANDLE ||
      h1_ema_handle      == INVALID_HANDLE || h1_atr_handle      == INVALID_HANDLE)
     {
      Print("Error creating indicator handles");
      return INIT_FAILED;
     }

   ArrayInitialize(g_protected_tickets, 0);
   ArrayInitialize(g_protected_flags,   false);
   g_protected_count = 0;

   g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("XAUUSD_Trend v1.3 initialised. News filter: ",
         NewsFilter_Enable ? "ON" : "OFF");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(h4_ema_fast_handle);
   IndicatorRelease(h4_ema_slow_handle);
   IndicatorRelease(h4_adx_handle);
   IndicatorRelease(h1_ema_handle);
   IndicatorRelease(h1_atr_handle);
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < StartHour || dt.hour > EndHour)
      return;

   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   CleanProtectedMap();
   ManageOpenPositions();

   double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(current_equity > g_peak_equity)
      g_peak_equity = current_equity;

   double drawdown_pct = (g_peak_equity - current_equity) / g_peak_equity * 100.0;

   if(!g_cb_active && drawdown_pct >= HardStopPct)
     {
      Print("HARD STOP TRIGGERED: Drawdown ", DoubleToString(drawdown_pct, 1),
            "% >= ", HardStopPct, "%. Closing ALL positions immediately.");
      CloseAllPositions();
      g_cb_active       = true;
      g_cb_trigger_time = currentBarTime;
      return;
     }

   if(!g_cb_active && drawdown_pct >= MaxDrawdownPct)
     {
      g_cb_active       = true;
      g_cb_trigger_time = currentBarTime;
      Print("CIRCUIT BREAKER TRIGGERED: Drawdown ", DoubleToString(drawdown_pct, 1),
            "% >= ", MaxDrawdownPct, "%. Cooldown ", CBCooldownDays, " days.");
     }
   if(g_cb_active)
     {
      int days_elapsed = (int)((currentBarTime - g_cb_trigger_time) / 86400);
      if(days_elapsed >= CBCooldownDays)
        {
         g_cb_active   = false;
         g_peak_equity = current_equity;
         Print("CIRCUIT BREAKER RESET: Cooldown complete. New peak equity: ", current_equity);
        }
      else
        {
         static datetime lastCBLog = 0;
         if(currentBarTime != lastCBLog)
           {
            Print("CIRCUIT BREAKER: Day ", days_elapsed, "/", CBCooldownDays,
                  " | Drawdown ", DoubleToString(drawdown_pct, 1), "%");
            lastCBLog = currentBarTime;
           }
         return;
        }
     }

   string news_label = "";
   if(IsNewsBlackout(news_label))
     {
      static datetime lastNewsLog = 0;
      if(currentBarTime != lastNewsLog)
        {
         Print("NEWS FILTER: Entry blocked - ", news_label, " blackout active.");
         lastNewsLog = currentBarTime;
        }
      if(NewsFilter_CloseOnEvent)
         CloseAllPositions();
      return;
     }

   if(CountUnprotectedPositions() >= MaxUnprotected)
      return;

   double h4_ema50 = 0;
   int trend = GetH4Trend(h4_ema50);
   if(trend == 0) return;

   int signal = GetH1Signal(trend, h4_ema50);
   if(signal == 0) return;

   OpenTrade(signal);
  }

//+------------------------------------------------------------------+
//| Get H4 trend direction                                           |
//| Returns: 1=bullish, -1=bearish, 0=no clear trend               |
//+------------------------------------------------------------------+
int GetH4Trend(double &h4_ema50_out)
  {
   double ema_fast[], ema_slow[];
   ArraySetAsSeries(ema_fast, true);
   ArraySetAsSeries(ema_slow, true);

   if(CopyBuffer(h4_ema_fast_handle, 0, 1, 1, ema_fast) < 1) return 0;
   if(CopyBuffer(h4_ema_slow_handle, 0, 1, 1, ema_slow) < 1) return 0;

   h4_ema50_out = ema_fast[0];

   if(H4_ADX_Min > 0)
     {
      double adx_buf[];
      ArraySetAsSeries(adx_buf, true);
      if(CopyBuffer(h4_adx_handle, 0, 1, 1, adx_buf) < 1) return 0;
      if(adx_buf[0] < H4_ADX_Min) return 0;
     }

   if(ema_fast[0] > ema_slow[0]) return  1;
   if(ema_fast[0] < ema_slow[0]) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| Get H1 price action signal                                       |
//+------------------------------------------------------------------+
int GetH1Signal(int trend, double h4_ema50)
  {
   double ema[], atr[];
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(h1_ema_handle, 0, 1, 3, ema) < 3) return 0;
   if(CopyBuffer(h1_atr_handle, 0, 1, ATR_Ratio_Period + 1, atr) < ATR_Ratio_Period + 1) return 0;

   double sig_open   = iOpen(_Symbol,  PERIOD_H1, 1);
   double sig_high   = iHigh(_Symbol,  PERIOD_H1, 1);
   double sig_low    = iLow(_Symbol,   PERIOD_H1, 1);
   double sig_close  = iClose(_Symbol, PERIOD_H1, 1);
   double prev_open  = iOpen(_Symbol,  PERIOD_H1, 2);
   double prev_close = iClose(_Symbol, PERIOD_H1, 2);

   double ema40       = ema[0];
   double atr_val     = atr[0];
   double touch_range = EMA_Touch_Buffer * atr_val;

   if(H1_ATR_Min > 0 && atr_val < H1_ATR_Min) return 0;

   if(ATR_Min_Ratio > 0)
     {
      double atr_sum = 0;
      for(int i = 1; i <= ATR_Ratio_Period; i++) atr_sum += atr[i];
      double atr_avg = atr_sum / ATR_Ratio_Period;
      if(atr_avg > 0 && atr_val / atr_avg < ATR_Min_Ratio) return 0;
     }

   if(trend == 1)
     {
      if(sig_close < h4_ema50) return 0;
      if(sig_low  > ema40 + touch_range)     return 0;
      if(sig_high < ema40 - touch_range * 2) return 0;
      if(sig_close < ema40) return 0;  // [②] close confirmation: body must close above EMA40
      bool pb = IsBullishPinBar(sig_open, sig_high, sig_low, sig_close);
      bool eg = IsBullishEngulfing(prev_open, prev_close, sig_open, sig_close);
      if(pb || eg) return 1;
     }
   if(trend == -1)
     {
      if(sig_close > h4_ema50) return 0;
      if(sig_high < ema40 - touch_range)     return 0;
      if(sig_low  > ema40 + touch_range * 2) return 0;
      if(sig_close > ema40) return 0;  // [②] close confirmation: body must close below EMA40
      bool pb = IsBearishPinBar(sig_open, sig_high, sig_low, sig_close);
      bool eg = IsBearishEngulfing(prev_open, prev_close, sig_open, sig_close);
      if(pb || eg) return -1;
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Pin Bar & Engulfing detection                                    |
//+------------------------------------------------------------------+
bool IsBullishPinBar(double o, double h, double l, double c)
  {
   double total_range = h - l;
   if(total_range < _Point) return false;
   double lower_wick = MathMin(o, c) - l;
   double upper_wick = h - MathMax(o, c);
   return (lower_wick >= total_range * 0.6 &&
           c >= l + total_range * 0.6 &&
           upper_wick <= total_range * 0.2);
  }

bool IsBearishPinBar(double o, double h, double l, double c)
  {
   double total_range = h - l;
   if(total_range < _Point) return false;
   double upper_wick = h - MathMax(o, c);
   double lower_wick = MathMin(o, c) - l;
   return (upper_wick >= total_range * 0.6 &&
           c <= h - total_range * 0.6 &&
           lower_wick <= total_range * 0.2);
  }

bool IsBullishEngulfing(double prev_o, double prev_c, double cur_o, double cur_c)
  {
   return (prev_c < prev_o && cur_c > cur_o &&
           cur_o <= prev_c && cur_c >= prev_o);
  }

bool IsBearishEngulfing(double prev_o, double prev_c, double cur_o, double cur_c)
  {
   return (prev_c > prev_o && cur_c < cur_o &&
           cur_o >= prev_c && cur_c <= prev_o);
  }

//+------------------------------------------------------------------+
//| Get broker-supported order filling mode                          |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillMode()
  {
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| Open a new trade                                                 |
//| [FIX-1] Removed forced lot_min*2 override                       |
//| [FIX-3] Added slippage guard vs bar[1] close price              |
//+------------------------------------------------------------------+
void OpenTrade(int direction)
  {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(h1_atr_handle, 0, 1, 1, atr) < 1) return;
   double atr_val = atr[0];

   // [FIX-3] Slippage guard (default 5.0 ATR = effectively disabled)
   double bar1_close   = iClose(_Symbol, PERIOD_H1, 1);
   double current_ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double current_bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slippage_max = MaxEntrySlippage * atr_val;

   if(direction == 1 && (current_ask - bar1_close) > slippage_max)
     {
      Print("Skip BUY: market moved ", DoubleToString(current_ask - bar1_close, _Digits),
            " above bar[1] close (max: ", DoubleToString(slippage_max, _Digits), ")");
      return;
     }
   if(direction == -1 && (bar1_close - current_bid) > slippage_max)
     {
      Print("Skip SELL: market moved ", DoubleToString(bar1_close - current_bid, _Digits),
            " below bar[1] close (max: ", DoubleToString(slippage_max, _Digits), ")");
      return;
     }

   double entry_price, sl_price;
   if(direction == 1)
     {
      entry_price = current_ask;
      sl_price    = entry_price - SL_ATR_Multi * atr_val;
     }
   else
     {
      entry_price = current_bid;
      sl_price    = entry_price + SL_ATR_Multi * atr_val;
     }

   double sl_distance = MathAbs(entry_price - sl_price);
   if(sl_distance < _Point) return;

   double lot_size = CalculateLotSize(sl_distance);
   if(lot_size <= 0) return;  // [FIX-1] Never override - skip if can't size

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};
   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = _Symbol;
   request.volume       = lot_size;
   request.type         = direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price        = entry_price;
   request.sl           = NormalizeDouble(sl_price, _Digits);
   request.tp           = 0;
   request.deviation    = 20;
   request.magic        = MagicNumber;
   request.comment      = TradeComment;
   request.type_filling = GetFillMode();

   if(!OrderSend(request, result))
      Print("OrderSend failed: retcode=", result.retcode, " comment=", result.comment);
   else
     {
      Print("Trade opened: ", direction == 1 ? "BUY" : "SELL",
            " Entry=", entry_price, " SL=", sl_price,
            " Lots=", lot_size, " ticket=", result.order);
      SetPositionProtected(result.order, false);
     }
  }

//+------------------------------------------------------------------+
//| Manage open positions: half-close at 1:2, breakeven, ATR trail  |
//| [FIX-2] ATR reads bar[1] (closed) consistently                  |
//| [FIX-4] Protection state via explicit flag map                  |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(h1_atr_handle, 0, 1, 1, atr) < 1) return;  // [FIX-2] offset=1
   double atr_val = atr[0];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      double open_price  = PositionGetDouble(POSITION_PRICE_OPEN);
      double current_sl  = PositionGetDouble(POSITION_SL);
      double current_vol = PositionGetDouble(POSITION_VOLUME);
      double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      long   pos_type    = PositionGetInteger(POSITION_TYPE);

      bool is_protected = IsPositionProtected(ticket);  // [FIX-4]

      if(!is_protected)
        {
         double sl_dist  = MathAbs(open_price - current_sl);
         double tp_level = (pos_type == POSITION_TYPE_BUY)
                           ? open_price + sl_dist * TP_RR
                           : open_price - sl_dist * TP_RR;

         bool tp_reached = (pos_type == POSITION_TYPE_BUY)
                           ? current_bid >= tp_level
                           : current_ask <= tp_level;

         if(tp_reached)
           {
            double close_vol = NormalizeVolume(current_vol / 2.0);
            if(close_vol > 0 && PartialClose(ticket, pos_type, close_vol))
              {
               if(PositionSelectByTicket(ticket))
                 {
                  ModifyPosition(ticket, open_price, 0);
                  SetPositionProtected(ticket, true);
                  Print("Half-close done, SL at breakeven. ticket=", ticket);
                 }
              }
           }
        }
      else
        {
         if(pos_type == POSITION_TYPE_BUY)
           {
            double trail_sl = NormalizeDouble(current_bid - ATR_Trail_Multi * atr_val, _Digits);
            if(trail_sl > current_sl && trail_sl > open_price)
               ModifyPosition(ticket, trail_sl, 0);
           }
         else
           {
            double trail_sl = NormalizeDouble(current_ask + ATR_Trail_Multi * atr_val, _Digits);
            if(trail_sl < current_sl && trail_sl < open_price)
               ModifyPosition(ticket, trail_sl, 0);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Count unprotected positions (explicit flag map)                  |
//+------------------------------------------------------------------+
int CountUnprotectedPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;
      if(!IsPositionProtected(ticket)) count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Partial close                                                    |
//+------------------------------------------------------------------+
bool PartialClose(ulong ticket, long pos_type, double vol)
  {
   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};
   request.action       = TRADE_ACTION_DEAL;
   request.position     = ticket;
   request.symbol       = _Symbol;
   request.volume       = vol;
   request.type         = pos_type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price        = pos_type == POSITION_TYPE_BUY
                          ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                          : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   request.deviation    = 20;
   request.magic        = MagicNumber;
   request.comment      = "HalfClose";
   request.type_filling = GetFillMode();

   if(!OrderSend(request, result))
     {
      Print("PartialClose failed: ticket=", ticket, " retcode=", result.retcode);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Normalize volume to broker lot step                              |
//+------------------------------------------------------------------+
double NormalizeVolume(double vol)
  {
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lot_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   vol = MathFloor(vol / lot_step) * lot_step;
   return vol >= lot_min ? vol : 0;
  }

//+------------------------------------------------------------------+
//| Modify position SL/TP                                            |
//+------------------------------------------------------------------+
void ModifyPosition(ulong ticket, double new_sl, double new_tp)
  {
   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};
   request.action   = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol   = _Symbol;
   request.sl       = NormalizeDouble(new_sl, _Digits);
   request.tp       = new_tp > 0 ? NormalizeDouble(new_tp, _Digits) : 0;

   if(!OrderSend(request, result))
      Print("ModifyPosition failed: ticket=", ticket, " retcode=", result.retcode);
  }

//+------------------------------------------------------------------+
//| Close all positions for this EA                                  |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      long   pos_type = PositionGetInteger(POSITION_TYPE);
      double vol      = PositionGetDouble(POSITION_VOLUME);

      MqlTradeRequest request = {};
      MqlTradeResult  result  = {};
      request.action       = TRADE_ACTION_DEAL;
      request.position     = ticket;
      request.symbol       = _Symbol;
      request.volume       = vol;
      request.type         = pos_type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price        = pos_type == POSITION_TYPE_BUY
                             ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                             : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.deviation    = 50;
      request.magic        = MagicNumber;
      request.comment      = "HardStop";
      request.type_filling = GetFillMode();

      if(!OrderSend(request, result))
         Print("CloseAllPositions failed: ticket=", ticket, " retcode=", result.retcode);
      else
         Print("Position closed: ticket=", ticket, " vol=", vol);
     }
  }

//+------------------------------------------------------------------+
//| Calculate lot size based on risk %                               |
//| [FIX-1] Removed forced lot_min*2 override                       |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_distance_price)
  {
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount = equity * RiskPercent / 100.0;
   double tick_value  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lot_min     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot_max     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tick_size <= 0 || tick_value <= 0) return 0;

   double value_per_lot = (sl_distance_price / tick_size) * tick_value;
   if(value_per_lot <= 0) return 0;

   double raw_lots = risk_amount / value_per_lot;

   if(raw_lots < lot_min)
     {
      double actual_risk_pct = (lot_min * value_per_lot) / equity * 100.0;
      Print("Skip trade: SL too wide. Required lots=", DoubleToString(raw_lots, 3),
            " < lot_min=", lot_min,
            " (would risk ", DoubleToString(actual_risk_pct, 1), "% vs target ", RiskPercent, "%)");
      return 0;
     }

   double lot_size = MathFloor(raw_lots / lot_step) * lot_step;
   return MathMin(lot_max, lot_size);
  }

//+------------------------------------------------------------------+
//| Find swing low in last N H1 bars                                 |
//+------------------------------------------------------------------+
double FindSwingLow(int lookback)
  {
   double lowest = DBL_MAX;
   for(int i = 1; i <= lookback; i++)
     {
      double low = iLow(_Symbol, PERIOD_H1, i);
      if(low < lowest) lowest = low;
     }
   return lowest == DBL_MAX ? 0 : lowest;
  }

//+------------------------------------------------------------------+
//| Find swing high in last N H1 bars                                |
//+------------------------------------------------------------------+
double FindSwingHigh(int lookback)
  {
   double highest = -DBL_MAX;
   for(int i = 1; i <= lookback; i++)
     {
      double high = iHigh(_Symbol, PERIOD_H1, i);
      if(high > highest) highest = high;
     }
   return highest == -DBL_MAX ? 0 : highest;
  }
//+------------------------------------------------------------------+
