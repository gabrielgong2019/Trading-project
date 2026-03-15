//+------------------------------------------------------------------+
//|                                             USDJPY_Trend_v1.mq5 |
//|                                                                  |
//|  Strategy: D1 Trend Filter + H4 Price Action Entry              |
//|  Instruments: USDJPY                                            |
//|  Version: 2.0 - Upgraded to D1 trend filter + H4 entry         |
//+------------------------------------------------------------------+
#property copyright "Trading Project"
#property version   "2.00"
#property strict

input group "=== Trend Filter (D1) ==="
input int    D1_EMA_Fast     = 50;       // D1 Fast EMA period
input int    D1_EMA_Slow     = 200;      // D1 Slow EMA period
input int    H4_ADX_Period   = 14;       // H4 ADX period
input double H4_ADX_Min      = 30.0;    // Minimum H4 ADX value to allow entry (0 = disabled)

input group "=== Entry (H4) ==="
input int    H4_EMA_Period   = 40;       // H4 EMA period for pullback
input double EMA_Touch_Buffer = 0.5;     // ATR multiplier: price must be within N*ATR of H4 EMA
input double H4_ATR_Min      = 0.0;     // Min H4 ATR to allow entry — skip low-volatility chop (0 = disabled)

input group "=== Risk Management ==="
input double RiskPercent     = 1.0;      // Risk per trade (% of equity)
input double TP_RR           = 2.0;      // Take profit risk:reward ratio (first target)
input double ATR_Trail_Multi = 2.0;      // ATR multiplier for trailing stop
input int    ATR_Period      = 14;       // ATR period
input int    MaxUnprotected  = 2;        // Max positions not yet at breakeven

input group "=== Trade Settings ==="
input int    MagicNumber     = 20240002; // Magic number
input string TradeComment    = "USDJPY_Trend_v1";
input int    SwingLookback   = 10;       // Bars to look back for swing high/low

input group "=== Circuit Breaker ==="
input double MaxDrawdownPct  = 20.0;    // Stop new trades if equity drops X% from peak
input int    CBCooldownDays  = 21;      // Cooldown period in days before resuming after CB trigger

