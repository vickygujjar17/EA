//+------------------------------------------------------------------+
//|                                                 CTradeManager.mqh |
//|             Module 6 â€” Unlimited Trend Runner (Step-Up Trail)      |
//|                             Otto EA - Institutional Grade   |
//+------------------------------------------------------------------+
#property copyright "Otto EA"
#property version   "1.00"

#ifndef __TRADE_MANAGER__
#define __TRADE_MANAGER__

#include "CommonDefines.mqh"
#include "CRiskManager.mqh"
#include "COrderManager.mqh"
#include "CSniperBlock.mqh"

//+------------------------------------------------------------------+
//| CTradeManager class                                               |
//| Step-up trailing stop: Half-Risk â†’ Breakeven â†’ ATR Trail           |
//+------------------------------------------------------------------+
class CTradeManager
  {
private:
   string            m_symbol;
   CRiskManager     *m_riskManager;
   COrderManager    *m_orderManager;
   CSniperBlock     *m_sniperBlock;

   // --- Statistics ---
   int               m_tradesManaged;
   int               m_halfRiskTriggers;
   int               m_breakevenTriggers;
   int               m_trailActivations;
   int               m_stopsHit;

   //+------------------------------------------------------------------+
   //| Calculates current profit as R-multiple                             |
   //| Positive R = profit, Negative R = loss                             |
   //+------------------------------------------------------------------+
   double            GetCurrentRMultiple(SActiveTrade &trade)
     {
      if(trade.initialRiskAmount <= 0)
         return 0.0;

      double currentPrice;
      double entryPrice  = trade.entryPrice;
      double currentProfit;

      if(trade.direction == DIR_LONG)
        {
         currentPrice  = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         currentProfit = currentPrice - entryPrice;
        }
      else
        {
         currentPrice  = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         currentProfit = entryPrice - currentPrice;
        }

      // Convert profit in price to profit in money
      double tickSize    = m_riskManager.GetTickSize();
      double tickValue   = m_riskManager.GetTickValuePerLot();
      double profitPoints = currentProfit / tickSize;
      double profitMoney  = profitPoints * tickValue * trade.lotSize;

      double rMultiple = profitMoney / trade.initialRiskAmount;

      return rMultiple;
     }

   //+------------------------------------------------------------------+
   //| Gets the spread in price units for breakeven calculation           |
   //+------------------------------------------------------------------+
   double            GetSpreadPrice(void)
     {
      return SymbolInfoDouble(m_symbol, SYMBOL_ASK) -
             SymbolInfoDouble(m_symbol, SYMBOL_BID);
     }

   //+------------------------------------------------------------------+
   //| Updates the high watermark for trail tracking                      |
   //+------------------------------------------------------------------+
   void              UpdateHighWatermark(SActiveTrade &trade)
     {
      double currentPrice;

      if(trade.direction == DIR_LONG)
         currentPrice = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      else
         currentPrice = SymbolInfoDouble(m_symbol, SYMBOL_ASK);

      if(trade.direction == DIR_LONG)
        {
         if(currentPrice > trade.highestPriceSinceEntry)
            trade.highestPriceSinceEntry = currentPrice;
        }
      else
        {
         if(currentPrice < trade.highestPriceSinceEntry)
            trade.highestPriceSinceEntry = currentPrice;
        }
     }

   //+------------------------------------------------------------------+
   //| Gets the current ATR for trailing stop distance                    |
   //+------------------------------------------------------------------+
   double            GetCurrentATR(void)
     {
      return m_sniperBlock.GetATR();
     }

   //+------------------------------------------------------------------+
   //| Step 1: Move SL to -0.5R (half risk locked in)                     |
   //+------------------------------------------------------------------+
   bool              Step1_HalfRisk(SActiveTrade &trade)
     {
      double halfRiskDistance = trade.initialSLDistance * 0.5;
      double newSL;

      if(trade.direction == DIR_LONG)
        {
         newSL = trade.entryPrice - halfRiskDistance;
        }
      else
        {
         newSL = trade.entryPrice + halfRiskDistance;
        }

      // Never move backward
      if(trade.direction == DIR_LONG)
        {
         if(newSL <= trade.currentTrailSL)
            return false;
        }
      else
        {
         if(newSL >= trade.currentTrailSL)
            return false;
        }

      // Modify SL on the broker
      if(m_orderManager.ModifyStopLoss(trade.ticket, newSL))
        {
         trade.currentTrailSL = newSL;
         trade.trailStep      = STEP_HALF_RISK;
         m_halfRiskTriggers++;

         if(EnableLogging)
           {
            Print("[TradeManager] STEP 1 (Half-Risk): ticket=", trade.ticket,
                  " | New SL=", DoubleToString(newSL, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)),
                  " | Risk now -0.5R");
           }

         return true;
        }

      return false;
     }

   //+------------------------------------------------------------------+
   //| Step 2: Move SL to breakeven (entry + spread)                      |
   //+------------------------------------------------------------------+
   bool              Step2_Breakeven(SActiveTrade &trade)
     {
      double spread = GetSpreadPrice();
      double newSL;

      if(trade.direction == DIR_LONG)
        {
         // For long: SL = entry + spread (just above entry to cover costs)
         newSL = trade.entryPrice + spread;
        }
      else
        {
         // For short: SL = entry - spread (just below entry)
         newSL = trade.entryPrice - spread;
        }

      // Never move backward
      if(trade.direction == DIR_LONG)
        {
         if(newSL <= trade.currentTrailSL)
            return false;
        }
      else
        {
         if(newSL >= trade.currentTrailSL)
            return false;
        }

      if(m_orderManager.ModifyStopLoss(trade.ticket, newSL))
        {
         trade.currentTrailSL = newSL;
         trade.trailStep      = STEP_BREAKEVEN;
         m_breakevenTriggers++;

         if(EnableLogging)
           {
            Print("[TradeManager] STEP 2 (Breakeven): ticket=", trade.ticket,
                  " | New SL=", DoubleToString(newSL, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)),
                  " | Risk now 0R (breakeven)");
           }

         return true;
        }

      return false;
     }

   //+------------------------------------------------------------------+
   //| Step 3: Activate dynamic ATR trailing stop                          |
   //+------------------------------------------------------------------+
   bool              Step3_ActivateTrail(SActiveTrade &trade)
     {
      double atr = GetCurrentATR();
      if(atr <= 0)
         return false;

      // Update highest price since entry to ensure we trail from the peak
      UpdateHighWatermark(trade);

      double trailDistance = ATRTrailDistance * atr;
      double newSL;

      if(trade.direction == DIR_LONG)
        {
         newSL = trade.highestPriceSinceEntry - trailDistance;
        }
      else
        {
         newSL = trade.highestPriceSinceEntry + trailDistance;
        }

      // Never move backward
      if(trade.direction == DIR_LONG)
        {
         if(newSL <= trade.currentTrailSL)
            return false;
        }
      else
        {
         if(newSL >= trade.currentTrailSL)
            return false;
        }

      if(m_orderManager.ModifyStopLoss(trade.ticket, newSL))
        {
         trade.currentTrailSL = newSL;
         trade.trailStep      = STEP_TRAILING;
         m_trailActivations++;

         if(EnableLogging)
           {
            Print("[TradeManager] STEP 3 (ATR Trail ACTIVE): ticket=", trade.ticket,
                  " | ATR=", DoubleToString(atr, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)),
                  " | TrailDist=", DoubleToString(trailDistance, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)),
                  " | SL=", DoubleToString(newSL, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)));
           }

         return true;
        }

      return false;
     }

   //+------------------------------------------------------------------+
   //| Continues dynamic trailing after activation                        |
   //+------------------------------------------------------------------+
   bool              ContinueTrail(SActiveTrade &trade)
     {
      double atr = GetCurrentATR();
      if(atr <= 0)
         return false;

      // Update watermark on every call to ensure we have latest high/low
      UpdateHighWatermark(trade);

      double trailDistance = ATRTrailDistance * atr;
      double newSL;

      if(trade.direction == DIR_LONG)
        {
         newSL = trade.highestPriceSinceEntry - trailDistance;
        }
      else
        {
         newSL = trade.highestPriceSinceEntry + trailDistance;
        }

      // CRITICAL: Never move backward â€” only tighten
      if(trade.direction == DIR_LONG)
        {
         if(newSL <= trade.currentTrailSL + SymbolInfoDouble(m_symbol, SYMBOL_POINT))
            return false; // Not enough improvement
        }
      else
        {
         if(newSL >= trade.currentTrailSL - SymbolInfoDouble(m_symbol, SYMBOL_POINT))
            return false;
        }

      if(m_orderManager.ModifyStopLoss(trade.ticket, newSL))
        {
         trade.currentTrailSL = newSL;

         if(EnableLogging)
           {
            // Only log significant moves to avoid spam
            static datetime lastTrailLog = 0;
            datetime now = TimeCurrent();
            if(now - lastTrailLog >= 300) // Every 5 minutes max
              {
               Print("[TradeManager] Trail UPDATE: ticket=", trade.ticket,
                     " | SLâ†’", DoubleToString(newSL, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)));
               lastTrailLog = now;
              }
           }

         return true;
        }

      return false;
     }

   //+------------------------------------------------------------------+
   //| Checks if price has hit the trailing stop level                    |
   //+------------------------------------------------------------------+
   bool              IsTrailingStopHit(SActiveTrade &trade)
     {
      double currentPrice;

      if(trade.direction == DIR_LONG)
        {
         currentPrice = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         return (currentPrice <= trade.currentTrailSL);
        }
      else
        {
         currentPrice = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         return (currentPrice >= trade.currentTrailSL);
        }
     }

   //+------------------------------------------------------------------+
   //| Prints detailed trade status for logging                           |
   //+------------------------------------------------------------------+
   void              LogTradeStatus(SActiveTrade &trade, double rMultiple)
     {
      if(!EnableLogging)
         return;

      double currentPrice;
      if(trade.direction == DIR_LONG)
         currentPrice = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      else
         currentPrice = SymbolInfoDouble(m_symbol, SYMBOL_ASK);

      double profitPoints = MathAbs(currentPrice - trade.entryPrice) /
                            m_riskManager.GetTickSize();

      Print("[TradeManager] STATUS: ticket=", trade.ticket,
            " | R=", DoubleToString(rMultiple, 2), "R",
            " | Step=", EnumToString(trade.trailStep),
            " | Profit=", DoubleToString(profitPoints, 1), "pts",
            " | SL=", DoubleToString(trade.currentTrailSL, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS)));
     }

