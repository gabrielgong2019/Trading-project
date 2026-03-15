//+------------------------------------------------------------------+
//|                                             USOIL_Trend_v1.mq5 |
//|                                                                  |
//|  Strategy: H4 Trend Filter + H1 Price Action Entry              |
//|  Instruments: USOIL                                            |
//|  Version: 1.0 - Port from XAUUSD_Trend_v1.3                     |
//+------------------------------------------------------------------+
#property copyright "Trading Project"
#property version   "1.00"
#property strict

input group "=== Trend Filter (H4) ==="
input int    H4_EMA_Fast     = 50;       // H4 Fast EMA period
input int    H4_EMA_Slow     = 200;      // H4 Slow EMA period
input int    H4_ADX_Period   = 14;       // H4 ADX period
input double H4_ADX_Min      = 25.0;    // Minimum ADX value to allow entry (0 = disabled)

input group "=== Entry (H1) ==="
input int    H1_EMA_Period   = 40;       // H1 EMA period for pullback
input double EMA_Touch_Buffer = 0.5;     // ATR multiplier: price must be within N*ATR of H1 EMA40
input double H1_ATR_Min      = 0.0;     // Min H1 ATR to allow entry — skip low-volatility chop (0 = disabled)

input group "=== Risk Management ==="
input double RiskPercent     = 1.0;      // Risk per trade (% of equity)
input double TP_RR           = 2.0;      // Take profit risk:reward ratio (first target)
input double ATR_Trail_Multi = 2.0;      // ATR multiplier for trailing stop
input int    ATR_Period      = 14;       // ATR period
input int    MaxUnprotected  = 2;        // Max positions not yet at breakeven

input group "=== Trade Settings ==="
input int    MagicNumber     = 20240003; // Magic number
input string TradeComment    = "USOIL_Trend_v1";
input int    SwingLookback   = 10;       // Bars to look back for swing high/low

input group "=== Circuit Breaker ==="
input double MaxDrawdownPct  = 20.0;    // Stop new trades if equity drops X% from peak
input int    CBCooldownDays  = 21;      // Cooldown period in days before resuming after CB trigger

