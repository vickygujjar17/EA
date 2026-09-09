//+------------------------------------------------------------------+
//|                                                 COrderManager.mqh |
//|                Module 5 â€” Order Execution, Slippage, Hedging       |
//|                             Otto EA - Institutional Grade   |
//+------------------------------------------------------------------+
#property copyright "Otto EA"
#property version   "1.00"

#ifndef __ORDER_MANAGER__
#define __ORDER_MANAGER__

#include <Trade\Trade.mqh>
#include "CommonDefines.mqh"
#include "CRiskManager.mqh"
#include "CSniperBlock.mqh"
#include "CCorrelationFilter.mqh"

//+------------------------------------------------------------------+
//| COrderManager class                                               |
//+------------------------------------------------------------------+
class COrderManager
  {
private:
   string            m_symbol;
   CRiskManager     *m_riskManager;
   CSniperBlock     *m_sniperBlock;
   CCorrelationFilter *m_correlationFilter;
   CTrade             m_trade;            // MQL5 trade object for order/position modification

   // --- Active trade tracking ---
   SActiveTrade      m_activeTrade;
   bool              m_hasActiveTrade;
   ENUM_TRADE_DIRECTION m_activeDirection;

   // --- Pending limit order tracking ---
   ulong             m_pendingLimitTickets[];
   int               m_pendingLimitCount;

   // --- Statistics ---
   int               m_ordersPlaced;
   int               m_ordersFilled;
   int               m_ordersRejected;
   int               m_reversalsExecuted;
   int               m_retryCount;

   // --- MODULE 3: Mutual Exclusion Lock (Reversal State Machine) ---
   bool              m_reversalInProgress;
   SSniperBlock      m_reversalTargetBlock;
   ENUM_TRADE_DIRECTION m_reversalTargetDir;
   datetime          m_reversalStartTime;

   // --- FIX 1: Physical Time-Lock (Throttle) ---
   datetime          m_lastOrderTime;         // Server time of last OrderSend attempt

   //+------------------------------------------------------------------+
   //| FIX 1: Check if 3 seconds have elapsed since last OrderSend       |
   //+------------------------------------------------------------------+
   bool              CheckOrderTimeLock(void)
     {
      if(TimeCurrent() - m_lastOrderTime < 3)
        {
         if(EnableLogging)
            Print("[OrderManager] TIME-LOCK: < 3s since last OrderSend â€” throttled");
         return false;
        }
      // Set lock BEFORE allowing OrderSend â€” blocks subsequent microsecond ticks
      m_lastOrderTime = TimeCurrent();
      return true;
     }

   //+------------------------------------------------------------------+
   //| Sets new SL/TP for an open position                               |
   //+------------------------------------------------------------------+
   bool              ModifyPosition(ulong ticket, double newSL, double newTP, double entryPrice)
     {
      // Ensure trailing stops are only moved in the profitable direction or to breakeven
      CPositionInfo pos;
      if(!pos.SelectByTicket(ticket))
        {
         if(EnableLogging)
            Print("[OrderManager] ERROR: Could not select position #", ticket, " for modification.");
         return false;
        }

      double currentSL = pos.StopLoss();
      double currentPrice = SymbolInfoDouble(m_symbol, SYMBOL_BID); // For short positions
      if(pos.PositionType() == POSITION_TYPE_BUY) currentPrice = SymbolInfoDouble(m_symbol, SYMBOL_ASK); // For long positions

      // For BUY positions, SL must only increase or stay same
      if(pos.PositionType() == POSITION_TYPE_BUY)
        {
         if(newSL < currentSL)
           {
            if(EnableLogging)
               Print("[OrderManager] WARNING: Attempted to move SL for BUY position #", ticket, " to a lower price (",
                     DoubleToString(newSL, Digits()), "). Ignoring.");
            newSL = currentSL; // Keep current SL if new one is lower
           }
        }
      // For SELL positions, SL must only decrease or stay same
      else if(pos.PositionType() == POSITION_TYPE_SELL)
        {
         if(newSL > currentSL)
           {
            if(EnableLogging)
               Print("[OrderManager] WARNING: Attempted to move SL for SELL position #", ticket, " to a higher price (",
                     DoubleToString(newSL, Digits()), "). Ignoring.");
            newSL = currentSL; // Keep current SL if new one is higher
           }
        }

      // Ensure SL is never worse than entry for breakeven/profit protection
      if(pos.PositionType() == POSITION_TYPE_BUY && newSL < entryPrice)
         newSL = entryPrice; // Move to breakeven or better
      if(pos.PositionType() == POSITION_TYPE_SELL && newSL > entryPrice)
         newSL = entryPrice; // Move to breakeven or better

      if(!m_trade.PositionModify(ticket, newSL, newTP))
        {
         if(EnableLogging)
            Print("[OrderManager] ERROR: Failed to modify position #", ticket,
                  " | Result: ", m_trade.ResultRetcode(), "-", m_trade.ResultDeal(),
                  " | New SL: ", DoubleToString(newSL, Digits()), " New TP: ", DoubleToString(newTP, Digits()));
         return false;
        }
      if(EnableLogging)
         Print("[OrderManager] Position #", ticket, " modified: SL=", DoubleToString(newSL, Digits()), ", TP=", DoubleToString(newTP, Digits()));
      return true;
     }

   bool              ValidateStopDistance(double price, double sl, bool isLong)
     {
      double stopsLevel = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) *
                          SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double freezLevel = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL) *
                          SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double maxLevel = MathMax(stopsLevel, freezLevel);
      double slDistance = MathAbs(price - sl);
      if(slDistance < maxLevel)
        { Print("[OrderManager] WARNING: SL distance ", DoubleToString(slDistance, Digits()), " < min required ", DoubleToString(maxLevel, Digits())); return false; }
      return true;
     }

   double            AdjustSLToMinimum(double price, double sl, bool isLong)
     {
      double stopsLevel = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) *
                          SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double freezLevel = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL) *
                          SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double minDist = MathMax(stopsLevel, freezLevel) * 1.1;
      if(isLong) { if(price - sl < minDist) return price - minDist; }
      else { if(sl - price < minDist) return price + minDist; }
      return sl;
     }

   double            GetAsk(void) { return SymbolInfoDouble(m_symbol, SYMBOL_ASK); }
   double            GetBid(void) { return SymbolInfoDouble(m_symbol, SYMBOL_BID); }

   double            GetCurrentSpread(void)
     {
      return (GetAsk() - GetBid()) / SymbolInfoDouble(m_symbol, SYMBOL_POINT);
     }

   bool              IsSpreadAcceptable(void)
     {
      double spread = GetCurrentSpread();
      if(spread > MaxSpreadPoints)
        {
         if(EnableLogging) Print("[OrderManager] Spread too wide: ", DoubleToString(spread, 1), " > ", MaxSpreadPoints);
         return false;
        }
      return true;
     }

   //+------------------------------------------------------------------+
   //| Core OrderSend with throttle + retry                             |
   //+------------------------------------------------------------------+
   bool              SendOrderWithRetry(MqlTradeRequest  &request,
                                        MqlTradeResult   &result)
     {
      // FIX 1: Hard time-lock â€” blocks all OrderSend calls within 3 seconds
      if(!CheckOrderTimeLock()) return false;

      ZeroMemory(result);
      int attempts = 0;
      bool success = false;
      while(attempts < MaxRetries && !success)
        {
         attempts++;
         request.deviation = MaxSlippage;
         request.magic     = MagicNumber;
         request.comment   = TradeComment;
         ResetLastError();
         if(OrderSend(request, result))
           {
            if(result.retcode == TRADE_RETCODE_DONE ||
               result.retcode == TRADE_RETCODE_DONE_PARTIAL ||
               result.retcode == TRADE_RETCODE_PLACED)
              { success = true; m_ordersPlaced++; break; }
            else
              {
               string retMsg = GetTradeRetcodeString(result.retcode);
               Print("[OrderManager] OrderSend result: ", retMsg, " (code=", result.retcode, ")");
               if(result.retcode == TRADE_RETCODE_REQUOTE ||
                  result.retcode == TRADE_RETCODE_PRICE_CHANGED ||
                  result.retcode == TRADE_RETCODE_PRICE_OFF)
                 {
                  if(request.type == ORDER_TYPE_BUY || request.type == ORDER_TYPE_BUY_LIMIT || request.type == ORDER_TYPE_BUY_STOP)
                     request.price = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
                  Sleep(RetryDelayMs); m_retryCount++; continue;
                 }
               else if(result.retcode == TRADE_RETCODE_CONNECTION)
                 { Print("[OrderManager] Connection issue â€” retrying..."); Sleep(RetryDelayMs * 2); m_retryCount++; continue; }
               else
                 { Print("[OrderManager] FATAL: Non-retryable error: ", retMsg); m_ordersRejected++; return false; }
              }
           }
         else
           {
            int error = GetLastError();
            Print("[OrderManager] OrderSend FAILED (attempt ", attempts, "/", MaxRetries, "): error=", error);
            if(error == TRADE_RETCODE_REQUOTE || error == TRADE_RETCODE_PRICE_CHANGED ||
               error == TRADE_RETCODE_TIMEOUT || error == TRADE_RETCODE_PRICE_OFF)
              {
               if(request.type == ORDER_TYPE_BUY || request.type == ORDER_TYPE_BUY_LIMIT || request.type == ORDER_TYPE_BUY_STOP)
                  request.price = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
               Sleep(RetryDelayMs); m_retryCount++; continue;
              }
            else if(error == TRADE_RETCODE_NO_MONEY)
              { Print("[OrderManager] FATAL: Not enough money"); m_ordersRejected++; return false; }
            else
              { Print("[OrderManager] FATAL: OrderSend error ", error); m_ordersRejected++; return false; }
           }
        }
      if(!success) { Print("[OrderManager] OrderSend exhausted all ", MaxRetries, " retries"); m_ordersRejected++; }
      return success;
     }

   string            GetTradeRetcodeString(uint retcode)
     {
      switch(retcode)
        {
         case TRADE_RETCODE_DONE:            return "DONE";
         case TRADE_RETCODE_DONE_PARTIAL:    return "DONE_PARTIAL";
         case TRADE_RETCODE_PLACED:          return "PLACED";
         case TRADE_RETCODE_REQUOTE:         return "REQUOTE";
         case TRADE_RETCODE_REJECT:          return "REJECT";
         case TRADE_RETCODE_CANCEL:          return "CANCEL";
         case TRADE_RETCODE_PRICE_CHANGED:   return "PRICE_CHANGED";
         case TRADE_RETCODE_PRICE_OFF:       return "PRICE_OFF";
         case TRADE_RETCODE_CONNECTION:      return "CONNECTION";
         case TRADE_RETCODE_CLIENT_DISABLES_AT: return "CLIENT_DISABLES_AT";
         case TRADE_RETCODE_INVALID_VOLUME:  return "INVALID_VOLUME";
         case TRADE_RETCODE_INVALID_PRICE:   return "INVALID_PRICE";
         case TRADE_RETCODE_INVALID_STOPS:   return "INVALID_STOPS";
         case TRADE_RETCODE_NO_MONEY:        return "NO_MONEY";
         case TRADE_RETCODE_MARKET_CLOSED:   return "MARKET_CLOSED";
         case TRADE_RETCODE_FROZEN:          return "FROZEN";
         default:                            return "UNKNOWN(" + IntegerToString(retcode) + ")";
        }
     }

   ENUM_ORDER_TYPE   GetOrderTypeForBlock(SSniperBlock &block)
     { return (block.type == BLOCK_SUPPORT) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT; }

   ENUM_TRADE_DIRECTION GetDirectionForBlock(SSniperBlock &block)
     { return (block.type == BLOCK_SUPPORT) ? DIR_LONG : DIR_SHORT; }

   //+------------------------------------------------------------------+
   //| Opens reversal position after close is confirmed                  |
   //+------------------------------------------------------------------+
   bool              OpenReversalPosition(SSniperBlock &targetBlock)
     {
      ENUM_ORDER_TYPE orderType;
      double entryPrice;
      double stopLoss = targetBlock.initialSL;
      bool   isLong;
      if(targetBlock.type == BLOCK_SUPPORT)
        { orderType = ORDER_TYPE_BUY; entryPrice = GetAsk(); isLong = true; }
      else
        { orderType = ORDER_TYPE_SELL; entryPrice = GetBid(); isLong = false; }
      double adjustedSL = stopLoss;
      if(!ValidateStopDistance(entryPrice, adjustedSL, isLong))
         adjustedSL = AdjustSLToMinimum(entryPrice, adjustedSL, isLong);
      double lotSize = m_riskManager.CalculateLotSize(entryPrice, adjustedSL);
      if(lotSize <= 0) { Print("[OrderManager] Reversal aborted: lotSize zero"); return false; }
      if(!m_riskManager.HasSufficientMargin(lotSize)) { Print("[OrderManager] Reversal insufficient margin"); return false; }
      MqlTradeRequest request; MqlTradeResult result;
      ZeroMemory(request);
      request.action   = TRADE_ACTION_DEAL;
      request.symbol   = m_symbol;
      request.type     = orderType;
      request.volume   = lotSize;
      request.price    = NormalizeDouble(entryPrice, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));
      request.sl       = NormalizeDouble(adjustedSL, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));
      request.tp       = 0;
      request.deviation = MaxSlippage;
      request.magic    = MagicNumber;
      request.comment  = TradeComment + "_REV";
      request.type_filling = ORDER_FILLING_RETURN;
      if(SendOrderWithRetry(request, result))
        {
         m_activeTrade.ticket             = result.order;
         m_activeTrade.direction          = GetDirectionForBlock(targetBlock);
         m_activeTrade.entryPrice         = result.price;
         m_activeTrade.initialSL          = adjustedSL;
         m_activeTrade.initialSLDistance  = targetBlock.initialSLDistance;
         m_activeTrade.lotSize            = lotSize;
         m_activeTrade.openTime           = TimeCurrent();
         m_activeTrade.trailStep          = STEP_NONE;
         m_activeTrade.sourceBlock        = targetBlock;
         m_activeTrade.currentTrailSL     = adjustedSL;
         if(m_activeTrade.direction == DIR_LONG)
            m_activeTrade.highestPriceSinceEntry = result.price;
         else
            m_activeTrade.highestPriceSinceEntry = result.price;
         double tickValue = m_riskManager.GetTickValuePerLot();
         double tickSize  = m_riskManager.GetTickSize();
         double slPoints = targetBlock.initialSLDistance / tickSize;
         m_activeTrade.initialRiskAmount = slPoints * tickValue * lotSize;
         m_hasActiveTrade  = true;
         m_activeDirection = m_activeTrade.direction;
         m_reversalsExecuted++;
         if(EnableLogging)
            Print("[OrderManager] REVERSAL COMPLETED: ticket=", result.order,
                  " | Dir=", (m_activeDirection == DIR_LONG ? "LONG" : "SHORT"),
                  " | Entry=", DoubleToString(result.price, Digits()));
         return true;
        }
      Print("[OrderManager] Reversal FAILED: Could not place market order");
      return false;
     }