public:
   //+------------------------------------------------------------------+
   //| Constructor                                                       |
   //+------------------------------------------------------------------+
                     CTradeManager(void)
     {
      m_symbol           = "";
      m_riskManager      = NULL;
      m_orderManager     = NULL;
      m_sniperBlock      = NULL;
      m_tradesManaged    = 0;
      m_halfRiskTriggers = 0;
      m_breakevenTriggers= 0;
      m_trailActivations = 0;
      m_stopsHit         = 0;
     }

   //+------------------------------------------------------------------+
   //| Destructor                                                        |
   //+------------------------------------------------------------------+
                    ~CTradeManager(void)
     {
     }

   //+------------------------------------------------------------------+
   //| Initialize                                                        |
   //+------------------------------------------------------------------+
   bool              Initialize(string            symbol,
                                CRiskManager     *riskManager,
                                COrderManager    *orderManager,
                                CSniperBlock     *sniperBlock)
     {
      m_symbol       = symbol;
      m_riskManager  = riskManager;
      m_orderManager = orderManager;
      m_sniperBlock  = sniperBlock;

      if(EnableLogging)
        {
         Print("[TradeManager] Initialized for ", m_symbol,
               " | RR Steps: ", RR_Step1, "R / ", RR_Step2, "R / ", RR_Step3, "R",
               " | Trail ATR Distance: ", ATRTrailDistance, "x");
        }

      return true;
     }

   //+------------------------------------------------------------------+
   //| Main update â€” manages the trailing stop for active trades          |
   //+------------------------------------------------------------------+
   void              Update(void)
     {
      if(!m_orderManager.HasActiveTrade())
         return;

      m_tradesManaged++;

      SActiveTrade trade;
      if(!m_orderManager.GetActiveTradeRef(trade))
         return;

      // Verify the position still exists
      if(!PositionSelectByTicket(trade.ticket))
        {
         // Position was closed externally
         if(EnableLogging)
            Print("[TradeManager] Position ", trade.ticket, " no longer exists â€” clearing state");

         // OrderManager will sync on next call
         return;
        }

      // Update high watermark
      UpdateHighWatermark(trade);

      // Calculate current R-multiple
      double rMultiple = GetCurrentRMultiple(trade);

      // Log trade status periodically
      static int tickCounter = 0;
      tickCounter++;
      if(tickCounter % 100 == 0) // Every ~100 ticks
         LogTradeStatus(trade, rMultiple);

      // --- Step-Up Trailing Stop Logic ---
      switch(trade.trailStep)
        {
         case STEP_NONE:
           // Check if we've reached Step 1 (1.5R)
           if(rMultiple >= RR_Step1)
             {
              Step1_HalfRisk(trade);
              m_orderManager.SetActiveTradeStep(STEP_HALF_RISK);
             }
           break;

         case STEP_HALF_RISK:
           // Check if we've reached Step 2 (2.0R)
           if(rMultiple >= RR_Step2)
             {
              Step2_Breakeven(trade);
              m_orderManager.SetActiveTradeStep(STEP_BREAKEVEN);
             }
           break;

         case STEP_BREAKEVEN:
           // Check if we've reached Step 3 (2.7R) â†’ activate trail
           if(rMultiple >= RR_Step3)
             {
              Step3_ActivateTrail(trade);
              m_orderManager.SetActiveTradeStep(STEP_TRAILING);
             }
           break;

         case STEP_TRAILING:
           // Continue dynamic trailing
           ContinueTrail(trade);
           break;
        }

      // Check if trailing stop has been hit
      // Note: Actual SL execution is handled by the broker.
      // This check provides additional safety.
      if(IsTrailingStopHit(trade) && trade.trailStep > STEP_NONE)
        {
         if(EnableLogging)
           {
            Print("[TradeManager] STOP HIT: ticket=", trade.ticket,
                  " | R at exit=", DoubleToString(rMultiple, 2), "R");
           }
         m_stopsHit++;
         // The broker will close the position at SL; we don't need to force-close
        }
     }

   //+------------------------------------------------------------------+
   //| Force-manages a trade that is not being tracked                    |
   //| Called on init to sync state for existing positions                |
   //+------------------------------------------------------------------+
   void              SyncTradeState(void)
     {
      if(!m_orderManager.HasActiveTrade())
         return;

      SActiveTrade trade;
      if(!m_orderManager.GetActiveTradeRef(trade))
         return;

      double rMultiple = GetCurrentRMultiple(trade);

      // Determine which step we should be in
      if(rMultiple >= RR_Step3)
         trade.trailStep = STEP_TRAILING;
      else if(rMultiple >= RR_Step2)
         trade.trailStep = STEP_BREAKEVEN;
      else if(rMultiple >= RR_Step1)
         trade.trailStep = STEP_HALF_RISK;
      else
         trade.trailStep = STEP_NONE;

      m_orderManager.SetActiveTradeStep(trade.trailStep);

      // Update high watermark
      UpdateHighWatermark(trade);
      m_orderManager.SetActiveTradeHighWatermark(trade.highestPriceSinceEntry);

      if(EnableLogging)
        {
         Print("[TradeManager] Trade state SYNCED: ticket=", trade.ticket,
               " | R=", DoubleToString(rMultiple, 2),
               " | Step=", EnumToString(trade.trailStep));
        }
     }

   //+------------------------------------------------------------------+
   //| Returns the number of trades managed so far                        |
   //+------------------------------------------------------------------+
   int               GetTradesManaged(void) const
     {
      return m_tradesManaged;
     }

   //+------------------------------------------------------------------+
   //| Statistics getters                                                 |
   //+------------------------------------------------------------------+
   int               GetHalfRiskTriggers(void) const
     {
      return m_halfRiskTriggers;
     }
   int               GetBreakevenTriggers(void) const
     {
      return m_breakevenTriggers;
     }
   int               GetTrailActivations(void) const
     {
      return m_trailActivations;
     }
   int               GetStopsHit(void) const
     {
      return m_stopsHit;
     }
  };

//+------------------------------------------------------------------+
#endif  // __TRADE_MANAGER__
