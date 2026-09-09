//+------------------------------------------------------------------+
//|                                                CommonDefines.mqh |
//|                              Otto EA - Central Definitions |
//|                                             Institutional Grade EA |
//+------------------------------------------------------------------+
#property copyright "Otto EA"
#property version   "1.00"
#property description "Institutional Trend-Following EA with Sniper Blocks"

#ifndef __COMMON_DEFINES__
#define __COMMON_DEFINES__

//+------------------------------------------------------------------+
//| Enumerations                                                      |
//+------------------------------------------------------------------+
enum ENUM_BLOCK_TYPE
  {
   BLOCK_RESISTANCE,    // Resistance block (for Short trades)
   BLOCK_SUPPORT        // Support block (for Long trades)
  };

enum ENUM_TRAIL_STEP
  {
   STEP_NONE = 0,       // Initial SL — no trail yet
   STEP_HALF_RISK = 1,  // 1.5R reached — SL moved to -0.5R
   STEP_BREAKEVEN = 2,  // 2.0R reached — SL at entry + spread
   STEP_TRAILING = 3    // 2.7R reached — dynamic ATR trail active
  };

enum ENUM_TRADE_DIRECTION
  {
   DIR_NONE = 0,
   DIR_LONG = 1,
   DIR_SHORT = -1
  };

enum ENUM_BLOCK_STATUS // New block status enumeration
  {
   BLOCK_STATUS_NEW,
   BLOCK_STATUS_ARMED,
   BLOCK_STATUS_BROKEN,
   BLOCK_STATUS_FLIPPED,
   BLOCK_STATUS_VETOED_SEPARATION,
   BLOCK_STATUS_VETOED_SIZING,
   BLOCK_STATUS_VETOED_FRONT_RUN,
   BLOCK_STATUS_VETOED_NEAR_MISS,
   BLOCK_STATUS_VETOED_STALE,
   BLOCK_STATUS_VETOED_MOMENTUM,
   BLOCK_STATUS_VETOED_FVG,
   BLOCK_STATUS_ORDER_PLACED,
   BLOCK_STATUS_TRADE_EXECUTED,
   BLOCK_STATUS_DELETED // For memory management / awaiting cleanup
  };

//+------------------------------------------------------------------+
//| Structures                                                        |
//+------------------------------------------------------------------+
struct SFractalPeak
  {
   datetime    time;                // Server time of the peak candle
   double      price;               // High (for resistance) or Low (for support) price
   int         barIndex;            // Bar index (shift from current, 0 = current)
   bool        isActive;            // Still valid as a dominant anchor
   bool        wasTriggered;        // Has this peak been used in a trade
   int         barsSinceFormation;  // Bars elapsed since this peak formed
   double      openPrice;           // Open of the peak candle
   double      closePrice;          // Close of the peak candle
   double      highPrice;           // Full high of the peak candle
   double      lowPrice;            // Full low of the peak candle
  };

struct SSniperBlock
  {
   ENUM_BLOCK_TYPE   type;               // Resistance or Support
   double            top;                // Upper boundary
   double            bottom;             // Lower boundary
   double            midpoint;           // (top + bottom) / 2 — limit order entry
   double            blockHeight;        // top - bottom (absolute)
   SFractalPeak      wick1;              // Wick 1 (older pivot from the 8/3 stream)
   SFractalPeak      wick2;              // Wick 2 (newer pivot from the 8/3 stream)
   bool              isValid;            // Passed ATR sizing veto (legacy flag, will be phased out)
   bool              isBroken;           // Broken by close outside buffer (legacy flag, will be phased out)
   ENUM_BLOCK_STATUS status;             // Current status of the block
   
   // New Pine Script v4.70 fields
   bool              isArmed;            // Has price armed the block?
   bool              isTriggered;        // Has the limit order been filled?
   bool              isFlipped;          // Has the block flipped from S to R or R to S?
   bool              isVetoed;           // Pine v4.70 generic veto latch (any veto fired)
   long              deleteOnBar;        // Bar index when this block should be deleted
   string            tradeId;            // Unique trade ID for order management
   bool              hasPlacedOrder;     // Has a limit order been placed for this block?
   bool              ghostArmed;         // OrderManager: has a resting limit order been armed for this block?
   double            localSl;            // Calculated SL for this block's order
   double            localTp;            // Calculated TP for this block's order
   double            localEntry;         // Calculated Entry for this block's order
   double            rrUnit;             // 1R distance for this block
   
   // Near Miss Veto Trackers
   bool              hasExited;          // Has price exited the block zone after formation?
   double            minProxDist;        // Minimum proximity distance to entry zone
   long              anchorBar;          // Bar index of the nearest approach (for Near Miss)
   int               anchorDay;          // Market day of the nearest approach (for Near Miss)
   double            anchorPrice;        // Price of the nearest approach (for Near Miss)
   long              anchorId;           // Unique ID for proximity anchor visualization
   
   // Stale Veto Tracker
   int               w1Day;              // Market day when Wick 1 formed

   ulong             limitOrderTicket;   // Ticket of the resting limit order
   datetime          creationTime;       // When this block was created
   double            atrAtCreation;      // ATR value when block was formed
   double            initialSL;          // Calculated Stop Loss price
   double            initialSLDistance;  // Distance in price from entry to SL
  };

