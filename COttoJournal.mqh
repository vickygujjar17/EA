//+------------------------------------------------------------------+
//|                                                   COttoJournal.mqh |
//|                                           Human-readable .txt log |
//|            OTTO EA Ã¢â‚¬â€ structured trade-entry / trade-exit journal    |
//+------------------------------------------------------------------+
#property copyright "OTTO EA"
#property version   "4.80"

#ifndef __OTTO_JOURNAL__
#define __OTTO_JOURNAL__

#include "OttoDefines.mqh"

//+------------------------------------------------------------------+
//| COttoJournal class                                              |
//| Appends detailed, human-readable entry/exit blocks to a plain  |
//| .txt file in MQL5\Files\ (Otto_Trade_Journal_<symbol>.txt).    |
//+------------------------------------------------------------------+
class COttoJournal
  {
private:
   string            m_symbol;
   string            m_sessionID;
   int               m_handle;
   bool              m_ready;

   string            FmtPrice(double p)
     {
      return DoubleToString(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
     }

   string            FmtPips(double priceDist)
     {
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(point <= 0) return "0.0";
      double pips = priceDist / (point * 10.0);
      return DoubleToString(pips, 1);
     }

   void              W(string s)
     {
      if(!m_ready || m_handle == INVALID_HANDLE) return;
      FileWriteString(m_handle, s + "\n");
      FileFlush(m_handle);
     }

   string            FmtDuration(datetime open, datetime close)
     {
      long secs = (long)(close - open);
      if(secs < 0) secs = 0;
      long h = secs / 3600;
      long m = (secs % 3600) / 60;
      return IntegerToString(h) + " hours " + IntegerToString(m) + " minutes";
     }

public:
                     COttoJournal(void)
     {
      m_symbol   = "";
      m_sessionID= "";
      m_handle = INVALID_HANDLE;
      m_ready  = false;
     }

   //+------------------------------------------------------------------+
   //| Sets the active trade session ID (prepends every block)          |
   //+------------------------------------------------------------------+
   void              SetSessionID(string id) { m_sessionID = id; }

                    ~COttoJournal(void)
     {
      Close();
     }

   bool              Initialize(string symbol)
     {
      m_symbol = symbol;
      string fn = "Otto_Trade_Journal_" + symbol + ".txt";
      // Open READ+WRITE and seek to END so new blocks append (no truncate on reload)
      m_handle = FileOpen(fn, FILE_TXT | FILE_READ | FILE_WRITE | FILE_SHARE_READ);
      if(m_handle != INVALID_HANDLE)
        {
         m_ready = true;
         if(FileTell(m_handle) == 0)            // file was (re)created empty
           {
            W("==================================================================================");
            W("[OTTO TRADE JOURNAL] Symbol: " + symbol + " | Created: " + TimeToString(TimeCurrent()));
            W("==================================================================================");
           }
         FileSeek(m_handle, 0, SEEK_END);       // always append
         if(EnableLogging) Print("[Journal] Opened (append): ", fn);
         return true;
        }
      Print("[Journal] ERROR: Could not open ", fn, " err=", GetLastError());
      return false;
     }
   void              Close(void)
     {
      if(m_handle != INVALID_HANDLE)
        {
         FileClose(m_handle);
         m_handle = INVALID_HANDLE;
        }
      m_ready = false;
     }

   //+------------------------------------------------------------------+
   //| LOG ENTRY Ã¢â‚¬â€ call when a limit order is FILLED                    |
   //+------------------------------------------------------------------+
   void              LogEntry(ulong ticket, ENUM_TRADE_DIRECTION dir, double entryPrice, double slPrice, double lotSize, double riskMoney, const SSniperBlock &blk)
     {
      if(!m_ready) return;
      double riskDist = MathAbs(entryPrice - slPrice);

      W("==================================================================================");
      W("[TRADE ENTRY] Session " + (m_sessionID!="" ? m_sessionID : "#NA") + " | Ticket #" + IntegerToString((int)ticket) + " | " + m_symbol +
        " (" + (dir == DIR_LONG ? "BUY / LONG" : "SELL / SHORT") + ") | " + TimeToString(TimeCurrent()));
      W("----------------------------------------------------------------------------------");
      W("  Execution Price   : " + FmtPrice(entryPrice));
      W("  Initial Stop Loss : " + FmtPrice(slPrice) + " (Risk Distance: " + FmtPips(riskDist) +
        " pips | 1R = " + FmtPrice(blk.rrUnit) + ")");
      W("  Volume & Sizing   : " + DoubleToString(lotSize,2) + " Lots | Risk: $" +
        DoubleToString(riskMoney,2) + " (0.25% Equity)");
      W("");
      W("  S/R Block Breakdown:");
      W("    - Block Polarity  : " + (blk.type == BLOCK_SUPPORT ? "SUPPORT" : "RESISTANCE"));
      W("    - Zone Range      : Top = " + FmtPrice(blk.top) + " | Bottom = " + FmtPrice(blk.bottom) +
        " (Height = " + FmtPips(blk.blockHeight) + " pips | " +
        DoubleToString((blk.atrSnapshot > 0 ? blk.blockHeight / blk.atrSnapshot : 0.0),2) + "x ATR)");
      if(blk.wick1Time > 0 && blk.wick2Time > 0)
        {
         W("    - Wick 1 (Anchor) : " + TimeToString(blk.wick1Time) + " | High = " + FmtPrice(blk.wick1.highPrice) +
           ", Low = " + FmtPrice(blk.wick1.lowPrice));
         W("    - Wick 2 (Retest) : " + TimeToString(blk.wick2Time) + " | High = " + FmtPrice(blk.wick2.highPrice) +
           ", Low = " + FmtPrice(blk.wick2.lowPrice));
        }
      W("    - Separation Test : " + (blk.vetoReason == VETO_NO_SEPARATION ? "FAILED (No separation)" : "PASSED (zone free)"));
      W("==================================================================================");
     }

   //+------------------------------------------------------------------+
   //| LOG EXIT Ã¢â‚¬â€ call when an active trade closes                       |
   //+------------------------------------------------------------------+
   void              LogExit(ulong ticket, ENUM_TRADE_DIRECTION dir, double entryPrice, double exitPrice, double lotSize, double grossProfit, double commission, double swap, datetime openTime, string exitReason)
     {
      if(!m_ready) return;
      double net = grossProfit + commission + swap;

      W("==================================================================================");
      W("[TRADE EXIT] Session " + (m_sessionID!="" ? m_sessionID : "#NA") + " | Ticket #" + IntegerToString((int)ticket) + " | " + m_symbol +
        " (" + (dir == DIR_LONG ? "BUY / LONG" : "SELL / SHORT") + ") | " + TimeToString(TimeCurrent()));
      W("----------------------------------------------------------------------------------");
      W("  Entry Price       : " + FmtPrice(entryPrice));
      W("  Exit Price        : " + FmtPrice(exitPrice));
      W("  Exit Reason       : " + exitReason);
      W("  Duration          : " + FmtDuration(openTime, TimeCurrent()));
      W("");
      W("  Financial Outcome:");
      W("    - Gross Result  : " + (grossProfit >= 0 ? "+" : "") + DoubleToString(grossProfit,2));
      W("    - Broker Fees   : Commission = " + DoubleToString(commission,2) + " | Swap = " + DoubleToString(swap,2));
      W("    - Net Profit/Loss : " + (net >= 0 ? "+" : "") + DoubleToString(net,2));
      W("==================================================================================");
     }

   //+------------------------------------------------------------------+
   //| LOG PYRAMID — a scaling tranche (2 or 3) was added               |
   //+------------------------------------------------------------------+
   void              LogPyramid(int tranche, ulong ticket, double entry, double size, double riskPct, double groupSL)
     {
      if(!m_ready) return;
      W("[PYRAMID ADDITION] Session " + (m_sessionID!="" ? m_sessionID : "#NA") + " | Tranche " + IntegerToString(tranche) + " | Ticket #" + IntegerToString((int)ticket) + " | +" + ((tranche==2)?"1.0":"2.0") + "R Reached");
      W("  Entry Price       : " + FmtPrice(entry) + " | Size: " + DoubleToString(size,2) + " Lots | Risk: " + DoubleToString(riskPct,2) + "%");
      W("  Group Stop Shift  : " + (groupSL>0 ? ("All active stops moved to " + FmtPrice(groupSL)) : "All active stops updated (cost-covering BE)"));
      W("----------------------------------------------------------------------------------");
     }
  };

//+------------------------------------------------------------------+
#endif  // __OTTO_JOURNAL__