public:
   //+------------------------------------------------------------------+
   //| Closes a position by ticket                                       |
   //+------------------------------------------------------------------+
   bool              ClosePosition(ulong ticket)
     {
      if(!PositionSelectByTicket(ticket))
        { Print("[OrderManager] Cannot close position: ticket ", ticket, " not found"); return false; }
      MqlTradeRequest closeReq; MqlTradeResult closeRes;
      ZeroMemory(closeReq);
      closeReq.action   = TRADE_ACTION_DEAL;
      closeReq.symbol   = m_symbol;
      closeReq.position = ticket;
      double posVolume = PositionGetDouble(POSITION_VOLUME);
      long   posType   = PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY) { closeReq.type = ORDER_TYPE_SELL; closeReq.price = GetBid(); }
      else { closeReq.type = ORDER_TYPE_BUY; closeReq.price = GetAsk(); }
      closeReq.volume   = posVolume;
      closeReq.deviation = MaxSlippage;
      closeReq.magic    = MagicNumber;
      closeReq.comment  = TradeComment + "_CLOSE";
      if(SendOrderWithRetry(closeReq, closeRes))
        {
         if(EnableLogging) Print("[OrderManager] Position CLOSED: ticket=", ticket, " volume=", DoubleToString(posVolume, 2));
         if(m_hasActiveTrade && m_activeTrade.ticket == ticket)
           { m_hasActiveTrade = false; m_activeDirection = DIR_NONE; }
         return true;
        }
      Print("[OrderManager] FAILED to close position: ticket=", ticket);
      return false;
     }

   bool              ModifyStopLoss(ulong ticket, double newSL)
     {
      if(!PositionSelectByTicket(ticket)) { Print("[OrderManager] Cannot modify SL: position ", ticket, " not found"); return false; }
      double currentSL = PositionGetDouble(POSITION_SL);
      long   posType   = PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY) { if(newSL <= currentSL + SymbolInfoDouble(m_symbol, SYMBOL_POINT)) return false; }
      else { if(newSL >= currentSL - SymbolInfoDouble(m_symbol, SYMBOL_POINT)) return false; }
      MqlTradeRequest modReq; MqlTradeResult modRes;
      ZeroMemory(modReq);
      modReq.action   = TRADE_ACTION_SLTP;
      modReq.symbol   = m_symbol;
      modReq.position = ticket;
      modReq.sl       = newSL;
      modReq.tp       = PositionGetDouble(POSITION_TP);
      modReq.magic    = MagicNumber;
      modReq.comment  = TradeComment + "_MODSL";
      if(SendOrderWithRetry(modReq, modRes))
        { if(EnableLogging) Print("[OrderManager] SL MODIFIED: ticket=", ticket, " newSL=", DoubleToString(newSL, Digits())); return true; }
      return false;
     }

   bool              DeleteOrder(ulong ticket)
     {
      if(!OrderSelect(ticket)) return false;
      MqlTradeRequest delReq; MqlTradeResult delRes;
      ZeroMemory(delReq);
      delReq.action = TRADE_ACTION_REMOVE;
      delReq.order  = ticket;
      delReq.magic  = MagicNumber;
      delReq.comment= TradeComment + "_DEL";
      if(SendOrderWithRetry(delReq, delRes))
        { if(EnableLogging) Print("[OrderManager] Order DELETED: ticket=", ticket); return true; }
      return false;
     }

   bool              FindActivePosition(ulong &outTicket, ENUM_TRADE_DIRECTION &outDir)
     {
      outTicket = 0; outDir = DIR_NONE;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(PositionSelectByTicket(PositionGetTicket(i)))
           {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == m_symbol)
              {
               outTicket = PositionGetInteger(POSITION_TICKET);
               long posType = PositionGetInteger(POSITION_TYPE);
               outDir = (posType == POSITION_TYPE_BUY) ? DIR_LONG : DIR_SHORT;
               return true;
              }
           }
        }
      return false;
     }

   int               CountMyPositions(void)
     {
      int count = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(PositionSelectByTicket(PositionGetTicket(i)))
           {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == m_symbol)
               count++;
           }
        }
      return count;
     }

   int               CountMyPendingOrders(void)
     {
      int count = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket > 0 && OrderSelect(ticket))
           {
            if(OrderGetInteger(ORDER_MAGIC) == MagicNumber &&
               OrderGetString(ORDER_SYMBOL) == m_symbol)
               count++;
           }
        }
      return count;
     }

   ulong             GetMyPendingOrderByIndex(int index)
     {
      int count = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket > 0 && OrderSelect(ticket))
           {
            if(OrderGetInteger(ORDER_MAGIC) == MagicNumber &&
               OrderGetString(ORDER_SYMBOL) == m_symbol)
              {
               if(count == index) return ticket;
               count++;
              }
           }
        }
      return 0;
     }

   void              CancelOrdersForBrokenBlocks(SSniperBlock &allBlocks[], int totalBlocks)
     {
      for(int b = 0; b < totalBlocks; b++)
        {
         if(allBlocks[b].isBroken && allBlocks[b].limitOrderTicket > 0)
           {
            if(DeleteOrder(allBlocks[b].limitOrderTicket))
               allBlocks[b].limitOrderTicket = 0;
           }
        }
     }

   //+------------------------------------------------------------------+
   //| MODULE 1: Triple-Ticket Verification                              |
   //+------------------------------------------------------------------+
   bool              IsOrderStillAlive(ulong ticket)
     {
      if(ticket <= 0) return false;
      if(OrderSelect(ticket))
        {
         ENUM_ORDER_STATE state = (ENUM_ORDER_STATE)OrderGetInteger(ORDER_STATE);
         return (state == ORDER_STATE_PLACED || state == ORDER_STATE_PARTIAL);
        }
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong t = OrderGetTicket(i);
         if(t == ticket) return true;
        }
      return false;
     }

   //+------------------------------------------------------------------+
   //| MODULE 3: InitiateReversal â€” Phase 1: Close first                 |
   //+------------------------------------------------------------------+
   bool              InitiateReversal(ulong ticket, SSniperBlock &targetBlock)
     {
      if(m_reversalInProgress) { Print("[OrderManager] Reversal already in progress â€” skipping"); return false; }
      m_reversalTargetBlock = targetBlock;
      m_reversalTargetDir = GetDirectionForBlock(targetBlock);
      m_reversalStartTime = TimeCurrent();
      m_reversalInProgress = true;
      if(EnableLogging)
         Print("[OrderManager] REVERSAL INITIATED: closing ticket=", ticket,
               " | Target: ", (m_reversalTargetDir == DIR_LONG ? "LONG" : "SHORT"));
      return ClosePosition(ticket);
     }

   //+------------------------------------------------------------------+
   //| MODULE 3: CompleteReversal â€” Phase 2: Wait for flat, then open    |
   //| FIX 3: Uses CountMyPositions() with bulletproof MagicNumber scan   |
   //+------------------------------------------------------------------+
   void              CompleteReversal(void)
     {
      if(!m_reversalInProgress) return;

      // FIX 3: Use CountMyPositions() â€” rigorous MagicNumber + symbol filter
      if(CountMyPositions() > 0)
        {
         // Position still alive â€” wait for next tick
         if(TimeCurrent() - m_reversalStartTime > 60)
           {
            Print("[OrderManager] Reversal TIMEOUT after 60s â€” clearing reversal lock");
            m_reversalInProgress = false;
           }
         return;
        }

      // Terminal is flat for this EA on this symbol â€” now safe
      if(EnableLogging)
         Print("[OrderManager] Reversal: position confirmed closed â€” opening opposite");

      if(!OpenReversalPosition(m_reversalTargetBlock))
         Print("[OrderManager] Reversal: failed to open opposite position");

      m_reversalInProgress = false;
     }