//--- Global Variables
int      d1_ema_fast_handle, d1_ema_slow_handle;
int      h4_adx_handle;
int      h4_ema_handle, h4_atr_handle;
double   g_peak_equity       = 0.0;
bool     g_cb_active         = false;
datetime g_cb_trigger_time   = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   d1_ema_fast_handle = iMA(_Symbol, PERIOD_D1, D1_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   d1_ema_slow_handle = iMA(_Symbol, PERIOD_D1, D1_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   h4_adx_handle      = iADX(_Symbol, PERIOD_H4, H4_ADX_Period);
   h4_ema_handle      = iMA(_Symbol, PERIOD_H4, H4_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   h4_atr_handle      = iATR(_Symbol, PERIOD_H4, ATR_Period);

   if(d1_ema_fast_handle == INVALID_HANDLE || d1_ema_slow_handle == INVALID_HANDLE ||
      h4_adx_handle == INVALID_HANDLE ||
      h4_ema_handle == INVALID_HANDLE || h4_atr_handle == INVALID_HANDLE)
     {
      Print("Error creating indicator handles");
      return INIT_FAILED;
     }

   g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(d1_ema_fast_handle);
   IndicatorRelease(d1_ema_slow_handle);
   IndicatorRelease(h4_adx_handle);
   IndicatorRelease(h4_ema_handle);
   IndicatorRelease(h4_atr_handle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Only act on new H4 bar open
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_H4, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   ManageOpenPositions();

   double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(current_equity > g_peak_equity)
      g_peak_equity = current_equity;

   double drawdown_pct = (g_peak_equity - current_equity) / g_peak_equity * 100.0;
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
         g_cb_active     = false;
         g_peak_equity   = current_equity;
         Print("CIRCUIT BREAKER RESET: ", CBCooldownDays, " day cooldown complete. Resuming trades. New peak: ", current_equity);
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

   if(CountUnprotectedPositions() >= MaxUnprotected)
      return;

   double d1_ema_fast = 0;
   int trend = GetD1Trend(d1_ema_fast);
   if(trend == 0)
      return;

   int signal = GetH4Signal(trend, d1_ema_fast);
   if(signal == 0)
      return;

   OpenTrade(signal);
  }

//+------------------------------------------------------------------+
//| Get D1 trend direction                                           |
//| Returns: 1=bullish, -1=bearish, 0=no clear trend               |
//+------------------------------------------------------------------+
int GetD1Trend(double &d1_ema_fast_out)
  {
   double ema_fast[], ema_slow[];
   ArraySetAsSeries(ema_fast, true);
   ArraySetAsSeries(ema_slow, true);

   if(CopyBuffer(d1_ema_fast_handle, 0, 1, 1, ema_fast) < 1) return 0;
   if(CopyBuffer(d1_ema_slow_handle, 0, 1, 1, ema_slow) < 1) return 0;

   d1_ema_fast_out = ema_fast[0];

   // ADX trend strength filter on H4 (D1 ADX is too slow to react)
   if(H4_ADX_Min > 0)
     {
      double adx_buf[];
      ArraySetAsSeries(adx_buf, true);
      if(CopyBuffer(h4_adx_handle, 0, 1, 1, adx_buf) < 1) return 0;
      if(adx_buf[0] < H4_ADX_Min) return 0;
     }

   if(ema_fast[0] > ema_slow[0]) return  1;  // Bullish
   if(ema_fast[0] < ema_slow[0]) return -1;  // Bearish
   return 0;
  }

//+------------------------------------------------------------------+
//| Get H4 price action signal                                       |
//| Returns: 1=long signal, -1=short signal, 0=no signal            |
//+------------------------------------------------------------------+
int GetH4Signal(int trend, double d1_ema_fast)
  {
   double ema[], atr[];
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(h4_ema_handle, 0, 1, 3, ema) < 3) return 0;
   if(CopyBuffer(h4_atr_handle, 0, 1, 1, atr) < 1) return 0;

   // Signal candle is bar[1] (last closed H4 bar)
   double sig_open  = iOpen(_Symbol,  PERIOD_H4, 1);
   double sig_high  = iHigh(_Symbol,  PERIOD_H4, 1);
   double sig_low   = iLow(_Symbol,   PERIOD_H4, 1);
   double sig_close = iClose(_Symbol, PERIOD_H4, 1);
   double prev_open  = iOpen(_Symbol,  PERIOD_H4, 2);
   double prev_close = iClose(_Symbol, PERIOD_H4, 2);

   double ema40   = ema[0];
   double atr_val = atr[0];
   double touch_range = EMA_Touch_Buffer * atr_val;

   if(H4_ATR_Min > 0 && atr_val < H4_ATR_Min) return 0;

   if(trend == 1)
     {
      // Price position filter: H4 close must be above D1 EMA fast
      if(sig_close < d1_ema_fast) return 0;

      if(sig_low > ema40 + touch_range)      return 0;
      if(sig_high < ema40 - touch_range * 2) return 0;

      bool pb = IsBullishPinBar(sig_open, sig_high, sig_low, sig_close);
      bool eg = IsBullishEngulfing(prev_open, prev_close, sig_open, sig_close);
      if(pb || eg) return 1;
     }

   if(trend == -1)
     {
      // Price position filter: H4 close must be below D1 EMA fast
      if(sig_close > d1_ema_fast) return 0;

      if(sig_high < ema40 - touch_range)     return 0;
      if(sig_low > ema40 + touch_range * 2)  return 0;

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
   double lower_wick  = MathMin(o, c) - l;
   double upper_wick  = h - MathMax(o, c);
   return (lower_wick >= total_range * 0.6 &&
           c >= l + total_range * 0.6 &&
           upper_wick <= total_range * 0.2);
  }

bool IsBearishPinBar(double o, double h, double l, double c)
  {
   double total_range = h - l;
   if(total_range < _Point) return false;
   double upper_wick  = h - MathMax(o, c);
   double lower_wick  = MathMin(o, c) - l;
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
//+------------------------------------------------------------------+
void OpenTrade(int direction)
  {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(h4_atr_handle, 0, 1, 1, atr) < 1) return;

   double entry_price, sl_price;
   double atr_val = atr[0];

   if(direction == 1)  // Long
     {
      entry_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl_price    = FindSwingLow(SwingLookback);
      if(sl_price <= 0) return;
      sl_price -= 10 * _Point;
     }
   else  // Short
     {
      entry_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl_price    = FindSwingHigh(SwingLookback);
      if(sl_price <= 0) return;
      sl_price += 10 * _Point;
     }

   double sl_distance = MathAbs(entry_price - sl_price);
   if(sl_distance < _Point) return;

   // Ensure SL is at least 1x ATR
   if(sl_distance < 1.0 * atr_val)
     {
      sl_price    = direction == 1 ? entry_price - atr_val : entry_price + atr_val;
      sl_distance = atr_val;
      Print("SL widened to 1x ATR floor: ", sl_price);
     }

   // Skip if SL is wider than 4x ATR
   if(sl_distance > 4.0 * atr_val)
     {
      Print("SL too wide (", sl_distance, " > 4x ATR ", 4.0*atr_val, "), skip trade");
      return;
     }

   double lot_size = CalculateLotSize(sl_distance);
   if(lot_size <= 0) return;

   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lot_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lot_size < lot_min * 2) lot_size = lot_min * 2;

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = _Symbol;
   request.volume       = lot_size;
   request.type         = direction == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price        = entry_price;
   request.sl           = sl_price;
   request.tp           = 0;
   request.deviation    = 20;
   request.magic        = MagicNumber;
   request.comment      = TradeComment;
   request.type_filling = GetFillMode();

   if(!OrderSend(request, result))
      Print("OrderSend failed: ", result.retcode, " ", result.comment);
   else
      Print("Trade opened: ", direction == 1 ? "BUY" : "SELL",
            " Entry=", entry_price, " SL=", sl_price,
            " Lots=", lot_size, " (half-close target @1:2)");
  }

//+------------------------------------------------------------------+
//| Manage open positions: half-close at 1:2, breakeven, ATR trail |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(h4_atr_handle, 0, 0, 1, atr) < 1) return;
   double atr_val = atr[0];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double open_price  = PositionGetDouble(POSITION_PRICE_OPEN);
      double current_sl  = PositionGetDouble(POSITION_SL);
      double current_vol = PositionGetDouble(POSITION_VOLUME);
      double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      long   pos_type    = PositionGetInteger(POSITION_TYPE);

      bool is_trailing = (pos_type == POSITION_TYPE_BUY)
                         ? (current_sl >= open_price - _Point)
                         : (current_sl <= open_price + _Point);

      if(!is_trailing)
        {
         double sl_dist  = MathAbs(open_price - current_sl);
         double tp_level = pos_type == POSITION_TYPE_BUY
                           ? open_price + sl_dist * TP_RR
                           : open_price - sl_dist * TP_RR;

         bool tp_reached = pos_type == POSITION_TYPE_BUY
                           ? current_bid >= tp_level
                           : current_ask <= tp_level;

         if(tp_reached)
           {
            double close_vol = NormalizeVolume(current_vol / 2.0);
            if(close_vol > 0 && PartialClose(ticket, pos_type, close_vol))
              {
               if(PositionSelectByTicket(ticket))
                  ModifyPosition(ticket, open_price, 0);
               Print("Half-close done, SL moved to breakeven. ticket=", ticket);
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
//| Calculate lot size based on risk %                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_distance_price)
  {
   double equity        = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount   = equity * RiskPercent / 100.0;
   double tick_value    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lot_min       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot_max       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Convert tick_value to account currency if needed (e.g. USDJPY profit is in JPY)
   string acc_currency    = AccountInfoString(ACCOUNT_CURRENCY);
   string profit_currency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   if(acc_currency != profit_currency && StringLen(acc_currency) > 0 && StringLen(profit_currency) > 0)
     {
      string conv_sym = profit_currency + acc_currency;
      double conv = 0;
      if(SymbolInfoDouble(conv_sym, SYMBOL_BID) > 0 || SymbolInfoDouble(conv_sym, SYMBOL_ASK) > 0)
        {
         double bid = SymbolInfoDouble(conv_sym, SYMBOL_BID);
         double ask = SymbolInfoDouble(conv_sym, SYMBOL_ASK);
         if(bid > 0 && ask > 0)
            conv = (bid + ask) / 2.0;
         else
            conv = bid > 0 ? bid : ask;
        }
      else
        {
         conv_sym = acc_currency + profit_currency;
         if(SymbolInfoDouble(conv_sym, SYMBOL_BID) > 0 || SymbolInfoDouble(conv_sym, SYMBOL_ASK) > 0)
           {
            double bid = SymbolInfoDouble(conv_sym, SYMBOL_BID);
            double ask = SymbolInfoDouble(conv_sym, SYMBOL_ASK);
            double rate = (bid > 0 && ask > 0) ? (bid + ask) / 2.0 : (bid > 0 ? bid : ask);
            if(rate > 0)
               conv = 1.0 / rate;
           }
        }
      if(conv > 0)
         tick_value *= conv;
     }

   if(tick_size <= 0 || tick_value <= 0) return 0;

   double value_per_lot = (sl_distance_price / tick_size) * tick_value;
   if(value_per_lot <= 0) return 0;

   double lot_size = risk_amount / value_per_lot;
   lot_size = MathFloor(lot_size / lot_step) * lot_step;
   lot_size = MathMax(lot_min, MathMin(lot_max, lot_size));

   return lot_size;
  }

//+------------------------------------------------------------------+
//| Find swing low in last N bars on H4                              |
//+------------------------------------------------------------------+
double FindSwingLow(int lookback)
  {
   double lowest = DBL_MAX;
   for(int i = 1; i <= lookback; i++)
     {
      double low = iLow(_Symbol, PERIOD_H4, i);
      if(low < lowest) lowest = low;
     }
   return lowest == DBL_MAX ? 0 : lowest;
  }

//+------------------------------------------------------------------+
//| Find swing high in last N bars on H4                            |
//+------------------------------------------------------------------+
double FindSwingHigh(int lookback)
  {
   double highest = -DBL_MAX;
   for(int i = 1; i <= lookback; i++)
     {
      double high = iHigh(_Symbol, PERIOD_H4, i);
      if(high > highest) highest = high;
     }
   return highest == -DBL_MAX ? 0 : highest;
  }

//+------------------------------------------------------------------+
//| Count positions not yet at breakeven                             |
//+------------------------------------------------------------------+
int CountUnprotectedPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double pos_open = PositionGetDouble(POSITION_PRICE_OPEN);
      double pos_sl   = PositionGetDouble(POSITION_SL);
      bool is_trailing = (MathAbs(pos_sl - pos_open) < _Point * 5);
      if(!is_trailing) count++;
     }
   return count;
  }
//+------------------------------------------------------------------+
