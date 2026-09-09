//+------------------------------------------------------------------+
//|                                                  CSniperBlock.mqh |
//|                 Module 4 â€” Wick1+Wick2 Overlap & ATR Veto          |
//|                             Otto EA - Institutional Grade   |
//+------------------------------------------------------------------+
#property copyright "Otto EA"
#property version   "1.00"

#ifndef __SNIPER_BLOCK__
#define __SNIPER_BLOCK__

#include "CommonDefines.mqh"
#include "CMarketStructure.mqh"

//+------------------------------------------------------------------+
//| CSniperBlock class                                                |
//| Pairs Major Anchors with Minor Retests to form S/R blocks         |
//| Validates blocks with ATR sizing & detects block breakage         |
//+------------------------------------------------------------------+
class CSniperBlock
  {
private:
   string            m_symbol;
   CMarketStructure *m_marketStruct;
   int               m_leftBars;         // Input: Left Bars for Pivot Calculation
   int               m_rightBars;        // Input: Right Bars for Pivot Calculation
   bool              m_useFvgVeto;       // Input: Enable Fair Value Gap Veto
   bool              m_useMomVeto;       // Input: Enable Momentum Veto
   bool              m_useSeparationVeto; // Input: Enable Separation Veto
   bool              m_useNearMissVeto;  // Input: Enable Near Miss Veto (6 Days)
   bool              m_useFrontRunVeto;  // Input: Enable Front-Run Veto (1:3 Target)
   bool              m_useStaleVeto;     // Input: Enable Stale Veto (45 Days)
   string            m_entryStyle;       // Entry style: "Front Edge" or "Midpoint"
   double            m_armAtr;           // Arming distance (ATR multiples) — 0.0 = instant arming

   // --- Active blocks ---
   SSniperBlock      m_blocks[];
   int               m_blockCount;

   // --- ATR handle ---
   int               m_atrHandle;
   double            m_currentATR;
   double            m_atrBuffer[];

   // --- Market Day Tracker ---
   int               m_currentMarketDay; // Tracks market open days for vetoes
   datetime          m_lastDailyCheck;   // Last time we checked for a new market day

   // --- Statistics ---
   int               m_blocksCreated;
   int               m_blocksBroken;
   int               m_blocksVetoed;
   int               m_blocksFlipped;
   int               m_lastCreationBar;
   long              m_globalAnchorCounter;


   //+------------------------------------------------------------------+
   //| Retrieves current ATR value                                        |
   //+------------------------------------------------------------------+
   double            GetCurrentATR(void)
     {
      if(m_atrHandle == INVALID_HANDLE)
         return 0;
      if(CopyBuffer(m_atrHandle, 0, 0, 1, m_atrBuffer) > 0)
         return m_atrBuffer[0];
      return 0;
     }

   //+------------------------------------------------------------------+
   //| Checks if two price ranges (wicks) overlap                         |
   //+------------------------------------------------------------------+
   bool              DoWicksOverlap(SFractalPeak &p1, SFractalPeak &p2)
     {
      double p1Low  = p1.lowPrice;
      double p1High = p1.highPrice;
      double p2Low  = p2.lowPrice;
      double p2High = p2.highPrice;
      if(p1High >= p2Low && p1Low <= p2High)
         return true;
      return false;
     }

   //+------------------------------------------------------------------+
   //| Calculates block dimensions per the Pine Script v4.70 spec       |
   //|   Resistance wick zone = high[rb] .. max(open,close)             |
   //|   Support    wick zone = min(open,close) .. low[rb]              |
   //|   (Zone-from-two-pivots implemented inline below; the previous   |
   //|    GetLowestBody/GetHighestBody helpers were removed in v4.70    |
   //|    alignment because they used the wrong body edge.)              |
   //+------------------------------------------------------------------+
   void              CalculateBlockDimensions(SSniperBlock &block)
     {
      SFractalPeak w1 = block.wick1;
      SFractalPeak w2 = block.wick2;
      if(block.type == BLOCK_RESISTANCE)
        {
         // Pine v4.70: each resistance wick zone = high[rb] (top) .. max(open[rb],close[rb]) (bottom)
         //   => block top    = max of the two wick tops
         //   => block bottom = min of the two wick bodies' HIGH (max(open,close))
         block.top    = MathMax(w1.highPrice, w2.highPrice);
         block.bottom = MathMin(MathMax(w1.openPrice, w1.closePrice),
                                MathMax(w2.openPrice, w2.closePrice));
        }
      else
        {
         // Pine v4.70: each support wick zone = min(open[rb],close[rb]) (top) .. low[rb] (bottom)
         //   => block top    = max of the two wick bodies' LOW (min(open,close))
         //   => block bottom = min of the two wick bottoms (low)
         block.top    = MathMax(MathMin(w1.openPrice, w1.closePrice),
                                MathMin(w2.openPrice, w2.closePrice));
         block.bottom = MathMin(w1.lowPrice, w2.lowPrice);
        }
      block.blockHeight = MathAbs(block.top - block.bottom);
      block.midpoint    = (block.top + block.bottom) / 2.0;
     }

   //+------------------------------------------------------------------+
   //| Checks ATR sizing veto rules                                       |
   //+------------------------------------------------------------------+
   bool              ValidateBlockByATR(SSniperBlock &block)
     {
      double atr = m_currentATR;
      if(atr <= 0)
        {
         if(EnableLogging)
            Print("[SniperBlock] WARNING: ATR not available â€” skipping veto");
         return true;
        }
      double minHeight = ATRVetoMin * atr;
      double maxHeight = ATRVetoMax * atr;
      if(block.blockHeight < minHeight)
        {
         if(EnableLogging)
            Print("[SniperBlock] Block VETOED (too small): Height=",
                  DoubleToString(block.blockHeight, Digits()),
                  " | Min=", DoubleToString(minHeight, Digits()),
                  " | ATR=", DoubleToString(atr, Digits()));
         m_blocksVetoed++;
         return false;
        }
      if(block.blockHeight > maxHeight)
        {
         if(EnableLogging)
            Print("[SniperBlock] Block VETOED (too large/dangerous): Height=",
                  DoubleToString(block.blockHeight, Digits()),
                  " | Max=", DoubleToString(maxHeight, Digits()),
                  " | ATR=", DoubleToString(atr, Digits()));
         m_blocksVetoed++;
         return false;
        }
      return true;
     }

   //+------------------------------------------------------------------+
   //| Checks if a block has been broken                                 |
   //+------------------------------------------------------------------+
   bool              IsBlockBroken(SSniperBlock &block)
     {
      double atr = m_currentATR;
      if(atr <= 0) return false;
      double buffer = ATRBufferBreak * atr;
      for(int bar = 0; bar <= 2; bar++)
        {
         double close = iClose(m_symbol, PERIOD_CURRENT, bar);
         if(block.type == BLOCK_RESISTANCE)
           {
            if(close > block.top + buffer) return true;
           }
         else
           {
            if(close < block.bottom - buffer) return true;
           }
        }
      return false;
     }

   //+------------------------------------------------------------------+
   //| Removes a block at the given index                                |
   //+------------------------------------------------------------------+
   void              RemoveBlock(int index)
     {
      if(index < 0 || index >= m_blockCount) return;
      for(int i = index; i < m_blockCount - 1; i++)
         m_blocks[i] = m_blocks[i + 1];
      m_blockCount--;
     }

   //+------------------------------------------------------------------+
   //| Checks if a block already exists for the same peaks               |
   //+------------------------------------------------------------------+
   bool              BlockExistsForPeaks(int w1BarIndex, int w2BarIndex)
     {
      for(int i = 0; i < m_blockCount; i++)
        {
         if(m_blocks[i].wick1.barIndex == w1BarIndex &&
            m_blocks[i].wick2.barIndex == w2BarIndex)
            return true;
        }
      return false;
     }

   //+------------------------------------------------------------------+
   //| MODULE 2: Cluster filter â€” checks if midpoint is within 1.0Ã—ATR  |
   //| of any existing block. Prevents overlapping blocks in tight ranges|
   //+------------------------------------------------------------------+
   bool              IsWithinClusterDistance(double newMidpoint)
     {
      if(m_currentATR <= 0) return false;
      double minDist = 1.0 * m_currentATR;
      for(int i = 0; i < m_blockCount; i++)
        {
         double dist = MathAbs(m_blocks[i].midpoint - newMidpoint);
         if(dist < minDist) return true;
        }
      return false;
     }

public:
   //+------------------------------------------------------------------+
   //| Constructor                                                       |
   //+------------------------------------------------------------------+
                     CSniperBlock(void)
      {
       m_symbol            = "";
       m_marketStruct      = NULL;
       m_leftBars          = 0;
       m_rightBars         = 0;
       m_useFvgVeto        = false;
       m_useMomVeto        = false;
       m_useSeparationVeto = false;
       m_useNearMissVeto   = false;
       m_useFrontRunVeto   = false;
       m_useStaleVeto      = false;
       m_blockCount        = 0;
       m_atrHandle         = INVALID_HANDLE;
       m_currentATR        = 0;
       m_currentMarketDay  = 0;
       m_lastDailyCheck    = 0;
       m_blocksCreated     = 0;
       m_blocksBroken      = 0;
       m_blocksVetoed      = 0;
       m_blocksFlipped     = 0;
       m_lastCreationBar   = -1;
       m_globalAnchorCounter = 1;
       ArrayResize(m_blocks, 0, MAX_BLOCKS);
       ArrayResize(m_atrBuffer, 1);
      }

   //+------------------------------------------------------------------+
   //| Destructor                                                        |
   //+------------------------------------------------------------------+
                    ~CSniperBlock(void)
     {
      ArrayFree(m_blocks);
      ArrayFree(m_atrBuffer);
      if(m_atrHandle != INVALID_HANDLE)
         IndicatorRelease(m_atrHandle);
     }

   //+------------------------------------------------------------------+
   //| Initialize                                                        |
   //+------------------------------------------------------------------+
   bool              Initialize(string symbol, CMarketStructure *marketStruct,
                                int leftBars, int rightBars,
                                bool useFvgVeto, bool useMomVeto, bool useSeparationVeto,
                                bool useNearMissVeto, bool useFrontRunVeto, bool useStaleVeto,
                                string entryStyle, double armAtr)
     {
      m_symbol            = symbol;
      m_marketStruct      = marketStruct;
      m_leftBars          = leftBars;
      m_rightBars         = rightBars;
      m_useFvgVeto        = useFvgVeto;
      m_useMomVeto        = useMomVeto;
      m_useSeparationVeto = useSeparationVeto;
      m_useNearMissVeto   = useNearMissVeto;
      m_useFrontRunVeto   = useFrontRunVeto;
      m_useStaleVeto      = useStaleVeto;
      m_entryStyle        = entryStyle;
      m_armAtr            = armAtr;

      m_atrHandle = iATR(m_symbol, PERIOD_CURRENT, ATRPeriod);
      if(m_atrHandle == INVALID_HANDLE)
        {
         Print("[SniperBlock] ERROR: Failed to create ATR indicator handle");
         return false;
        }

      // Initialize market day tracker
      MqlDateTime dt;    
      TimeCurrent(dt);
      m_lastDailyCheck = StructToTime(dt);
      m_currentMarketDay = 0; // Will be incremented on first new day check

      if(EnableLogging)
         Print("[SniperBlock] Initialized for ", m_symbol,
               " | ATR Period: ", ATRPeriod,
               " | Veto Range: ", ATRVetoMin, "x - ", ATRVetoMax, "x ATR",
               " | Pivots: L=", m_leftBars, " R=", m_rightBars);
      return true;
     }

   //+------------------------------------------------------------------+
   //| Updates the market day counter                                     |
   //+------------------------------------------------------------------+
   void              UpdateMarketDay(void)
     {
      MqlDateTime dt;
      TimeCurrent(dt);
      datetime today = StructToTime(dt);

      if(today != m_lastDailyCheck)
        {
         // Check if it's a new market day (skip weekends for counting).
         // MQL5: MqlDateTime.day_of_week — 0=Sunday, 1=Monday, ... 6=Saturday.
         if(dt.day_of_week != 6 && dt.day_of_week != 0)
           {
            m_currentMarketDay++;
           }
         m_lastDailyCheck = today;
        }
     }

   //+------------------------------------------------------------------+
   //| Ages relative bar shifts and countdown timers on a new bar close  |
   //+------------------------------------------------------------------+
   void              AgeAllBlocks(void)
     {
      for(int i = 0; i < m_blockCount; i++)
        {
         m_blocks[i].wick1.barIndex++;
         m_blocks[i].wick2.barIndex++;
         if(m_blocks[i].anchorDay != 0)
           {
            m_blocks[i].anchorBar++;
           }
         // Countdown deleteOnBar if it is active (e.g. set to 1 to delete on next bar close)
         if(m_blocks[i].deleteOnBar > 0)
           {
            m_blocks[i].deleteOnBar--;
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Main update                                                       |
   //+------------------------------------------------------------------+
    void              Update(void)
      {
       m_currentATR = GetCurrentATR();
       UpdateMarketDay(); // Update market day count first

       datetime currentBarTime = iTime(m_symbol, PERIOD_CURRENT, 0);
       static datetime lastBarTime = 0;
       bool isNewBar = (currentBarTime != lastBarTime);
       
       if(isNewBar)
         {
          lastBarTime = currentBarTime;
          
          // Age relative bar shifts and countdowns
          AgeAllBlocks();
          
          // Try to create new blocks (on bar close)
          TryCreateNewBlocks();
          
          // Run bar close block processing (stale, momentum, FVG veto checks)
          ProcessBlocksOnBarClose();
         }

       // Every tick processing (Exit check, Front-Run check, Near Miss proximity check, Breakage/Flipped check, Arming check)
       ProcessBlocksOnTick();
       
       CleanupStaleBlocks();
      }
    
   //+------------------------------------------------------------------+
   //| Gets all valid (unbroken) blocks                                   |
   //+------------------------------------------------------------------+
   int               GetValidBlocks(SSniperBlock &outBlocks[]) const
     {
      int count = 0;
      for(int i = 0; i < m_blockCount; i++)
        {
         if(m_blocks[i].status == BLOCK_STATUS_ARMED || m_blocks[i].status == BLOCK_STATUS_NEW)
            count++;
        }
      ArrayResize(outBlocks, count);
      int idx = 0;
      for(int i = 0; i < m_blockCount; i++)
        {
         if(m_blocks[i].status == BLOCK_STATUS_ARMED || m_blocks[i].status == BLOCK_STATUS_NEW)
           {
            outBlocks[idx] = m_blocks[i];
            idx++;
           }
        }
      return count;
     }

   //+------------------------------------------------------------------+
   //| Gets all blocks (including broken)                                 |
   //+------------------------------------------------------------------+
   int               GetAllBlocks(SSniperBlock &outBlocks[]) const
     {
      ArrayResize(outBlocks, m_blockCount);
      for(int i = 0; i < m_blockCount; i++)
         outBlocks[i] = m_blocks[i];
      return m_blockCount;
     }

   //+------------------------------------------------------------------+
   //| Marks a block's limit order ticket                                 |
   //+------------------------------------------------------------------+
   void              SetBlockOrderTicket(int blockIndex, ulong ticket)
     {
      if(blockIndex >= 0 && blockIndex < m_blockCount)
         m_blocks[blockIndex].limitOrderTicket = ticket;
     }

   //+------------------------------------------------------------------+
   //| MODULE 4: DeleteBlockType â€” Removes all blocks of a given type    |
   //| Used by Hive Mind tie-breaker to delete conflicting blocks        |
   //+------------------------------------------------------------------+
   void              DeleteBlockType(ENUM_BLOCK_TYPE type)
     {
      for(int i = m_blockCount - 1; i >= 0; i--)
        {
         if(m_blocks[i].type == type && (m_blocks[i].status == BLOCK_STATUS_NEW || m_blocks[i].status == BLOCK_STATUS_ARMED))
           {
            // Mark for deletion and update stats
            m_blocks[i].status = BLOCK_STATUS_DELETED;
            m_blocks[i].deleteOnBar = InpGetCurrentBar() + 1;
            m_blocksVetoed++; // Count as vetoed due to conflict resolution
            if(EnableLogging)
               Print("[SniperBlock] Block DELETED (Conflict). Block ID:", m_blocks[i].wick1.barIndex, "-", m_blocks[i].wick2.barIndex);
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Gets current ATR                                                   |
   //+------------------------------------------------------------------+
   double            GetATR(void) const
     {
      return m_currentATR;
     }

   int               GetBlocksCreated(void) const { return m_blocksCreated; }
   int               GetBlocksBroken(void) const { return m_blocksBroken; }
   int               GetBlocksVetoed(void) const { return m_blocksVetoed; }
   int               GetBlocksFlipped(void) const { return m_blocksFlipped; }
   int               GetBlockCount(void) const { return m_blockCount; }

   //+------------------------------------------------------------------+
   //| New Public Methods for accessing block properties                |
   //+------------------------------------------------------------------+
   bool              GetBlockByIndex(int index, SSniperBlock &outBlock) const
     {
      if(index >= 0 && index < m_blockCount)
        {
         outBlock = m_blocks[index];
         return true;
        }
      return false;
     }

   void              SetBlockStatus(int index, ENUM_BLOCK_STATUS status)
     {
      if(index >= 0 && index < m_blockCount)
         m_blocks[index].status = status;
     }

   void              SetBlockTradeId(int index, string tradeId)
     {
      if(index >= 0 && index < m_blockCount)
         m_blocks[index].tradeId = tradeId;
     }

   void              SetBlockOrderParams(int index, double sl, double tp, double entry, double rrUnit)
     {
      if(index >= 0 && index < m_blockCount)
        {
         m_blocks[index].localSl = sl;
         m_blocks[index].localTp = tp;
         m_blocks[index].localEntry = entry;
         m_blocks[index].rrUnit = rrUnit;
         m_blocks[index].hasPlacedOrder = true;
        }
     }

   void              SetBlockTriggered(int index)
     {
      if(index >= 0 && index < m_blockCount)
        {
         m_blocks[index].isTriggered = true;
         m_blocks[index].status = BLOCK_STATUS_TRADE_EXECUTED;
         m_blocks[index].deleteOnBar = InpGetCurrentBar() + 1; // Mark for cleanup after execution
        }
     }

   //+------------------------------------------------------------------+
   //| Scans for anchor+retest pairs                                     |
   //+------------------------------------------------------------------+
   void              TryCreateNewBlocks(void)
     {
      if(m_marketStruct == NULL) return;
      datetime currentBarTime = iTime(m_symbol, PERIOD_CURRENT, 0);
      static datetime lastAttemptTime = 0;
      if(currentBarTime == lastAttemptTime) return;
      lastAttemptTime = currentBarTime;

      SFractalPeak resistPeaks[];
      int resistCount = m_marketStruct.GetResistancePeaks(resistPeaks);
      SFractalPeak supportPeaks[];
      int supportCount = m_marketStruct.GetSupportPeaks(supportPeaks);

      // Pine v4.70 pairs each new pivot (Wick 2) with the IMMEDIATELY preceding
      // pivot (Wick 1) from the SAME Left=8/Right=3 pivot stream. We therefore
      // only pair consecutive peaks (i -> i+1), not all combinations.
      for(int i = 0; i < resistCount - 1 && m_blockCount < MAX_BLOCKS; i++)
        {
         SFractalPeak w1 = resistPeaks[i];
         SFractalPeak w2 = resistPeaks[i + 1];
         TryFormBlock(w1, w2, BLOCK_RESISTANCE);
        }
      for(int i = 0; i < supportCount - 1 && m_blockCount < MAX_BLOCKS; i++)
        {
         SFractalPeak w1 = supportPeaks[i];
         SFractalPeak w2 = supportPeaks[i + 1];
         TryFormBlock(w1, w2, BLOCK_SUPPORT);
        }
     }

   //+------------------------------------------------------------------+
   //| Attempts to form a single block from two peaks                     |
   //+------------------------------------------------------------------+
   bool              TryFormBlock(SFractalPeak  &p1,
                                  SFractalPeak  &p2,
                                  ENUM_BLOCK_TYPE type)
     {
      SFractalPeak anchor, retest;
      int barDiff;
      if(p1.barIndex > p2.barIndex)
        { anchor = p1; retest = p2; }
      else
        { anchor = p2; retest = p1; }
      barDiff = anchor.barIndex - retest.barIndex;

      if(barDiff < MinBlockDistance || barDiff > MaxBlockDistance)
         return false;
      if(!DoWicksOverlap(anchor, retest))
         return false;
      if(BlockExistsForPeaks(anchor.barIndex, retest.barIndex))
         return false;

      SSniperBlock newBlock;
      ZeroMemory(newBlock);
      newBlock.type         = type;
      newBlock.wick1        = anchor;
      newBlock.wick2        = retest;
       newBlock.isValid      = false; // Legacy flag, will be updated to status
       newBlock.isBroken     = false; // Legacy flag, will be updated to status
       newBlock.status       = BLOCK_STATUS_NEW;
       newBlock.isArmed      = false;
       newBlock.isTriggered  = false;
       newBlock.isFlipped    = false;
       newBlock.deleteOnBar  = 0;
       newBlock.tradeId      = ""; // MQL5 string defaults to empty, not NA
       newBlock.hasPlacedOrder = false;
       newBlock.localSl      = 0.0;
       newBlock.localTp      = 0.0;
       newBlock.localEntry   = 0.0;
       newBlock.rrUnit       = 0.0;
       newBlock.hasExited    = false;
       newBlock.minProxDist  = 0.0;
       newBlock.anchorBar    = 0;
       newBlock.anchorDay    = 0;
       newBlock.anchorPrice  = 0.0;
       newBlock.anchorId     = 0;
       newBlock.w1Day        = m_currentMarketDay;

       newBlock.limitOrderTicket = 0;
       newBlock.creationTime = TimeCurrent();
       newBlock.atrAtCreation = m_currentATR;

       CalculateBlockDimensions(newBlock);
       bool passesAtrSizing = ValidateBlockByATR(newBlock);

       if(!passesAtrSizing)
         {
          newBlock.status = BLOCK_STATUS_VETOED_SIZING;
          if(EnableLogging)
             Print("[SniperBlock] Block VETOED (sizing) during creation. Block ID:", newBlock.wick1.barIndex, "-", newBlock.wick2.barIndex);
         }

       // Cluster filter â€” veto if within 1.0Ã—ATR of existing block
       if(IsWithinClusterDistance(newBlock.midpoint))
         {
          newBlock.status = BLOCK_STATUS_VETOED_FVG; // Using FVG for now, will refine
          if(EnableLogging)
             Print("[SniperBlock] Cluster VETO: Mid ",
                   DoubleToString(newBlock.midpoint, Digits()),
                   " within 1.0Ã—ATR of existing block â€” discarded. Block ID:", newBlock.wick1.barIndex, "-", newBlock.wick2.barIndex);
         }

       if(newBlock.status == BLOCK_STATUS_NEW)
         {
          newBlock.isValid = true; // Passed creation vetos (sizing/cluster) => eligible for order placement
          ArrayResize(m_blocks, m_blockCount + 1, MAX_BLOCKS);
          m_blocks[m_blockCount] = newBlock;
          m_blockCount++;
          m_blocksCreated++;
          if(EnableLogging)
             Print("[SniperBlock] Block CREATED (",
                   (type == BLOCK_RESISTANCE ? "RESISTANCE" : "SUPPORT"),
                   ") | Mid=", DoubleToString(newBlock.midpoint, Digits()),
                   " | Height=", DoubleToString(newBlock.blockHeight, Digits()),
                   " | Bar: ", newBlock.wick2.barIndex);
         }
       else
         {
          // Block was vetoed during creation (sizing or cluster). Keep it in the array
          // briefly for stats/logging, mark it vetoed, and schedule deterministic removal
          // after one bar (deleteOnBar countdown handled by AgeAllBlocks + CleanupStaleBlocks).
          newBlock.isVetoed  = true;
          newBlock.deleteOnBar = 1; // remove after the next bar close
          ArrayResize(m_blocks, m_blockCount + 1, MAX_BLOCKS);
          m_blocks[m_blockCount] = newBlock;
          m_blockCount++;
         }
       return newBlock.status == BLOCK_STATUS_NEW;
     }

   //+------------------------------------------------------------------+
   //| Processes all active blocks on a new bar close                   |
   //+------------------------------------------------------------------+
   void              ProcessBlocksOnBarClose(void)
     {
      for(int i = m_blockCount - 1; i >= 0; i--)
        {

         // Skip if terminal status
         if(m_blocks[i].status >= BLOCK_STATUS_BROKEN && m_blocks[i].status != BLOCK_STATUS_ORDER_PLACED)
           {
            continue;
           }

         // --- 45-DAY STALE VETO LOGIC (configurable via StaleVetoDays) ---
         if(m_useStaleVeto && !m_blocks[i].isTriggered && !m_blocks[i].isVetoed)
           {
            if(m_blocks[i].w1Day != 0)
              {
               int daysSinceW1 = m_currentMarketDay - m_blocks[i].w1Day;
               if(daysSinceW1 >= StaleVetoDays)
                 {
                  m_blocks[i].isVetoed = true;
                  m_blocks[i].status = BLOCK_STATUS_VETOED_STALE;
                  m_blocks[i].deleteOnBar = 1; // Delete on next bar close
                  m_blocksVetoed++;
                  if(EnableLogging)
                     Print("[SniperBlock] Block VETOED: Stale (", StaleVetoDays, "D). Block ID:", m_blocks[i].wick1.barIndex, "-", m_blocks[i].wick2.barIndex);
                  continue;
                 }
              }
           }

         // --- INDEPENDENT 6-DAY NEAR MISS LOGIC (Expiration check) ---
         if(m_useNearMissVeto && m_blocks[i].hasExited && !m_blocks[i].isTriggered)
           {
            if(m_blocks[i].anchorDay != 0)
              {
               int daysPassed = m_currentMarketDay - m_blocks[i].anchorDay;
               if(daysPassed >= 6)
                 {
                  m_blocks[i].isVetoed = true;
                  m_blocks[i].status = BLOCK_STATUS_VETOED_NEAR_MISS;
                  m_blocks[i].deleteOnBar = 1;
                  m_blocksVetoed++;
                  if(EnableLogging)
                     Print("[SniperBlock] Block VETOED: Near Miss (6D). Block ID:", m_blocks[i].wick1.barIndex, "-", m_blocks[i].wick2.barIndex);
                  continue;
                 }
              }
           }

         // --- MOMENTUM & FVG VETO LOGIC (only for armed blocks before trigger) ---
         if(m_blocks[i].isArmed && m_blocks[i].status == BLOCK_STATUS_ARMED && !m_blocks[i].isTriggered)
           {
            bool momentumVeto = false;
            bool fvgVeto = false;

            for(int j = 0; j <= 7; j++)
              {
               if(m_useMomVeto && (iHigh(m_symbol, PERIOD_CURRENT, j) - iLow(m_symbol, PERIOD_CURRENT, j)) > (3.5 * GetATR(j)))
                 {
                  momentumVeto = true;
                  break;
                 }
               if(m_useFvgVeto)
                 {
                  double high_j = iHigh(m_symbol, PERIOD_CURRENT, j);
                  double low_j = iLow(m_symbol, PERIOD_CURRENT, j);
                  double high_j2 = iHigh(m_symbol, PERIOD_CURRENT, j + 2);
                  double low_j2 = iLow(m_symbol, PERIOD_CURRENT, j + 2);

                  if(m_blocks[i].type == BLOCK_SUPPORT && (high_j < low_j2))
                    {
                     fvgVeto = true;
                     break;
                    }
                  if(m_blocks[i].type == BLOCK_RESISTANCE && (low_j > high_j2))
                    {
                     fvgVeto = true;
                     break;
                    }
                 }
              }

            if(momentumVeto)
              {
               m_blocks[i].isVetoed = true;
               m_blocks[i].status = BLOCK_STATUS_VETOED_MOMENTUM;
               m_blocks[i].deleteOnBar = 1;
               m_blocksVetoed++;
               if(EnableLogging)
                  Print("[SniperBlock] Block VETOED: Momentum. Block ID:", m_blocks[i].wick1.barIndex, "-", m_blocks[i].wick2.barIndex);
               continue;
              }
            else if(fvgVeto)
              {
               m_blocks[i].isVetoed = true;
               m_blocks[i].status = BLOCK_STATUS_VETOED_FVG;
               m_blocks[i].deleteOnBar = 1;
               m_blocksVetoed++;
               if(EnableLogging)
                  Print("[SniperBlock] Block VETOED: FVG. Block ID:", m_blocks[i].wick1.barIndex, "-", m_blocks[i].wick2.barIndex);
               continue;
              }
           }

         // --- Separation Veto (v4.70) ---
         if(m_useSeparationVeto && m_blocks[i].status == BLOCK_STATUS_NEW)
           {
            bool hasSeparation = CheckSeparationVeto(m_blocks[i]);
            if(!hasSeparation)
              {
               m_blocks[i].isVetoed = true;
               m_blocks[i].status = BLOCK_STATUS_VETOED_SEPARATION;
               m_blocks[i].deleteOnBar = 1;
               m_blocksVetoed++;
               if(EnableLogging)
                  Print("[SniperBlock] Block VETOED: No Separation. Block ID:", m_blocks[i].wick1.barIndex, "-", m_blocks[i].wick2.barIndex);
               continue;
              }
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Processes block logic on every tick (Entry, Front-Run, etc.)     |
   //+------------------------------------------------------------------+
   void              ProcessBlocksOnTick(void)
     {
      for(int i = m_blockCount - 1; i >= 0; i--)
        {

         // Skip if terminal status
         if(m_blocks[i].status >= BLOCK_STATUS_BROKEN && m_blocks[i].status != BLOCK_STATUS_ORDER_PLACED)
           {
            continue;
           }

         // --- Block Exit Check (has price left the zone yet?) ---
         if(!m_blocks[i].hasExited)
           {
            if((m_blocks[i].type == BLOCK_SUPPORT && iLow(m_symbol, PERIOD_CURRENT, 0) > m_blocks[i].top) ||
               (m_blocks[i].type == BLOCK_RESISTANCE && iHigh(m_symbol, PERIOD_CURRENT, 0) < m_blocks[i].bottom))
              {
               m_blocks[i].hasExited = true;
              }
           }

         // --- INDEPENDENT FRONT-RUN VETO (1:3 TARGET HIT) ---
         if(m_useFrontRunVeto && m_blocks[i].hasExited && !m_blocks[i].isTriggered)
           {
            double entryStylePrice = (m_entryStyle == "Midpoint") ? m_blocks[i].midpoint : (m_blocks[i].type == BLOCK_SUPPORT ? m_blocks[i].top : m_blocks[i].bottom);
            double currentAtr = m_currentATR;
            double calcSlDist = m_blocks[i].blockHeight + (0.5 * currentAtr);
            double targetPrice = m_blocks[i].type == BLOCK_SUPPORT ? (entryStylePrice + (3.0 * calcSlDist)) : (entryStylePrice - (3.0 * calcSlDist));

            // If order was placed, use actual TP
            if(m_blocks[i].hasPlacedOrder && m_blocks[i].localTp != 0)
              {
               targetPrice = m_blocks[i].localTp;
              }

            bool targetHit = (m_blocks[i].type == BLOCK_SUPPORT) ? (iHigh(m_symbol, PERIOD_CURRENT, 0) >= targetPrice) : (iLow(m_symbol, PERIOD_CURRENT, 0) <= targetPrice);

            if(targetHit)
              {
               m_blocks[i].isVetoed = true;
               m_blocks[i].status = BLOCK_STATUS_VETOED_FRONT_RUN;
               m_blocks[i].deleteOnBar = 1;
               m_blocksVetoed++;
               if(EnableLogging)
                  Print("[SniperBlock] Block VETOED: 1:3 Target Hit (Front-Run). Block ID:", m_blocks[i].wick1.barIndex, "-", m_blocks[i].wick2.barIndex);
               continue;
              }
           }

         // --- INDEPENDENT 6-DAY NEAR MISS LOGIC (Proximity tracking) ---
         if(m_useNearMissVeto && m_blocks[i].hasExited && !m_blocks[i].isTriggered)
           {
            bool inProx = false;
            double currentDist = 0.0;
            double currentPriceExtreme = (m_blocks[i].type == BLOCK_SUPPORT) ? iLow(m_symbol, PERIOD_CURRENT, 0) : iHigh(m_symbol, PERIOD_CURRENT, 0);

            // Proximity Zone: 1 Block Height away from the edge
            if(m_blocks[i].type == BLOCK_SUPPORT && currentPriceExtreme <= (m_blocks[i].top + m_blocks[i].blockHeight) && currentPriceExtreme > m_blocks[i].top)
              {
               inProx = true;
               currentDist = currentPriceExtreme - m_blocks[i].top;
              }
            else if(m_blocks[i].type == BLOCK_RESISTANCE && currentPriceExtreme >= (m_blocks[i].bottom - m_blocks[i].blockHeight) && currentPriceExtreme < m_blocks[i].bottom)
              {
               inProx = true;
               currentDist = m_blocks[i].bottom - currentPriceExtreme;
              }

            if(inProx)
              {
               if(m_blocks[i].minProxDist == 0.0 || currentDist < m_blocks[i].minProxDist)
                 {
                  m_blocks[i].minProxDist = currentDist;
                  m_blocks[i].anchorBar = 0;
                  m_blocks[i].anchorDay = m_currentMarketDay;
                  m_blocks[i].anchorPrice = currentPriceExtreme;

                  if(m_blocks[i].anchorId == 0)
                    {
                     m_blocks[i].anchorId = m_globalAnchorCounter++;
                    }
                 }
              }
           }

         // --- CORE ARMING LOGIC ---
         if(!m_blocks[i].isArmed && m_blocks[i].status == BLOCK_STATUS_NEW)
           {
            double close = iClose(m_symbol, PERIOD_CURRENT, 0);
            if(m_blocks[i].type == BLOCK_SUPPORT && close > (m_blocks[i].top + (m_armAtr * m_currentATR)))
              {
               m_blocks[i].isArmed = true;
               m_blocks[i].status = BLOCK_STATUS_ARMED;
               if(EnableLogging)
                  Print("[SniperBlock] Block ARMED (Support). Block ID:", m_blocks[i].wick1.barIndex, "-", m_blocks[i].wick2.barIndex);
              }
            else if(m_blocks[i].type == BLOCK_RESISTANCE && close < (m_blocks[i].bottom - (m_armAtr * m_currentATR)))
              {
               m_blocks[i].isArmed = true;
               m_blocks[i].status = BLOCK_STATUS_ARMED;
               if(EnableLogging)
                  Print("[SniperBlock] Block ARMED (Resistance). Block ID:", m_blocks[i].wick1.barIndex, "-", m_blocks[i].wick2.barIndex);
              }
           }

         // --- Block Breakage and Flipped Logic ---
         if(IsBlockBroken(m_blocks[i]))
           {
            m_blocks[i].isBroken = true; // Mirror broken state so OrderManager can cancel resting orders
            double barRange = iHigh(m_symbol, PERIOD_CURRENT, 0) - iLow(m_symbol, PERIOD_CURRENT, 0);
            if(barRange > (2.0 * m_currentATR))
              {
               m_blocks[i].isFlipped = true;
               m_blocks[i].type = (m_blocks[i].type == BLOCK_SUPPORT) ? BLOCK_RESISTANCE : BLOCK_SUPPORT;
               m_blocks[i].status = BLOCK_STATUS_FLIPPED;
               m_blocks[i].deleteOnBar = 1;
               m_blocksFlipped++;
               if(EnableLogging)
                  Print("[SniperBlock] Block FLIPPED. Block ID:", m_blocks[i].wick1.barIndex, "-", m_blocks[i].wick2.barIndex);
              }
            else
              {
               m_blocks[i].status = BLOCK_STATUS_BROKEN;
               m_blocks[i].deleteOnBar = 1;
               m_blocksBroken++;
               if(EnableLogging)
                  Print("[SniperBlock] Block BROKEN. Block ID:", m_blocks[i].wick1.barIndex, "-", m_blocks[i].wick2.barIndex);
              }
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Checks all active blocks for breakage                             |
   //+------------------------------------------------------------------+
   void              CheckBlocksForBreakage(void)
     {
      // This is now integrated into ProcessBlocks
     }

   //+------------------------------------------------------------------+
   //| Removes blocks marked for deletion                                |
   //+------------------------------------------------------------------+
   void              CleanupStaleBlocks(void)
     {
      for(int i = m_blockCount - 1; i >= 0; i--)
        {
         // A block is terminal once it reaches a broken/flipped/vetoed/executed state.
         // Terminal blocks are scheduled for removal (deleteOnBar set > 0) and AgeAllBlocks()
         // decrements that countdown every new bar. Once it reaches 0 we free the memory now,
         // guaranteeing leak-free UDT (struct) management as required by the Pine v4.70 port.
         bool isTerminalDelete =
            m_blocks[i].status == BLOCK_STATUS_BROKEN ||
            m_blocks[i].status == BLOCK_STATUS_FLIPPED ||
            m_blocks[i].status == BLOCK_STATUS_TRADE_EXECUTED ||
            m_blocks[i].status == BLOCK_STATUS_DELETED ||
            (m_blocks[i].status >= BLOCK_STATUS_VETOED_SEPARATION &&
             m_blocks[i].status <= BLOCK_STATUS_VETOED_FVG); // all vetoed states, excludes ORDER_PLACED

         if(isTerminalDelete && m_blocks[i].deleteOnBar <= 0)
           {
            RemoveBlock(i);
            continue;
           }

         // Legacy fallback: purge extremely old NEW/ARMED blocks never caught by a veto.
         // (wick1.barIndex is bars-ago, maintained by AgeAllBlocks.)
         if(m_blocks[i].wick1.barIndex > MaxBlockDistance * 3)
           {
            RemoveBlock(i);
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Helper to get current bar index (assuming it's relative to current)|
   //+------------------------------------------------------------------+
   int               InpGetCurrentBar(void)
     {
      return 0; // Current bar is always 0 in MQL5 for current price data
     }

   //+------------------------------------------------------------------+
   //| Helper to get ATR at a specific bar shift                       |
   //+------------------------------------------------------------------+
   double            GetATR(int shift)
     {
      if(m_atrHandle == INVALID_HANDLE) return 0.0;
      if(CopyBuffer(m_atrHandle, 0, shift, 1, m_atrBuffer) > 0) return m_atrBuffer[0];
      return 0.0;
     }

   //+------------------------------------------------------------------+
   //| Checks for separation veto criteria                             |
   //+------------------------------------------------------------------+
   bool              CheckSeparationVeto(SSniperBlock &block)
     {
      if(!m_useSeparationVeto) return true; // Bypass if disabled

      // In MQL5 shifts, wick1.barIndex is kept current (bars-ago) by AgeAllBlocks();
      // this is the equivalent of Pine's (bar_index - w1_res_bar).
      int barsBackW1 = block.wick1.barIndex;
      // Pine v4.70: if there aren't enough bars strictly between W1 and W2
      // ((bars_back_w1 - w2_bar) <= 1) then has_separation remains false => VETO.
      if((barsBackW1 - block.wick2.barIndex) <= 1) return false; // Not enough bars between W1 & W2 -> no separation

      bool hasSeparation = false;
      for(int j = block.wick2.barIndex + 1; j < barsBackW1; j++)
        {
         if(block.type == BLOCK_RESISTANCE)
           {
            // For resistance, at least one candle between Wick 1 and Wick 2 must have its High strictly below the bottom of the block.
            if(iHigh(m_symbol, PERIOD_CURRENT, j) < block.bottom)
              {
               hasSeparation = true;
               break;
              }
           }
         else // BLOCK_SUPPORT
           {
            // For support, at least one candle's Low must be strictly above the top of the block.
            if(iLow(m_symbol, PERIOD_CURRENT, j) > block.top)
              {
               hasSeparation = true;
               break;
              }
           }
        }
      return hasSeparation;
     }

  };

#endif  // __SNIPER_BLOCK__

