//+------------------------------------------------------------------+
//|                                             CMarketStructure.mqh  |
//|                    Module 3 — Fractal Pivots & Dominant Peak Memory |
//|                             TrendSniper EA - Institutional Grade   |
//+------------------------------------------------------------------+
#property copyright "TrendSniper EA"
#property version   "1.00"

#ifndef __MARKET_STRUCTURE__
#define __MARKET_STRUCTURE__

#include "CommonDefines.mqh"

//+------------------------------------------------------------------+
//| CMarketStructure class                                             |
//| Detects fractal pivot highs/lows with dominant peak retention      |
//+------------------------------------------------------------------+
class CMarketStructure
  {
private:
   string            m_symbol;

   // --- Resistance (Pivot High) peaks ---
   SFractalPeak      m_resistPeaks[];
   int               m_resistCount;

   // --- Support (Pivot Low) peaks ---
   SFractalPeak      m_supportPeaks[];
   int               m_supportCount;

   // --- Cache ---
   int               m_lastProcessedBar;
   datetime          m_lastBarTime;
   int               m_loopCounter;

   //+------------------------------------------------------------------+
   //| Checks if bar 'idx' is HIGHEST among +/- leftBars/rightBars        |
   //+------------------------------------------------------------------+
   bool              IsFractalHigh(int barIndex, int leftBars, int rightBars)
     {
      double highCenter = iHigh(m_symbol, PERIOD_CURRENT, barIndex);

      // Check left side — all bars must have strictly lower highs
      for(int i = 1; i <= leftBars; i++)
        {
         double leftHigh = iHigh(m_symbol, PERIOD_CURRENT, barIndex + i);
         if(leftHigh >= highCenter)
            return false;
        }

      // Check right side — all bars must have strictly lower highs
      for(int i = 1; i <= rightBars; i++)
        {
         int checkIdx = barIndex - i;
         if(checkIdx < 0) break;
         double rightHigh = iHigh(m_symbol, PERIOD_CURRENT, checkIdx);
         if(rightHigh >= highCenter)
            return false;
        }

      // Ensure enough bars on both sides for a valid detection
      if(barIndex < rightBars)
         return false;
      if(barIndex + leftBars >= LookbackBars)
         return false;

      return true;
     }

   //+------------------------------------------------------------------+
   //| Checks if bar 'idx' is LOWEST among +/- leftBars/rightBars         |
   //+------------------------------------------------------------------+
   bool              IsFractalLow(int barIndex, int leftBars, int rightBars)
     {
      double lowCenter = iLow(m_symbol, PERIOD_CURRENT, barIndex);

      for(int i = 1; i <= leftBars; i++)
        {
         double leftLow = iLow(m_symbol, PERIOD_CURRENT, barIndex + i);
         if(leftLow <= lowCenter)
            return false;
        }

      for(int i = 1; i <= rightBars; i++)
        {
         int checkIdx = barIndex - i;
         if(checkIdx < 0) break;
         double rightLow = iLow(m_symbol, PERIOD_CURRENT, checkIdx);
         if(rightLow <= lowCenter)
            return false;
        }

      if(barIndex < rightBars)
         return false;
      if(barIndex + leftBars >= LookbackBars)
         return false;

      return true;
     }

   //+------------------------------------------------------------------+
   //| Creates an SFractalPeak entry from a detected bar index             |
   //+------------------------------------------------------------------+
   void              CreatePeakEntry(int barIndex, bool isHigh, SFractalPeak &outPeak)
     {
      ZeroMemory(outPeak);
      outPeak.time      = iTime(m_symbol, PERIOD_CURRENT, barIndex);
      outPeak.barIndex  = barIndex;
      outPeak.openPrice = iOpen(m_symbol, PERIOD_CURRENT, barIndex);
      outPeak.closePrice= iClose(m_symbol, PERIOD_CURRENT, barIndex);
      outPeak.highPrice = iHigh(m_symbol, PERIOD_CURRENT, barIndex);
      outPeak.lowPrice  = iLow(m_symbol, PERIOD_CURRENT, barIndex);

      if(isHigh)
         outPeak.price = outPeak.highPrice;   // Resistance anchor = the high
      else
         outPeak.price = outPeak.lowPrice;     // Support anchor = the low

      outPeak.isActive           = true;
      outPeak.wasTriggered       = false;
      outPeak.barsSinceFormation = 0;
     }

   //+------------------------------------------------------------------+
   //| Finds the index of the active dominant resistance peak (-1 if none)|
   //+------------------------------------------------------------------+
   int               FindActiveResistPeak(void)
     {
      for(int i = 0; i < m_resistCount; i++)
        {
         if(m_resistPeaks[i].isActive)
            return i;
        }
      return -1;
     }

   //+------------------------------------------------------------------+
   //| Finds the index of the active dominant support peak (-1 if none)   |
   //+------------------------------------------------------------------+
   int               FindActiveSupportPeak(void)
     {
      for(int i = 0; i < m_supportCount; i++)
        {
         if(m_supportPeaks[i].isActive)
            return i;
        }
      return -1;
     }

   //+------------------------------------------------------------------+
   //| Removes excess peaks from an array (cleanup routine)               |
   //+------------------------------------------------------------------+
   void              CleanupPeaksArray(SFractalPeak  &peaks[],
                                       int           &count,
                                       int            maxAllowed)
     {
      // Remove oldest inactive peaks if we exceed the limit
      while(count > maxAllowed)
        {
         // Find the oldest non-active or stale peak to remove
         int oldestIdx = -1;
         int oldestBars = -1;

         for(int i = 0; i < count; i++)
           {
            if(!peaks[i].isActive || peaks[i].barsSinceFormation > MaxPeakAge * 2)
              {
               if(peaks[i].barsSinceFormation > oldestBars)
                 {
                  oldestBars = peaks[i].barsSinceFormation;
                  oldestIdx = i;
                 }
              }
           }

         if(oldestIdx >= 0)
           {
            // Remove by shifting
            for(int i = oldestIdx; i < count - 1; i++)
               peaks[i] = peaks[i + 1];
            count--;
           }
         else
           {
            // No removable peak — break to avoid infinite loop
            break;
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Applies Dominant Peak Retention rules for Resistance (Pivot High)  |
   //+------------------------------------------------------------------+
   void              ApplyResistanceRetention(SFractalPeak &newPeak)
     {
      // ---- DOMINANT PEAK RETENTION RULES (Module 3) ----
      // 1. If no active anchor → store as active
      // 2. If new is higher than active → replace
      // 3. If active is stale (> 30 bars) → replace
      // 4. If active was already triggered → replace
      // 5. Otherwise → discard new peak

      int activeIdx = FindActiveResistPeak();

      if(activeIdx < 0)
        {
         // No active resistance anchor — store this one
         AddResistancePeak(newPeak);
         return;
        }

      SFractalPeak active = m_resistPeaks[activeIdx];

      bool shouldReplace = false;
      string reason = "";

      // Rule 2: New peak is higher → dominates
      if(newPeak.price > active.price)
        {
         shouldReplace = true;
         reason = "new peak higher";
        }
      // Rule 3: Active peak is stale
      else if(active.barsSinceFormation > MaxPeakAge)
        {
         shouldReplace = true;
         reason = "active peak stale (>30 bars)";
        }
      // Rule 4: Active peak was triggered
      else if(active.wasTriggered)
        {
         shouldReplace = true;
         reason = "active peak already triggered";
        }
      // Rule 5: Discard new peak — active is dominant

      if(shouldReplace)
        {
         // Deactivate old peak
         m_resistPeaks[activeIdx].isActive = false;

         // Store new peak as active
         AddResistancePeak(newPeak);

         if(EnableLogging)
           {
            Print("[MarketStructure] Resistance anchor REPLACED at ",
                  DoubleToString(newPeak.price, Digits()),
                  " | Reason: ", reason,
                  " | Old: ", DoubleToString(active.price, Digits()),
                  " (age: ", active.barsSinceFormation, " bars)");
           }
        }
      else
        {
         if(EnableLogging)
           {
            Print("[MarketStructure] Resistance peak DISCARDED at ",
                  DoubleToString(newPeak.price, Digits()),
                  " | Existing dominant: ", DoubleToString(active.price, Digits()),
                  " (age: ", active.barsSinceFormation, " bars)");
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Applies Dominant Peak Retention rules for Support (Pivot Low)       |
   //+------------------------------------------------------------------+
   void              ApplySupportRetention(SFractalPeak &newPeak)
     {
      // Mirror logic for Support (Pivot Low):
      // Lower lows dominate (mirror of "higher highs")
      int activeIdx = FindActiveSupportPeak();

      if(activeIdx < 0)
        {
         AddSupportPeak(newPeak);
         return;
        }

      SFractalPeak active = m_supportPeaks[activeIdx];

      bool shouldReplace = false;
      string reason = "";

      // Rule 2 (mirrored): New low is LOWER → dominates
      if(newPeak.price < active.price)
        {
         shouldReplace = true;
         reason = "new peak lower";
        }
      else if(active.barsSinceFormation > MaxPeakAge)
        {
         shouldReplace = true;
         reason = "active peak stale (>30 bars)";
        }
      else if(active.wasTriggered)
        {
         shouldReplace = true;
         reason = "active peak already triggered";
        }

      if(shouldReplace)
        {
         m_supportPeaks[activeIdx].isActive = false;
         AddSupportPeak(newPeak);

         if(EnableLogging)
           {
            Print("[MarketStructure] Support anchor REPLACED at ",
                  DoubleToString(newPeak.price, Digits()),
                  " | Reason: ", reason,
                  " | Old: ", DoubleToString(active.price, Digits()),
                  " (age: ", active.barsSinceFormation, " bars)");
           }
        }
      else
        {
         if(EnableLogging)
           {
            Print("[MarketStructure] Support peak DISCARDED at ",
                  DoubleToString(newPeak.price, Digits()),
                  " | Existing dominant: ", DoubleToString(active.price, Digits()),
                  " (age: ", active.barsSinceFormation, " bars)");
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Adds a resistance peak to the array (managing capacity)            |
   //+------------------------------------------------------------------+
   void              AddResistancePeak(SFractalPeak &peak)
     {
      if(m_resistCount >= MAX_PEAKS_RESIST)
         CleanupPeaksArray(m_resistPeaks, m_resistCount, MAX_PEAKS_RESIST - 1);

      ArrayResize(m_resistPeaks, m_resistCount + 1, MAX_PEAKS_RESIST);
      m_resistPeaks[m_resistCount] = peak;
      m_resistCount++;
     }

   //+------------------------------------------------------------------+
   //| Adds a support peak to the array (managing capacity)               |
   //+------------------------------------------------------------------+
   void              AddSupportPeak(SFractalPeak &peak)
     {
      if(m_supportCount >= MAX_PEAKS_SUPPORT)
         CleanupPeaksArray(m_supportPeaks, m_supportCount, MAX_PEAKS_SUPPORT - 1);

      ArrayResize(m_supportPeaks, m_supportCount + 1, MAX_PEAKS_SUPPORT);
      m_supportPeaks[m_supportCount] = peak;
      m_supportCount++;
     }

   //+------------------------------------------------------------------+
   //| Increments barsSinceFormation for all stored peaks                 |
   //| Deactivates peaks that have existed far too long                   |
   //+------------------------------------------------------------------+
   void              AgeAllPeaks(void)
     {
      // Age resistance peaks
      for(int i = m_resistCount - 1; i >= 0; i--)
        {
         m_resistPeaks[i].barsSinceFormation++;

         // Remove peaks that are extremely old (3x MaxPeakAge)
         if(m_resistPeaks[i].barsSinceFormation > MaxPeakAge * 3)
           {
            for(int j = i; j < m_resistCount - 1; j++)
               m_resistPeaks[j] = m_resistPeaks[j + 1];
            m_resistCount--;
           }
        }

      // Age support peaks
      for(int i = m_supportCount - 1; i >= 0; i--)
        {
         m_supportPeaks[i].barsSinceFormation++;

         if(m_supportPeaks[i].barsSinceFormation > MaxPeakAge * 3)
           {
            for(int j = i; j < m_supportCount - 1; j++)
               m_supportPeaks[j] = m_supportPeaks[j + 1];
            m_supportCount--;
           }
        }
     }

public:
   //+------------------------------------------------------------------+
   //| Constructor                                                       |
   //+------------------------------------------------------------------+
                     CMarketStructure(void)
     {
      m_symbol          = "";
      m_resistCount     = 0;
      m_supportCount    = 0;
      m_lastProcessedBar = -1;
      m_lastBarTime     = 0;
      m_loopCounter     = 0;

      ArrayResize(m_resistPeaks, 0, MAX_PEAKS_RESIST);
      ArrayResize(m_supportPeaks, 0, MAX_PEAKS_SUPPORT);
     }

   //+------------------------------------------------------------------+
   //| Destructor                                                        |
   //+------------------------------------------------------------------+
                    ~CMarketStructure(void)
     {
      ArrayFree(m_resistPeaks);
      ArrayFree(m_supportPeaks);
     }

   //+------------------------------------------------------------------+
   //| Initialize                                                        |
   //+------------------------------------------------------------------+
   bool              Initialize(string symbol)
     {
      m_symbol = symbol;

      if(EnableLogging)
        {
         Print("[MarketStructure] Initialized for ", m_symbol,
               " | Major: ", LeftBars, "/", RightBars,
               " | Minor: ", MinorLeft, "/", MinorRight,
               " | MaxPeakAge: ", MaxPeakAge);
        }

      return true;
     }

   //+------------------------------------------------------------------+
   //| Main update — scans for fractals, applies retention rules          |
   //+------------------------------------------------------------------+
   void              Update(void)
     {
      m_loopCounter++;

      // Only process new bars (once per bar)
      datetime currentBarTime = iTime(m_symbol, PERIOD_CURRENT, 0);
      if(currentBarTime == m_lastBarTime)
         return;
      m_lastBarTime = currentBarTime;

      // Age all existing peaks by 1 bar
      AgeAllPeaks();

      // Scan for Major Anchors (8/5 fractals) across recent bars
      // We start from RightBars+1 to ensure enough right-side bars exist
      int scanStart = RightBars + 1;
      int scanEnd   = LookbackBars - LeftBars - 1;

      for(int bar = scanStart; bar <= scanEnd && bar < LookbackBars; bar++)
        {
         // --- Detect Major Pivot High (Resistance Anchor) ---
         if(IsFractalHigh(bar, LeftBars, RightBars))
           {
            // Check if this bar was already stored (avoid duplicates)
            bool alreadyStored = false;
            for(int i = 0; i < m_resistCount && !alreadyStored; i++)
              {
               if(m_resistPeaks[i].barIndex == bar)
                  alreadyStored = true;
              }

            if(!alreadyStored)
              {
               SFractalPeak newPeak;
               CreatePeakEntry(bar, true, newPeak);
               ApplyResistanceRetention(newPeak);
              }
           }

         // --- Detect Major Pivot Low (Support Anchor) ---
         if(IsFractalLow(bar, LeftBars, RightBars))
           {
            bool alreadyStored = false;
            for(int i = 0; i < m_supportCount && !alreadyStored; i++)
              {
               if(m_supportPeaks[i].barIndex == bar)
                  alreadyStored = true;
              }

            if(!alreadyStored)
              {
               SFractalPeak newPeak;
               CreatePeakEntry(bar, false, newPeak);
               ApplySupportRetention(newPeak);
              }
           }
        }

      // --- Detect Minor Retests (2/2 fractals) ---
      // Minor retests are stored directly (no retention rules — they pair with anchors)
      for(int bar = scanStart; bar <= scanEnd && bar < LookbackBars; bar++)
        {
         if(IsFractalHigh(bar, MinorLeft, MinorRight))
           {
            bool alreadyStored = false;
            for(int i = 0; i < m_resistCount && !alreadyStored; i++)
              {
               if(m_resistPeaks[i].barIndex == bar)
                  alreadyStored = true;
              }

            if(!alreadyStored)
              {
               SFractalPeak minorRetest;
               CreatePeakEntry(bar, true, minorRetest);
               minorRetest.isActive = false; // Minor retests are not dominant anchors
               AddResistancePeak(minorRetest);
              }
           }

         if(IsFractalLow(bar, MinorLeft, MinorRight))
           {
            bool alreadyStored = false;
            for(int i = 0; i < m_supportCount && !alreadyStored; i++)
              {
               if(m_supportPeaks[i].barIndex == bar)
                  alreadyStored = true;
              }

            if(!alreadyStored)
              {
               SFractalPeak minorRetest;
               CreatePeakEntry(bar, false, minorRetest);
               minorRetest.isActive = false;
               AddSupportPeak(minorRetest);
              }
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Marks a resistance peak as triggered (used for a trade)            |
   //+------------------------------------------------------------------+
   void              MarkResistPeakTriggered(int barIndex)
     {
      for(int i = 0; i < m_resistCount; i++)
        {
         if(m_resistPeaks[i].barIndex == barIndex)
           {
            m_resistPeaks[i].wasTriggered = true;
            break;
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Marks a support peak as triggered (used for a trade)               |
   //+------------------------------------------------------------------+
   void              MarkSupportPeakTriggered(int barIndex)
     {
      for(int i = 0; i < m_supportCount; i++)
        {
         if(m_supportPeaks[i].barIndex == barIndex)
           {
            m_supportPeaks[i].wasTriggered = true;
            break;
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Gets all stored resistance peaks                                   |
   //+------------------------------------------------------------------+
   int               GetResistancePeaks(SFractalPeak &outArray[]) const
     {
      ArrayResize(outArray, m_resistCount);
      for(int i = 0; i < m_resistCount; i++)
         outArray[i] = m_resistPeaks[i];
      return m_resistCount;
     }

   //+------------------------------------------------------------------+
   //| Gets all stored support peaks                                      |
   //+------------------------------------------------------------------+
   int               GetSupportPeaks(SFractalPeak &outArray[]) const
     {
      ArrayResize(outArray, m_supportCount);
      for(int i = 0; i < m_supportCount; i++)
         outArray[i] = m_supportPeaks[i];
      return m_supportCount;
     }

   //+------------------------------------------------------------------+
   //| Gets the count of resistance peaks                                 |
   //+------------------------------------------------------------------+
   int               GetResistCount(void) const
     {
      return m_resistCount;
     }

   //+------------------------------------------------------------------+
   //| Gets the count of support peaks                                    |
   //+------------------------------------------------------------------+
   int               GetSupportCount(void) const
     {
      return m_supportCount;
     }

   //+------------------------------------------------------------------+
   //| Gets the active resistance peak (if any) — direct pointer to array |
   //+------------------------------------------------------------------+
   bool              GetActiveResistance(SFractalPeak &outPeak) const
     {
      for(int i = 0; i < m_resistCount; i++)
        {
         if(m_resistPeaks[i].isActive)
           {
            outPeak = m_resistPeaks[i];
            return true;
           }
        }
      return false;
     }

   //+------------------------------------------------------------------+
   //| Gets the active support peak (if any)                              |
   //+------------------------------------------------------------------+
   bool              GetActiveSupport(SFractalPeak &outPeak) const
     {
      for(int i = 0; i < m_supportCount; i++)
        {
         if(m_supportPeaks[i].isActive)
           {
            outPeak = m_supportPeaks[i];
            return true;
           }
        }
      return false;
     }

   //+------------------------------------------------------------------+
   //| Gets the peak count since init (for stats)                         |
   //+------------------------------------------------------------------+
   int               GetTotalPeaksDetected(void) const
     {
      return m_resistCount + m_supportCount;
     }
  };

//+------------------------------------------------------------------+
#endif  // __MARKET_STRUCTURE__