//--- Global Variables
int      h4_ema_fast_handle, h4_ema_slow_handle;
int      h4_adx_handle;
int      h1_ema_handle, h1_atr_handle;
double   g_peak_equity       = 0.0;     // Highest equity seen since EA start
bool     g_cb_active         = false;   // Circuit breaker currently active
datetime g_cb_trigger_time   = 0;       // When circuit breaker was triggered

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   h4_ema_fast_handle = iMA(_Symbol, PERIOD_H4, H4_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   h4_ema_slow_handle = iMA(_Symbol, PERIOD_H4, H4_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   h4_adx_handle      = iADX(_Symbol, PERIOD_H4, H4_ADX_Period);
   h1_ema_handle      = iMA(_Symbol, PERIOD_H1, H1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   h1_atr_handle      = iATR(_Symbol, PERIOD_H1, ATR_Period);

   if(h4_ema_fast_handle == INVALID_HANDLE || h4_ema_slow_handle == INVALID_HANDLE ||
      h4_adx_handle == INVALID_HANDLE ||
      h1_ema_handle == INVALID_HANDLE || h1_atr_handle == INVALID_HANDLE)
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
   IndicatorRelease(h4_ema_fast_handle);
   IndicatorRelease(h4_ema_slow_handle);
   IndicatorRelease(h4_adx_handle);
   IndicatorRelease(h1_ema_handle);
   IndicatorRelease(h1_atr_handle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Only act on new H1 bar open
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
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
         g_peak_equity   = current_equity;  // Reset peak to current equity for fresh start
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

   double h4_ema50 = 0;
   int trend = GetH4Trend(h4_ema50);
   if(trend == 0)
      return;

   int signal = GetH1Signal(trend, h4_ema50);
   if(signal == 0)
      return;

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

   // ADX trend strength filter
   if(H4_ADX_Min > 0)
     {
      double adx_buf[];
      ArraySetAsSeries(adx_buf, true);
      if(CopyBuffer(h4_adx_handle, 0, 1, 1, adx_buf) < 1) return 0;
      if(adx_buf[0] < H4_ADX_Min) return 0;  // Trend lacks momentum
     }

   if(ema_fast[0] > ema_slow[0]) return  1;  // Bullish
   if(ema_fast[0] < ema_slow[0]) return -1;  // Bearish
   return 0;
  }

//+------------------------------------------------------------------+
//| Get H1 price action signal                                       |
//| Returns: 1=long signal, -1=short signal, 0=no signal            |
//+------------------------------------------------------------------+
int GetH1Signal(int trend, double h4_ema50)
  {
   double ema[], atr[];
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(h1_ema_handle, 0, 1, 3, ema) < 3) return 0;
   if(CopyBuffer(h1_atr_handle, 0, 1, 1, atr) < 1) return 0;

   // Signal candle is bar[1] (last closed bar)
   double sig_open  = iOpen(_Symbol,  PERIOD_H1, 1);
   double sig_high  = iHigh(_Symbol,  PERIOD_H1, 1);
   double sig_low   = iLow(_Symbol,   PERIOD_H1, 1);
   double sig_close = iClose(_Symbol, PERIOD_H1, 1);
   double prev_open  = iOpen(_Symbol,  PERIOD_H1, 2);
   double prev_close = iClose(_Symbol, PERIOD_H1, 2);

   double ema40   = ema[0];  // EMA40 at bar[1]
   double atr_val = atr[0];
   double touch_range = EMA_Touch_Buffer * atr_val;

   // Skip entry in low-volatility / choppy conditions
   if(H1_ATR_Min > 0 && atr_val < H1_ATR_Min) return 0;

   if(trend == 1)
     {
      // Price position filter: H1 close must be above H4 EMA50
      if(sig_close < h4_ema50) return 0;

      if(sig_low > ema40 + touch_range)   return 0;
      if(sig_high < ema40 - touch_range * 2) return 0;

      bool pb = IsBullishPinBar(sig_open, sig_high, sig_low, sig_close);
      bool eg = IsBullishEngulfing(prev_open, prev_close, sig_open, sig_close);
      if(pb || eg) return 1;
     }

   if(trend == -1)
     {
      // Price position filter: H1 close must be below H4 EMA50
      if(sig_close > h4_ema50) return 0;

      if(sig_high < ema40 - touch_range)   return 0;
      if(sig_low > ema40 + touch_range * 2) return 0;

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
   // Lower wick >= 60% of range, close in upper 40% of range, upper wick <= 20%
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
   // Upper wick >= 60% of range, close in lower 40% of range, lower wick <= 20%
   return (upper_wick >= total_range * 0.6 &&
           c <= h - total_range * 0.6 &&
           lower_wick <= total_range * 0.2);
  }

bool IsBullishEngulfing(double prev_o, double prev_c, double cur_o, double cur_c)
  {
   // Previous bar bearish, current bar bullish and body engulfs previous body
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
//| Open a new trade (no fixed TP — managed manually)               |
//+------------------------------------------------------------------+
void OpenTrade(int direction)
  {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(h1_atr_handle, 0, 1, 1, atr) < 1) return;

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

   // Ensure SL is at least 1x ATR — widen to ATR floor if swing point is too close
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

   // Ensure lot_size is even-splittable (at least 2x lot_step)
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
   request.tp           = 0;  // No fixed TP — EA manages exit
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
   if(CopyBuffer(h1_atr_handle, 0, 0, 1, atr) < 1) return;
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
      // Position is "trailing" once SL has reached breakeven or better.
      // BUY: SL >= open_price means protected. SELL: SL <= open_price means protected.
      bool is_trailing = (pos_type == POSITION_TYPE_BUY)
                         ? (current_sl >= open_price - _Point)
                         : (current_sl <= open_price + _Point);

      if(!is_trailing)
        {
         // --- Phase 1: waiting for 1:2 target to partial close ---
         double sl_dist  = MathAbs(open_price - current_sl);
         double tp_level = pos_type == POSITION_TYPE_BUY
                           ? open_price + sl_dist * TP_RR
                           : open_price - sl_dist * TP_RR;

         bool tp_reached = pos_type == POSITION_TYPE_BUY
                           ? current_bid >= tp_level
                           : current_ask <= tp_level;

         if(tp_reached)
           {
            // Step 1: Close 50% of position
            double close_vol = NormalizeVolume(current_vol / 2.0);
            if(close_vol > 0 && PartialClose(ticket, pos_type, close_vol))
              {
               // Step 2: Move SL to breakeven — this also marks entry into trailing phase
               if(PositionSelectByTicket(ticket))
                  ModifyPosition(ticket, open_price, 0);
               Print("Half-close done, SL moved to breakeven. ticket=", ticket);
              }
           }
        }
      else
        {
         // --- Phase 2: ATR trailing stop on remaining 50% ---
         if(pos_type == POSITION_TYPE_BUY)
           {
            double trail_sl = NormalizeDouble(current_bid - ATR_Trail_Multi * atr_val, _Digits);
            // Only move SL up, and only if above breakeven
            if(trail_sl > current_sl && trail_sl > open_price)
               ModifyPosition(ticket, trail_sl, 0);
           }
         else
           {
            double trail_sl = NormalizeDouble(current_ask + ATR_Trail_Multi * atr_val, _Digits);
            // Only move SL down, and only if below breakeven
            if(trail_sl < current_sl && trail_sl < open_price)
               ModifyPosition(ticket, trail_sl, 0);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Partial close: close specified volume of a position             |
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
//| Calculate lot size based on 1% risk                              |
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

   if(tick_size <= 0 || tick_value <= 0) return 0;

   double value_per_lot = (sl_distance_price / tick_size) * tick_value;
   if(value_per_lot <= 0) return 0;

   double lot_size = risk_amount / value_per_lot;
   lot_size = MathFloor(lot_size / lot_step) * lot_step;
   lot_size = MathMax(lot_min, MathMin(lot_max, lot_size));

   return lot_size;
  }

//+------------------------------------------------------------------+
//| Find swing low in last N bars on H1                              |
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
//| Find swing high in last N bars on H1                             |
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
      // Strict breakeven check: slot is only freed when SL is exactly at open price.
      // After trailing moves SL past open_price, position re-occupies a slot,
      // preventing new entries at extended prices (position cooldown).
      bool is_trailing = (MathAbs(pos_sl - pos_open) < _Point * 5);
      if(!is_trailing) count++;
     }
   return count;
  }
//+------------------------------------------------------------------+
