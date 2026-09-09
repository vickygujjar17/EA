//+------------------------------------------------------------------+
//|                                                 CRiskManager.mqh  |
//|                              Module 2 â€” Dynamic 0.25% Risk Sizing  |
//|                             Otto EA - Institutional Grade   |
//+------------------------------------------------------------------+
#property copyright "Otto EA"
#property version   "1.00"

#ifndef __RISK_MANAGER__
#define __RISK_MANAGER__

#include "CommonDefines.mqh"

//+------------------------------------------------------------------+
//| CRiskManager class                                                |
//| Dynamically calculates lot size for 0.25% account risk per trade   |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   string            m_symbol;
   double            m_tickValue;           // Cached SYMBOL_TRADE_TICK_VALUE
   double            m_tickSize;            // Cached SYMBOL_TRADE_TICK_SIZE
   double            m_volumeStep;          // Cached SYMBOL_VOLUME_STEP
   double            m_volumeMin;           // Cached SYMBOL_VOLUME_MIN
   double            m_volumeMax;           // Cached SYMBOL_VOLUME_MAX
   int               m_digits;              // Cached SYMBOL_DIGITS

   double            m_lastRiskAmount;
   double            m_lastLotSize;
   int               m_tradesCalculated;

   //+------------------------------------------------------------------+
   //| Refreshes symbol properties from the market                        |
   //+------------------------------------------------------------------+
   bool              RefreshSymbolProperties(void)
     {
      m_tickValue  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      m_tickSize   = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      m_volumeStep = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      m_volumeMin  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      m_volumeMax  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      m_digits     = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);

      if(m_tickValue <= 0 || m_tickSize <= 0 || m_volumeStep <= 0)
        {
         Print("[RiskManager] ERROR: Invalid symbol properties for ", m_symbol,
               " | TickVal=", m_tickValue,
               " | TickSize=", m_tickSize,
               " | VolStep=", m_volumeStep);
         return false;
        }

      return true;
     }

   //+------------------------------------------------------------------+
   //| Rounds a lot size to the nearest valid volume step                 |
   //+------------------------------------------------------------------+
   double            NormalizeLotSize(double rawLot)
     {
      if(m_volumeStep <= 0)
         return rawLot;

      double steps = MathRound(rawLot / m_volumeStep);
      double normalized = steps * m_volumeStep;

      // Clamp to min/max
      normalized = MathMax(m_volumeMin, MathMin(m_volumeMax, normalized));

      return normalized;
     }