public:
   //+------------------------------------------------------------------+
   //| Constructor                                                       |
   //+------------------------------------------------------------------+
                     COrderManager(void)
     {
      m_symbol          = "";
      m_riskManager     = NULL;
      m_sniperBlock     = NULL;
      m_correlationFilter = NULL;
      m_hasActiveTrade  = false;
      m_activeDirection = DIR_NONE;
      m_pendingLimitCount = 0;
      m_ordersPlaced    = 0;
      m_ordersFilled    = 0;
      m_ordersRejected  = 0;
      m_reversalsExecuted = 0;
      m_retryCount      = 0;
      m_reversalInProgress = false;
      m_reversalStartTime = 0;
      m_lastOrderTime   = 0;  // FIX 1: Initialize time-lock
      ZeroMemory(m_activeTrade);
      ArrayResize(m_pendingLimitTickets, 0);
     }

                    ~COrderManager(void) { ArrayFree(m_pendingLimitTickets); }

   bool              Initialize(string symbol, CRiskManager *riskManager, CSniperBlock *sniperBlock, CCorrelationFilter *correlationFilter)
     {
      m_symbol      = symbol;
      m_riskManager = riskManager;
      m_sniperBlock = sniperBlock;
      m_correlationFilter = correlationFilter;
      SyncActiveTrade();
      if(EnableLogging)
         Print("[OrderManager] Initialized for ", m_symbol, " | Magic: ", MagicNumber);
      return true;
     }

   void              SyncActiveTrade(void)
     {
      ulong ticket; ENUM_TRADE_DIRECTION dir;
      if(FindActivePosition(ticket, dir))
        {
         if(PositionSelectByTicket(ticket))
           {
            m_activeTrade.ticket     = ticket;
            m_activeTrade.direction  = dir;
            m_activeTrade.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            m_activeTrade.initialSL  = PositionGetDouble(POSITION_SL);
            m_activeTrade.initialSLDistance = MathAbs(m_activeTrade.entryPrice - m_activeTrade.initialSL);
            m_activeTrade.lotSize    = PositionGetDouble(POSITION_VOLUME);
            m_activeTrade.openTime   = (datetime)PositionGetInteger(POSITION_TIME);
            m_activeTrade.trailStep  = STEP_NONE;
            if(dir == DIR_LONG) m_activeTrade.highestPriceSinceEntry = GetBid();
            else m_activeTrade.highestPriceSinceEntry = GetAsk();
            double tickValue = m_riskManager.GetTickValuePerLot();
            double tickSize  = m_riskManager.GetTickSize();
            double slPoints = m_activeTrade.initialSLDistance / tickSize;
            m_activeTrade.initialRiskAmount = slPoints * tickValue * m_activeTrade.lotSize;
            m_activeTrade.currentTrailSL = m_activeTrade.initialSL;
            m_hasActiveTrade  = true;
            m_activeDirection = dir;
           }
        }
      else
        {
         if(m_reversalInProgress) m_reversalInProgress = false;
         m_hasActiveTrade = false;
         m_activeDirection = DIR_NONE;
        }
     }

   void              Update(void)
     {
      CompleteReversal();
      CheckPendingOrderFills();
     }

   //+------------------------------------------------------------------+
   //| Places a limit order with duplicate prevention + time-lock        |
   //+------------------------------------------------------------------+
   bool              PlaceLimitOrder(SSniperBlock &block, int blockIndex)
     {
      if(!block.isValid || block.isBroken) return false;

      // FIX 3: Bulletproof MagicNumber lock â€” if position exists, no new entry
      if(CountMyPositions() > 0 && !block.ghostArmed)
        {
         if(EnableLogging)
            Print("[OrderManager] POSITION LOCK: Active position exists for magic ", MagicNumber, " on ", m_symbol, " â€” skipping new limit order");
         return false;
        }

      // MODULE 1: Triple-ticket verification
      if(IsOrderStillAlive(block.limitOrderTicket))
        { block.ghostArmed = true; return true; }
      block.limitOrderTicket = 0;
      block.ghostArmed = false;

      if(!IsSpreadAcceptable()) return false;

      ENUM_ORDER_TYPE orderType = GetOrderTypeForBlock(block);
      double limitPrice = block.midpoint;
      bool   isLong     = (orderType == ORDER_TYPE_BUY_LIMIT);

      // Pine v4.70 execution params:
      //   entry  = midpoint (default entry_style)
      //   SL dist (rrUnit) = blockHeight + 0.5 * ATR    (local_sl generator)
      //   TP               = entry +/- 3 * rrUnit       (local_tp generator)
      double atrNow = m_sniperBlock.GetATR();
      double rrUnit = block.blockHeight + (0.5 * atrNow);
      double slPrice = isLong ? (limitPrice - rrUnit) : (limitPrice + rrUnit);
      double tpPrice = isLong ? (limitPrice + (3.0 * rrUnit)) : (limitPrice - (3.0 * rrUnit));

      // Persist on the block so the front-run veto & downstream sync see real values
      block.initialSL         = slPrice;
      block.initialSLDistance = rrUnit;
      block.localEntry        = limitPrice;
      block.localSl           = slPrice;
      block.localTp           = tpPrice;
      block.rrUnit            = rrUnit;
      block.hasPlacedOrder    = true;

      double stopLoss   = slPrice;
      double adjustedSL = stopLoss;
      if(!ValidateStopDistance(limitPrice, adjustedSL, isLong))
         adjustedSL = AdjustSLToMinimum(limitPrice, adjustedSL, isLong);

      double lotSize = m_riskManager.CalculateLotSize(limitPrice, adjustedSL);
      if(lotSize <= 0) { Print("[OrderManager] SAFETY ABORT: Lot size zero"); return false; }
      if(!m_riskManager.HasSufficientMargin(lotSize))
        { Print("[OrderManager] Insufficient margin â€” skipping"); return false; }

      MqlTradeRequest request; MqlTradeResult result;
      ZeroMemory(request); ZeroMemory(result);
      request.action   = TRADE_ACTION_PENDING;
      request.symbol   = m_symbol;
      request.type     = orderType;
      request.volume   = lotSize;
      request.price    = NormalizeDouble(limitPrice, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));
      request.sl       = NormalizeDouble(adjustedSL, (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS));
      request.tp       = 0;
      request.deviation = MaxSlippage;
      request.magic    = MagicNumber;
      request.comment  = TradeComment;
      request.type_filling = ORDER_FILLING_RETURN;

      if(request.volume < m_riskManager.GetVolumeMin() || request.volume > m_riskManager.GetVolumeMax())
        { Print("[OrderManager] Invalid volume"); return false; }

      if(SendOrderWithRetry(request, result))
        {
         block.limitOrderTicket = result.order;
         block.ghostArmed = true;
         if(EnableLogging)
            Print("[OrderManager] LIMIT PLACED: ticket=", result.order,
                  " | ", (isLong ? "BUY" : "SELL"), " LIMIT",
                  " | Price=", DoubleToString(limitPrice, Digits()),
                  " | Lot=", DoubleToString(lotSize, 2));
         return true;
        }
      return false;
     }

   //+------------------------------------------------------------------+
   //| GHOST BLOCKS: Proximity Arming with immediate write-back          |
   //+------------------------------------------------------------------+
   void              ManageGhostBlocks(void)
     {
      if(m_reversalInProgress) return;

      SSniperBlock blocks[];
      int blockCount = m_sniperBlock.GetAllBlocks(blocks);
      double currentATR = m_sniperBlock.GetATR();
      if(currentATR <= 0) return;
      double currentBid = GetBid();
      double currentAsk = GetAsk();

      for(int i = 0; i < blockCount; i++)
        {
         // Skip blocks with terminal or vetoed statuses
         if(blocks[i].status >= BLOCK_STATUS_BROKEN && blocks[i].status != BLOCK_STATUS_ORDER_PLACED)
           {
            if(blocks[i].limitOrderTicket > 0)
              {
               if(DeleteOrder(blocks[i].limitOrderTicket))
                 {
                  m_sniperBlock.SetBlockOrderTicket(i, 0);
                  m_sniperBlock.SetBlockOrderParams(i, blocks[i].localSl, blocks[i].localTp, blocks[i].localEntry, blocks[i].rrUnit);
                  // Update hasPlacedOrder to false
                  SSniperBlock bUpdate;
                  m_sniperBlock.GetBlockByIndex(i, bUpdate);
                  bUpdate.hasPlacedOrder = false;
                  // We need a better way to update hasPlacedOrder in CSniperBlock, but for now we rely on status
                 }
              }
            continue;
           }

         ENUM_TRADE_DIRECTION blockDir = GetDirectionForBlock(blocks[i]);
         if(m_hasActiveTrade && blockDir == m_activeDirection) continue;

         double refPrice = (blocks[i].type == BLOCK_SUPPORT) ? currentAsk : currentBid;
         double distance = MathAbs(blocks[i].midpoint - refPrice);

         bool hasPendingOrder = IsOrderStillAlive(blocks[i].limitOrderTicket);

         if(hasPendingOrder)
           {
            double disarmThreshold = GhostDisarmDistance * currentATR;
            if(distance > disarmThreshold)
              {
               if(DeleteOrder(blocks[i].limitOrderTicket))
                 {
                  m_sniperBlock.SetBlockOrderTicket(i, 0);
                  m_sniperBlock.SetBlockStatus(i, blocks[i].status == BLOCK_STATUS_ORDER_PLACED ? BLOCK_STATUS_ARMED : blocks[i].status);
                  if(EnableLogging)
                     Print("[GhostBlock] DISARMED: ticket=", blocks[i].limitOrderTicket,
                           " | distance=", DoubleToString(distance, Digits()));
                 }
              }
            continue;
           }

         // Only arm blocks that are in ARMED or NEW status
         if(blocks[i].status != BLOCK_STATUS_ARMED && blocks[i].status != BLOCK_STATUS_NEW) continue;

          // MODULE 2: Correlation veto check before arming
          ENUM_TRADE_DIRECTION proposedDir = GetDirectionForBlock(blocks[i]);
          bool isVetoed = (m_correlationFilter != NULL) &&
                          (proposedDir == DIR_LONG || proposedDir == DIR_SHORT) &&
                          m_correlationFilter.IsTradeVetoed(proposedDir);
          if(isVetoed)
            {
             if(EnableLogging)
                Print("[Correlation] VETO on ", m_symbol, " ",
                      (proposedDir == DIR_LONG ? "LONG" : "SHORT"),
                      " â€” blocked by portfolio correlation filter");
             continue;
            }

          double armThreshold = GhostArmDistance * currentATR;
          if(distance <= armThreshold)
            {
             if(PlaceLimitOrder(blocks[i], i))
              {
               // PlaceLimitOrder updates block properties locally, we must sync back
               m_sniperBlock.SetBlockOrderTicket(i, blocks[i].limitOrderTicket);
               m_sniperBlock.SetBlockStatus(i, BLOCK_STATUS_ORDER_PLACED);
               m_sniperBlock.SetBlockOrderParams(i, blocks[i].localSl, blocks[i].localTp, blocks[i].localEntry, blocks[i].rrUnit);

               if(EnableLogging)
                  Print("[GhostBlock] ARMED & ORDER PLACED: ",
                        (blocks[i].type == BLOCK_SUPPORT ? "SUPPORT" : "RESISTANCE"),
                        " | mid=", DoubleToString(blocks[i].midpoint, Digits()),
                        " | ticket=", blocks[i].limitOrderTicket);
              }
           }
        }
     }

   void              CancelAllPendingOrders(void)
     {
      SSniperBlock blocks[];
      int blockCount = m_sniperBlock.GetAllBlocks(blocks);
      int cancelledCount = 0;
      for(int i = 0; i < blockCount; i++)
        {
         if(blocks[i].limitOrderTicket > 0)
           {
            if(DeleteOrder(blocks[i].limitOrderTicket))
              {
               blocks[i].limitOrderTicket = 0;
               blocks[i].ghostArmed = false;
               m_sniperBlock.SetBlockOrderTicket(i, 0);
               cancelledCount++;
              }
           }
        }
      if(cancelledCount > 0 && EnableLogging)
         Print("[GhostBlock] Cancelled ", cancelledCount, " pending orders");
     }

   bool              ExecuteReversal(ulong activeTicket, SSniperBlock &targetBlock)
     {
      return InitiateReversal(activeTicket, targetBlock);
     }

   void              CheckPendingOrderFills(void)
     {
      SSniperBlock blocks[];
      int blockCount = m_sniperBlock.GetAllBlocks(blocks);
      for(int i = 0; i < blockCount; i++)
        {
         if(blocks[i].limitOrderTicket > 0)
           {
            if(!OrderSelect(blocks[i].limitOrderTicket))
              {
               ulong newTicket; ENUM_TRADE_DIRECTION newDir;
               if(FindActivePosition(newTicket, newDir))
                 {
                  if(!m_hasActiveTrade || m_activeTrade.ticket != newTicket)
                    {
                     if(m_hasActiveTrade) m_reversalsExecuted++;
                     SyncActiveTrade();
                     m_ordersFilled++;
                    }
                 }
               m_sniperBlock.SetBlockOrderTicket(i, 0);
              }
           }
        }
     }

   void              ManageDirectionConflict(void)
     {
      if(!m_hasActiveTrade) return;
      ENUM_TRADE_DIRECTION activeDir = m_activeDirection;
      int myOrders = CountMyPendingOrders();
      for(int i = myOrders - 1; i >= 0; i--)
        {
         ulong ticket = GetMyPendingOrderByIndex(i);
         if(ticket > 0 && OrderSelect(ticket))
           {
            ENUM_ORDER_TYPE oType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            if((activeDir == DIR_LONG && oType == ORDER_TYPE_BUY_LIMIT) ||
               (activeDir == DIR_SHORT && oType == ORDER_TYPE_SELL_LIMIT))
               DeleteOrder(ticket);
           }
        }
     }

   bool              HasActiveTrade(void) const { return m_hasActiveTrade; }
   ENUM_TRADE_DIRECTION GetActiveDirection(void) const { return m_activeDirection; }
   SActiveTrade      GetActiveTrade(void) const { return m_activeTrade; }
   bool              GetActiveTradeRef(SActiveTrade &outTrade) const
     { if(!m_hasActiveTrade) return false; outTrade = m_activeTrade; return true; }
   void              SetActiveTradeSL(double newSL) { m_activeTrade.currentTrailSL = newSL; }
   void              SetActiveTradeHighWatermark(double newHigh) { m_activeTrade.highestPriceSinceEntry = newHigh; }
   void              SetActiveTradeStep(ENUM_TRAIL_STEP step) { m_activeTrade.trailStep = step; }
   bool              IsReversalInProgress(void) const { return m_reversalInProgress; }
   int               GetOrdersPlaced(void) const { return m_ordersPlaced; }
   int               GetOrdersFilled(void) const { return m_ordersFilled; }
   int               GetOrdersRejected(void) const { return m_ordersRejected; }
   int               GetReversalsExecuted(void) const { return m_reversalsExecuted; }
   int               GetRetryCount(void) const { return m_retryCount; }
  };

#endif  // __ORDER_MANAGER__
