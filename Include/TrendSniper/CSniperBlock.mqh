//+------------------------------------------------------------------+
//|                                                  CSniperBlock.mqh |
//|                 Module 4 — Wick1+Wick2 Overlap & ATR Veto          |
//|                             TrendSniper EA - Institutional Grade   |
//+------------------------------------------------------------------+
#property copyright "TrendSniper EA"
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

   // --- Active blocks ---
   SSniperBlock      m_blocks[];
   int               m_blockCount;

   // --- ATR handle ---
   int               m_atrHandle;
   double            m_currentATR;
   double            m_atrBuffer[];

   // --- Statistics ---
   int               m_blocksCreated;
   int               m_blocksBroken;
   int               m_blocksVetoed;
   int               m_lastCreationBar;

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
   //| Gets the lowest body price (min of open/close)                     |
   //+------------------------------------------------------------------+
   double            GetLowestBody(SFractalPeak &p1, SFractalPeak &p2)
     {
      double b1 = MathMin(p1.openPrice, p1.closePrice);
      double b2 = MathMin(p2.openPrice, p2.closePrice);
      return MathMin(b1, b2);
     }

   //+------------------------------------------------------------------+
   //| Gets the highest body price (max of open/close)                    |
   //+------------------------------------------------------------------+
   double            GetHighestBody(SFractalPeak &p1, SFractalPeak &p2)
     {
      double b1 = MathMax(p1.openPrice, p1.closePrice);
      double b2 = MathMax(p2.openPrice, p2.closePrice);
      return MathMax(b1, b2);
     }

   //+------------------------------------------------------------------+
   //| Calculates block dimensions per the spec                           |
   //+------------------------------------------------------------------+
   void              CalculateBlockDimensions(SSniperBlock &block)
     {
      SFractalPeak w1 = block.wick1;
      SFractalPeak w2 = block.wick2;
      if(block.type == BLOCK_RESISTANCE)
        {
         block.top = MathMax(w1.highPrice, w2.highPrice);
         block.bottom = GetLowestBody(w1, w2);
        }
      else
        {
         block.top = GetHighestBody(w1, w2);
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
            Print("[SniperBlock] WARNING: ATR not available — skipping veto");
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
   //| MODULE 2: Cluster filter — checks if midpoint is within 1.0×ATR  |
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
      m_symbol         = "";
      m_marketStruct   = NULL;
      m_blockCount     = 0;
      m_atrHandle      = INVALID_HANDLE;
      m_currentATR     = 0;
      m_blocksCreated  = 0;
      m_blocksBroken   = 0;
      m_blocksVetoed   = 0;
      m_lastCreationBar = -1;
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
   bool              Initialize(string symbol, CMarketStructure *marketStruct)
     {
      m_symbol       = symbol;
      m_marketStruct = marketStruct;
      m_atrHandle = iATR(m_symbol, PERIOD_CURRENT, ATRPeriod);
      if(m_atrHandle == INVALID_HANDLE)
        {
         Print("[SniperBlock] ERROR: Failed to create ATR indicator handle");
         return false;
        }
      if(EnableLogging)
         Print("[SniperBlock] Initialized for ", m_symbol,
               " | ATR Period: ", ATRPeriod,
               " | Veto Range: ", ATRVetoMin, "x - ", ATRVetoMax, "x ATR");
      return true;
     }

   //+------------------------------------------------------------------+
   //| Main update                                                       |
   //+------------------------------------------------------------------+
   void              Update(void)
     {
      m_currentATR = GetCurrentATR();
      TryCreateNewBlocks();
      CheckBlocksForBreakage();
      CleanupStaleBlocks();
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

      for(int i = 0; i < resistCount && m_blockCount < MAX_BLOCKS; i++)
        {
         for(int j = i + 1; j < resistCount && m_blockCount < MAX_BLOCKS; j++)
           {
            SFractalPeak w1 = resistPeaks[i];
            SFractalPeak w2 = resistPeaks[j];
            if(!TryFormBlock(w1, w2, BLOCK_RESISTANCE))
               continue;
           }
        }
      for(int i = 0; i < supportCount && m_blockCount < MAX_BLOCKS; i++)
        {
         for(int j = i + 1; j < supportCount && m_blockCount < MAX_BLOCKS; j++)
           {
            SFractalPeak w1 = supportPeaks[i];
            SFractalPeak w2 = supportPeaks[j];
            if(!TryFormBlock(w1, w2, BLOCK_SUPPORT))
               continue;
           }
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
      newBlock.isValid      = false;
      newBlock.isBroken     = false;
      newBlock.limitOrderTicket = 0;
      newBlock.creationTime = TimeCurrent();
      newBlock.atrAtCreation = m_currentATR;

      CalculateBlockDimensions(newBlock);
      newBlock.isValid = ValidateBlockByATR(newBlock);

      if(newBlock.isValid)
        {
         double slBuffer = ATRBufferSL * m_currentATR;
         newBlock.initialSLDistance = newBlock.blockHeight + slBuffer;
         if(newBlock.type == BLOCK_RESISTANCE)
            newBlock.initialSL = newBlock.top + slBuffer;
         else
            newBlock.initialSL = newBlock.bottom - slBuffer;

         // MODULE 2: Cluster filter — veto if within 1.0×ATR of existing block
         if(IsWithinClusterDistance(newBlock.midpoint))
           {
            if(EnableLogging)
               Print("[SniperBlock] Cluster VETO: Mid ",
                     DoubleToString(newBlock.midpoint, Digits()),
                     " within 1.0×ATR of existing block — discarded");
            m_blocksVetoed++;
            return false;
           }

         ArrayResize(m_blocks, m_blockCount + 1, MAX_BLOCKS);
         m_blocks[m_blockCount] = newBlock;
         m_blockCount++;
         m_blocksCreated++;
         if(EnableLogging)
            Print("[SniperBlock] Block CREATED (",
                  (type == BLOCK_RESISTANCE ? "RESISTANCE" : "SUPPORT"),
                  ") | Mid=", DoubleToString(newBlock.midpoint, Digits()),
                  " | Height=", DoubleToString(newBlock.blockHeight, Digits()));
        }
      return newBlock.isValid;
     }

   //+------------------------------------------------------------------+
   //| Checks all active blocks for breakage                             |
   //+------------------------------------------------------------------+
   void              CheckBlocksForBreakage(void)
     {
      for(int i = m_blockCount - 1; i >= 0; i--)
        {
         if(!m_blocks[i].isBroken && IsBlockBroken(m_blocks[i]))
           {
            m_blocks[i].isBroken = true;
            m_blocksBroken++;
           }
        }
     }

   //+------------------------------------------------------------------+
   //| Removes stale blocks                                              |
   //+------------------------------------------------------------------+
   void              CleanupStaleBlocks(void)
     {
      for(int i = m_blockCount - 1; i >= 0; i--)
        {
         bool shouldRemove = false;
         if(m_blocks[i].isBroken)
            shouldRemove = true;
         else
           {
            int barsSinceAnchor = m_blocks[i].wick1.barIndex;
            if(barsSinceAnchor > MaxBlockDistance * 3)
               shouldRemove = true;
           }
         if(shouldRemove)
            RemoveBlock(i);
        }
     }

   //+------------------------------------------------------------------+
   //| Gets all valid (unbroken) blocks                                   |
   //+------------------------------------------------------------------+
   int               GetValidBlocks(SSniperBlock &outBlocks[]) const
     {
      int count = 0;
      for(int i = 0; i < m_blockCount; i++)
        {
         if(m_blocks[i].isValid && !m_blocks[i].isBroken)
            count++;
        }
      ArrayResize(outBlocks, count);
      int idx = 0;
      for(int i = 0; i < m_blockCount; i++)
        {
         if(m_blocks[i].isValid && !m_blocks[i].isBroken)
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
   //| MODULE 4: DeleteBlockType — Removes all blocks of a given type    |
   //| Used by Hive Mind tie-breaker to delete conflicting blocks        |
   //+------------------------------------------------------------------+
   void              DeleteBlockType(ENUM_BLOCK_TYPE type)
     {
      for(int i = m_blockCount - 1; i >= 0; i--)
        {
         if(m_blocks[i].type == type && !m_blocks[i].isBroken)
           {
            // Cancel any pending order if ticket exists
            if(m_blocks[i].limitOrderTicket > 0)
               m_blocks[i].limitOrderTicket = 0; // OrderManager handles actual deletion
            RemoveBlock(i);
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
   int               GetBlockCount(void) const { return m_blockCount; }
  };

#endif  // __SNIPER_BLOCK__