struct SActiveTrade
  {
   ulong             ticket;
   ENUM_TRADE_DIRECTION direction;
   double            entryPrice;
   double            initialSL;
   double            initialSLDistance;
   double            initialRiskAmount;
   double            currentTrailSL;
   double            highestPriceSinceEntry;  // High watermark for trailing
   ENUM_TRAIL_STEP   trailStep;
   SSniperBlock      sourceBlock;
   datetime          openTime;
   double            lotSize;
  };

//+------------------------------------------------------------------+
//| Extern Input Parameters                                           |
//+------------------------------------------------------------------+
input group "══════════════════════════════════════════════════"
input group "  [1] GENERAL SETTINGS"
input group "══════════════════════════════════════════════════"
input int      MagicNumber       = 20240624;   // Unique EA Magic Number
input string   TradeComment      = "TS";       // Trade comment prefix
input bool     EnableLogging     = true;       // Write detailed log to file
input bool     EnableVisuals     = true;       // Draw blocks on chart

input group "══════════════════════════════════════════════════"
input group "  [2] MARKET STRUCTURE — Fractal Settings"
input group "══════════════════════════════════════════════════"
input int      LeftBars          = 8;          // Left bars for single pivot (Wick 1 & Wick 2)
input int      RightBars         = 3;          // Right bars for single pivot (Wick 1 & Wick 2)
input int      MaxPeakAge        = 30;         // Bars before a dominant peak is considered stale
input int      MaxBlockDistance  = 150;        // Max bars between W1 and W2 for a block
input int      MinBlockDistance  = 3;          // Min bars between W1 and W2 for a block
input int      LookbackBars      = 300;        // Number of bars to scan for fractals
input int      StaleVetoDays     = 45;         // Stale Veto (45 Days) — cancels block if no entry this many market days after Wick 1

input group "══════════════════════════════════════════════════"
input group "  [3] BLOCK VALIDATION — ATR Settings"
input group "══════════════════════════════════════════════════"
input int      ATRPeriod         = 14;         // ATR calculation period
input double   ATRVetoMin        = 0.1;         // Block height must be >= this * ATR
input double   ATRVetoMax        = 1.5;         // Block height must be <= this * ATR
input double   ATRBufferSL       = 0.5;         // SL buffer beyond block edge (in ATR multiples)
input double   ATRBufferBreak    = 0.5;         // Break confirmation buffer (in ATR multiples)
input double   ATRTrailDistance  = 1.5;         // Trailing stop distance in ATR multiples

input group "══════════════════════════════════════════════════"
input group "  [4] RISK MANAGEMENT"
input group "══════════════════════════════════════════════════"
input double   RiskPercent       = 0.25;        // Risk per trade (% of account, 0.25 = 0.25%)
input int      MaxSlippage       = 30;          // Maximum slippage in points
input int      MaxRetries        = 3;           // Max OrderSend retry attempts
input int      RetryDelayMs      = 500;         // Delay between retries (milliseconds)
input int      MaxSpreadPoints   = 50;          // Max spread (points) allowed for new entries

input group "══════════════════════════════════════════════════"
input group "  [5] NEWS FILTER"
input group "══════════════════════════════════════════════════"
input bool     EnableNewsFilter  = true;        // Enable high-impact news pause
input int      NewsMinutesBefore = 5;           // Minutes before event to pause new orders
input int      NewsMinutesAfter  = 5;           // Minutes after event to resume new orders

input group "══════════════════════════════════════════════════"
input group "  [6] TRAILING — Step-Up Runner"
input group "══════════════════════════════════════════════════"
input double   RR_Step1          = 1.5;         // R:R to move SL to half-risk
input double   RR_Step2          = 2.0;         // R:R to move SL to breakeven
input double   RR_Step3          = 2.7;         // R:R to activate dynamic ATR trail

input group "══════════════════════════════════════════════════"
input group "  [7] PROP FIRM SAFETY BUFFERS"
input group "══════════════════════════════════════════════════"
input double   SafetyMaxRiskPct  = 1.5;         // Hard clamp: abort if risk > this % of account
input double   SafetyDailyDDLimit= 2.5;         // Soft breach: pause new orders at this % DD from midnight
input double   SafetyTotalDDLimit= 3.5;         // Hard breach: close all + halt at this % DD from start

input group "══════════════════════════════════════════════════"
input group "  [8] GHOST BLOCKS — Dynamic Order Placement"
input group "══════════════════════════════════════════════════"
input double   GhostArmDistance  = 2.0;         // Arm limit order when price within this × ATR of midpoint
input double   GhostDisarmDistance = 3.0;       // Disarm (cancel) when price beyond this × ATR from midpoint

//+------------------------------------------------------------------+
//| Global Constants                                                  |
//+------------------------------------------------------------------+
#define MAX_BLOCKS        50        // Max concurrent S/R blocks
#define MAX_PEAKS_RESIST  50        // Max stored resistance peaks
#define MAX_PEAKS_SUPPORT 50        // Max stored support peaks

//+------------------------------------------------------------------+
#endif  // __COMMON_DEFINES__