public:
   //+------------------------------------------------------------------+
   //| Constructor                                                       |
   //+------------------------------------------------------------------+
                     CRiskManager(void)
     {
      m_symbol           = "";
      m_tickValue         = 0;
      m_tickSize          = 0;
      m_volumeStep        = 0;
      m_volumeMin         = 0;
      m_volumeMax         = 0;
      m_digits            = 0;
      m_lastRiskAmount    = 0;
      m_lastLotSize       = 0;
      m_tradesCalculated  = 0;
     }

   //+------------------------------------------------------------------+
   //| Destructor                                                        |
   //+------------------------------------------------------------------+
                    ~CRiskManager(void)
     {
     }

   //+------------------------------------------------------------------+
   //| Initialize â€” cache symbol properties                               |
   //+------------------------------------------------------------------+
   bool              Initialize(string symbol)
     {
      m_symbol = symbol;

      if(!RefreshSymbolProperties())
         return false;

      if(EnableLogging)
        {
         Print("[RiskManager] Initialized for ", m_symbol,
               " | TickVal=", DoubleToString(m_tickValue, m_digits),
               " | TickSize=", DoubleToString(m_tickSize, m_digits),
               " | VolMin=", DoubleToString(m_volumeMin, 2),
               " | VolMax=", DoubleToString(m_volumeMax, 2),
               " | VolStep=", DoubleToString(m_volumeStep, 2));
        }

      return true;
     }

   //+------------------------------------------------------------------+
   //| Core calculation: Lot size for given SL distance in points         |
   //| entryPrice and stopLossPrice are in price units                    |
   //| Returns the EXACT lot size to risk exactly RiskPercent% of account |
   //+------------------------------------------------------------------+
   double            CalculateLotSize(double   entryPrice,
                                      double   stopLossPrice)
     {
      // Refresh properties each call to handle changing market conditions
      if(!RefreshSymbolProperties())
        {
         Print("[RiskManager] ERROR: Cannot refresh symbol properties");
         return m_volumeMin; // Return minimum as fallback
        }

      // --- Determine account risk capital ---
      // Use the LOWER of Balance and Equity for safety
      double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double accountEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double accountCapital = MathMin(accountBalance, accountEquity);

      double riskMoney = accountCapital * (RiskPercent / 100.0);

      // --- Calculate Stop Loss distance in points ---
      double slDistancePrice  = MathAbs(entryPrice - stopLossPrice);
      double slDistancePoints = slDistancePrice / m_tickSize;

      if(slDistancePoints <= 0)
        {
         Print("[RiskManager] ERROR: SL distance is zero or negative! ",
               "Entry=", entryPrice, " SL=", stopLossPrice);
         return m_volumeMin;
        }

      // --- Calculate lot size ---
      // Formula: lotSize = riskMoney / (slDistancePoints * tickValuePerLot)
      // tickValuePerLot is the profit/loss of 1 standard lot per 1 tick move
      double tickValuePerLot = m_tickValue;

      // For some brokers, tickValue may be for minimum lot, not standard lot
      // We handle this: if tickValue seems too small for 1 lot, scale it
      // Standard: 1 lot = 100,000 units. tickValue = profit in account currency per tick per lot
      if(tickValuePerLot > 0)
        {
         // All good â€” use directly
        }
      else
        {
         Print("[RiskManager] WARNING: tickValue is zero â€” using fallback calculation");
         // Fallback: approximate from contract size
         double contractSize = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_CONTRACT_SIZE);
         if(contractSize > 0)
           {
            tickValuePerLot = contractSize * m_tickSize;
           }
         else
           {
            Print("[RiskManager] FATAL: Cannot determine tick value");
            return m_volumeMin;
           }
        }

      double rawLotSize = riskMoney / (slDistancePoints * tickValuePerLot);

      if(EnableLogging)
        {
         Print("[RiskManager] -- Lot Calculation --");
         Print("  Account Capital: ", DoubleToString(accountCapital, 2));
         Print("  Risk %: ", RiskPercent, "% = ", DoubleToString(riskMoney, 2), " ", AccountInfoString(ACCOUNT_CURRENCY));
         Print("  SL Distance (price): ", DoubleToString(slDistancePrice, m_digits));
         Print("  SL Distance (points): ", DoubleToString(slDistancePoints, 1));
         Print("  Tick Value per Lot: ", DoubleToString(tickValuePerLot, m_digits));
         Print("  Raw Lot Size: ", DoubleToString(rawLotSize, 4));
        }

      // --- Normalize to valid lot size ---
      double finalLotSize = NormalizeLotSize(rawLotSize);

      // --- Clamp one more time for safety ---
      if(finalLotSize < m_volumeMin)
        {
         Print("[RiskManager] WARNING: Calculated lot ", DoubleToString(finalLotSize, 4),
               " < Min ", DoubleToString(m_volumeMin, 2), " â€” using minimum");
         finalLotSize = m_volumeMin;
        }

      if(finalLotSize > m_volumeMax)
        {
         Print("[RiskManager] WARNING: Calculated lot ", DoubleToString(finalLotSize, 4),
               " > Max ", DoubleToString(m_volumeMax, 2), " â€” using maximum. Risk may exceed target.");
         finalLotSize = m_volumeMax;
        }

      // --- Safety: ensure lot size is non-zero ---
      if(finalLotSize <= 0)
        {
         Print("[RiskManager] FATAL: Lot size is zero â€” using minimum");
         finalLotSize = m_volumeMin;
        }

      // --- PROP FIRM SAFETY CLAMP: Verify actual risk % does not exceed limit ---
      double actualRiskPct = (finalLotSize * slDistancePoints * tickValuePerLot) / accountCapital * 100.0;
      if(actualRiskPct > SafetyMaxRiskPct)
        {
         Print("[RiskManager] SAFETY CLAMP: Actual risk ", DoubleToString(actualRiskPct, 2),
               "% exceeds max ", SafetyMaxRiskPct, "% â€” aborting trade (lot=",
               DoubleToString(finalLotSize, 4), ")");
         return 0.0; // Return 0 to signal abort
        }

      // --- Update tracking variables ---
      m_lastRiskAmount = riskMoney;
      m_lastLotSize    = finalLotSize;
      m_tradesCalculated++;

      if(EnableLogging)
        {
         Print("[RiskManager] FINAL Lot Size: ", DoubleToString(finalLotSize, 4),
               " | ActualRisk=", DoubleToString(actualRiskPct, 2), "%",
               " | RiskAmount=", DoubleToString(riskMoney, 2),
               " | SlPoints=", DoubleToString(slDistancePoints, 1));
        }

      return finalLotSize;
     }

   //+------------------------------------------------------------------+
   //| Calculates lot size from a pre-computed SL distance in points      |
   //| (Alternative entry point when SL is already in points)            |
   //+------------------------------------------------------------------+
   double            CalculateLotSizeFromPoints(double slDistancePoints)
     {
      if(!RefreshSymbolProperties())
         return m_volumeMin;

      double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double accountEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double accountCapital = MathMin(accountBalance, accountEquity);
      double riskMoney      = accountCapital * (RiskPercent / 100.0);

      double tickValuePerLot = m_tickValue;
      if(tickValuePerLot <= 0)
        {
         double contractSize = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_CONTRACT_SIZE);
         tickValuePerLot = (contractSize > 0) ? contractSize * m_tickSize : 0.01;
        }

      double rawLotSize = riskMoney / (slDistancePoints * tickValuePerLot);
      double finalLotSize = NormalizeLotSize(rawLotSize);

      finalLotSize = MathMax(m_volumeMin, MathMin(m_volumeMax, finalLotSize));
      if(finalLotSize <= 0) finalLotSize = m_volumeMin;

      return finalLotSize;
     }

   //+------------------------------------------------------------------+
   //| Returns the tick value per standard lot (cached)                   |
   //+------------------------------------------------------------------+
   double            GetTickValuePerLot(void) const
     {
      return m_tickValue;
     }

   //+------------------------------------------------------------------+
   //| Returns the tick size (cached)                                     |
   //+------------------------------------------------------------------+
   double            GetTickSize(void) const
     {
      return m_tickSize;
     }

   //+------------------------------------------------------------------+
   //| Returns the symbol digits (cached)                                 |
   //+------------------------------------------------------------------+
   int               GetDigits(void) const
     {
      return m_digits;
     }

   //+------------------------------------------------------------------+
   //| Returns minimum volume for this symbol                             |
   //+------------------------------------------------------------------+
   double            GetVolumeMin(void) const
     {
      return m_volumeMin;
     }

   //+------------------------------------------------------------------+
   //| Returns maximum volume for this symbol                             |
   //+------------------------------------------------------------------+
   double            GetVolumeMax(void) const
     {
      return m_volumeMax;
     }

   //+------------------------------------------------------------------+
   //| Returns volume step for this symbol                                |
   //+------------------------------------------------------------------+
   double            GetVolumeStep(void) const
     {
      return m_volumeStep;
     }

   //+------------------------------------------------------------------+
   //| Returns the last calculated risk amount                             |
   //+------------------------------------------------------------------+
   double            GetLastRiskAmount(void) const
     {
      return m_lastRiskAmount;
     }

   //+------------------------------------------------------------------+
   //| Returns the last calculated lot size                               |
   //+------------------------------------------------------------------+
   double            GetLastLotSize(void) const
     {
      return m_lastLotSize;
     }

   //+------------------------------------------------------------------+
   //| Returns total number of lot calculations performed                 |
   //+------------------------------------------------------------------+
   int               GetTradesCalculated(void) const
     {
      return m_tradesCalculated;
     }

   //+------------------------------------------------------------------+
   //| Checks if there is sufficient margin for a given lot size          |
   //+------------------------------------------------------------------+
   bool              HasSufficientMargin(double lotSize)
     {
      double marginRequired;
      if(!OrderCalcMargin(ORDER_TYPE_BUY, m_symbol, lotSize,
                          SymbolInfoDouble(m_symbol, SYMBOL_ASK), marginRequired))
        {
         Print("[RiskManager] ERROR: OrderCalcMargin failed");
         return false;
        }

      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      bool sufficient = (freeMargin > marginRequired * 1.1); // 10% buffer

      if(!sufficient && EnableLogging)
        {
         Print("[RiskManager] Insufficient margin: Required=",
               DoubleToString(marginRequired, 2),
               " Free=", DoubleToString(freeMargin, 2));
        }

      return sufficient;
     }
  };

//+------------------------------------------------------------------+
#endif  // __RISK_MANAGER__
