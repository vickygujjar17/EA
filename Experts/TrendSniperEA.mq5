//+------------------------------------------------------------------+
//|                                                  TrendSniperEA.mq5|
//|                           Institutional Trend-Following Sniper EA |
//|                                                Real-Money Grade   |
//+------------------------------------------------------------------+
#property copyright "TrendSniper EA"
#property version   "1.00"
#property description "Institutional Trend-Following EA | Hedging Account"
#property description "Modules: News Filter | Dynamic Risk | Market Structure"
#property description "Sniper Blocks | Order Execution | Trend Runner"
#property description "Ghost Blocks | Prop Firm Safety Buffers"
#property link      "https://github.com/trendsniper"

//+------------------------------------------------------------------+
//| Includes                                                          |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
#include "../Include/TrendSniper/CommonDefines.mqh"
#include "../Include/TrendSniper/CNewsFilter.mqh"
#include "../Include/TrendSniper/CRiskManager.mqh"
#include "../Include/TrendSniper/CMarketStructure.mqh"
#include "../Include/TrendSniper/CSniperBlock.mqh"
#include "../Include/TrendSniper/COrderManager.mqh"
#include "../Include/TrendSniper/CCorrelationFilter.mqh"
#include "../Include/TrendSniper/CTradeManager.mqh"

//+------------------------------------------------------------------+
//| Global Module Instances                                            |
//+------------------------------------------------------------------+
CNewsFilter        g_newsFilter;
CRiskManager       g_riskManager;
CMarketStructure   g_marketStructure;
CSniperBlock       g_sniperBlock;
COrderManager      g_orderManager;
CCorrelationFilter g_correlationFilter;
CTradeManager      g_tradeManager;

//+------------------------------------------------------------------+
//| Global State                                                       |
//+------------------------------------------------------------------+
string   g_symbol;
bool     g_isHedging        = false;
bool     g_initialized      = false;
int      g_tickCount        = 0;
datetime g_lastStatusLog    = 0;
int      g_fileHandle       = INVALID_HANDLE;
string   g_logFileName      = "";

// --- Prop Firm Safety State ---
double   g_initialBalance      = 0;         // Starting balance at EA init
double   g_midnightBalance     = 0;         // Balance at today's 00:00 server time
datetime g_lastMidnightCheck   = 0;         // Last time we reset midnight balance
bool     g_dailyDD_Paused      = false;     // Daily drawdown pause active
bool     g_totalDD_Halted      = false;     // Total drawdown — permanent halt
datetime g_dailyDD_ResumeTime  = 0;         // Next day 00:00 server time to resume
double   g_dailyEquityHigh     = 0;         // Daily equity high watermark

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   g_symbol = _Symbol;

   Print("╔══════════════════════════════════════════════════════════╗");
   Print("║           TrendSniper EA v1.00 — INITIALIZING            ║");
   Print("╠══════════════════════════════════════════════════════════╣");
   Print("║ Symbol: ", g_symbol, "                                    ║");
   Print("║ Magic:  ", MagicNumber, "                                          ║");
   Print("╚══════════════════════════════════════════════════════════╝");

   // --- Validate Hedging Account ---
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("╔══════════════════════════════════════════════════════════╗");
      Print("║  FATAL ERROR: EA requires HEDGING account mode!          ║");
      Print("║  Current mode: ", EnumToString(marginMode));
      Print("║  Please switch to a hedging account.                    ║");
      Print("╚══════════════════════════════════════════════════════════╝");
      return INIT_FAILED;
     }
   g_isHedging = true;
   Print("[INIT] Account type: HEDGING ✓");

   // --- Log account info ---
   Print("[INIT] Account: ", AccountInfoInteger(ACCOUNT_LOGIN),
         " | Server: ", AccountInfoString(ACCOUNT_SERVER),
         " | Currency: ", AccountInfoString(ACCOUNT_CURRENCY),
         " | Leverage: 1:", AccountInfoInteger(ACCOUNT_LEVERAGE));
   Print("[INIT] Balance: ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
         " | Equity: ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
         " | Free Margin: ", DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));

   // --- Initialize News Filter (Module 1) ---
   if(!g_newsFilter.Initialize(g_symbol))
     {
      Print("[INIT] WARNING: News Filter initialization failed — continuing without news filter");
     }
   else
     {
      Print("[INIT] News Filter ✓");
     }

   // --- Initialize Risk Manager (Module 2) ---
   if(!g_riskManager.Initialize(g_symbol))
     {
      Print("[INIT] FATAL: Risk Manager initialization failed");
      return INIT_FAILED;
     }
   Print("[INIT] Risk Manager ✓");

   // --- Initialize Market Structure (Module 3) ---
   if(!g_marketStructure.Initialize(g_symbol))
     {
      Print("[INIT] FATAL: Market Structure initialization failed");
      return INIT_FAILED;
     }
   Print("[INIT] Market Structure ✓");

   // --- Initialize Sniper Block (Module 4) ---
   if(!g_sniperBlock.Initialize(g_symbol, &g_marketStructure))
     {
      Print("[INIT] FATAL: Sniper Block initialization failed");
      return INIT_FAILED;
     }
   Print("[INIT] Sniper Block ✓");

   // --- Initialize Correlation Filter (Module 9) ---
   if(!g_correlationFilter.Initialize(g_symbol))
     {
      Print("[INIT] WARNING: Correlation Filter initialization failed — continuing without filter");
     }
   else
     {
      Print("[INIT] Correlation Filter ✓");
     }

   // --- Initialize Order Manager (Module 5) ---
   if(!g_orderManager.Initialize(g_symbol, &g_riskManager, &g_sniperBlock, &g_correlationFilter))
     {
      Print("[INIT] FATAL: Order Manager initialization failed");
      return INIT_FAILED;
     }
   Print("[INIT] Order Manager ✓");

   // --- Initialize Trade Manager (Module 6) ---
   if(!g_tradeManager.Initialize(g_symbol, &g_riskManager, &g_orderManager, &g_sniperBlock))
     {
      Print("[INIT] FATAL: Trade Manager initialization failed");
      return INIT_FAILED;
     }
   Print("[INIT] Trade Manager ✓");

   // --- Initialize prop firm safety state ---
   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_midnightBalance = g_initialBalance;
   g_dailyEquityHigh = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dailyDD_Paused = false;
   g_totalDD_Halted = false;
   MqlDateTime dt;
   TimeCurrent(dt);
   g_lastMidnightCheck = StructToTime(dt); // Today's midnight

   Print("[Safety] Init Balance: ", DoubleToString(g_initialBalance, 2),
         " | MaxDailyDD: ", SafetyDailyDDLimit, "%",
         " | MaxTotalDD: ", SafetyTotalDDLimit, "%");

   // --- Sync existing trade state ---
   g_tradeManager.SyncTradeState();

   // --- Setup log file ---
   if(EnableLogging)
     {
      g_logFileName = "TrendSniper_" + g_symbol + "_" +
                      IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".csv";
      g_fileHandle = FileOpen(g_logFileName, FILE_CSV | FILE_WRITE | FILE_SHARE_READ, ',');
      if(g_fileHandle != INVALID_HANDLE)
        {
         FileWrite(g_fileHandle,
                   "Time", "Symbol", "Event", "Details");
         Print("[INIT] Log file: ", g_logFileName, " ✓");
        }
      else
        {
         Print("[INIT] WARNING: Could not create log file");
        }
     }

   g_initialized = true;

   Print("╔══════════════════════════════════════════════════════════╗");
   Print("║       TrendSniper EA INITIALIZED SUCCESSFULLY            ║");
   Print("║       Risk per trade: ", RiskPercent, "% of account                   ║");
   Print("║       Max Slippage: ", MaxSlippage, " points                            ║");
   Print("║       News Filter: ", EnableNewsFilter ? "ENABLED" : "DISABLED", "                       ║");
   Print("║       Ghost Blocks: 2.0/3.0 ATR arm/disarm              ║");
   Print("║       Safety MaxRisk: ", SafetyMaxRiskPct, "%  DailyDD: ", SafetyDailyDDLimit, "%  TotalDD: ", SafetyTotalDDLimit, "%  ║");
   Print("╚══════════════════════════════════════════════════════════╝");

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("╔══════════════════════════════════════════════════════════╗");
   Print("║           TrendSniper EA — DEINITIALIZING                ║");
   Print("╠══════════════════════════════════════════════════════════╣");

   // --- Print statistics ---
   Print("║ --- News Filter ---");
   Print("║ Blackouts triggered: ", g_newsFilter.GetBlackoutCount());
   Print("║ --- Market Structure ---");
   Print("║ Total peaks detected: ", g_marketStructure.GetTotalPeaksDetected());
   Print("║ --- Sniper Blocks ---");
   Print("║ Blocks created: ", g_sniperBlock.GetBlocksCreated(),
         " | Broken: ", g_sniperBlock.GetBlocksBroken(),
         " | Vetoed: ", g_sniperBlock.GetBlocksVetoed());
   Print("║ --- Order Manager ---");
   Print("║ Orders placed: ", g_orderManager.GetOrdersPlaced(),
         " | Filled: ", g_orderManager.GetOrdersFilled(),
         " | Rejected: ", g_orderManager.GetOrdersRejected());
   Print("║ Reversals: ", g_orderManager.GetReversalsExecuted(),
         " | Retries: ", g_orderManager.GetRetryCount());
   Print("║ --- Trade Manager ---");
   Print("║ Half-Risk triggers: ", g_tradeManager.GetHalfRiskTriggers(),
         " | Breakeven: ", g_tradeManager.GetBreakevenTriggers());
   Print("║ Trail activations: ", g_tradeManager.GetTrailActivations(),
         " | Stops hit: ", g_tradeManager.GetStopsHit());
   Print("║ --- Prop Firm Safety ---");
   Print("║ DailyDD Paused: ", g_dailyDD_Paused ? "YES" : "NO",
         " | TotalDD Halted: ", g_totalDD_Halted ? "YES" : "NO");

   // --- Cancel all pending orders ---
   int pendingOrders = g_orderManager.CountMyPendingOrders();
   if(pendingOrders > 0)
     {
      Print("║ Cancelling ", pendingOrders, " pending orders...");
      for(int i = pendingOrders - 1; i >= 0; i--)
        {
         ulong ticket = g_orderManager.GetMyPendingOrderByIndex(i);
         if(ticket > 0)
            g_orderManager.DeleteOrder(ticket);
        }
     }

   Print("║ Reason: ", reason);
   Print("╚══════════════════════════════════════════════════════════╝");

   // --- Close log file ---
   if(g_fileHandle != INVALID_HANDLE)
     {
      FileClose(g_fileHandle);
      g_fileHandle = INVALID_HANDLE;
     }

   g_initialized = false;
  }

//+------------------------------------------------------------------+
//| Checks daily balance reset at midnight server time                 |
//+------------------------------------------------------------------+
void CheckDailyReset(void)
  {
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime todayMidnight = StructToTime(dt); // Year/Month/Day, 00:00

   if(todayMidnight != g_lastMidnightCheck)
     {
      g_midnightBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyEquityHigh = AccountInfoDouble(ACCOUNT_EQUITY);
      g_lastMidnightCheck = todayMidnight;

      if(g_dailyDD_Paused)
        {
         g_dailyDD_Paused = false;
         if(EnableLogging)
            Print("[Safety] New day at ", TimeToString(todayMidnight),
                  " — daily drawdown pause LIFTED. Midnight balance: ",
                  DoubleToString(g_midnightBalance, 2));
        }

      if(EnableLogging)
        {
         Print("[Safety] Daily reset: midnight balance = ",
               DoubleToString(g_midnightBalance, 2),
               " | equity high = ", DoubleToString(g_dailyEquityHigh, 2));
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function — Main Orchestration Loop                     |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   // Guard: ensure initialization was successful
   if(!g_initialized)
      return;

   g_tickCount++;

   // ================================================================
   // STEP 0: PROP FIRM SAFETY CHECKS (highest priority)
   // ================================================================

   // Hard halt: total drawdown exceeded — do nothing at all
   if(g_totalDD_Halted)
      return;

   // Check daily reset (midnight boundary)
   CheckDailyReset();

   // If we're in daily DD pause, skip all new order operations
   // but still manage active trades (trail stops must remain active)
   if(!g_dailyDD_Paused)
     {
      // Check daily drawdown
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double dailyDD = 0;
      if(g_midnightBalance > 0)
         dailyDD = 100.0 * (g_midnightBalance - equity) / g_midnightBalance;

      if(dailyDD >= SafetyDailyDDLimit)
        {
         g_dailyDD_Paused = true;
         g_dailyDD_ResumeTime = g_lastMidnightCheck + 86400; // Next midnight
         g_orderManager.CancelAllPendingOrders();
         if(EnableLogging)
            Print("[Safety] DAILY DRAWDOWN LIMIT: ", DoubleToString(dailyDD, 2), "% > ",
                  SafetyDailyDDLimit, "% — pausing new orders until ", TimeToString(g_dailyDD_ResumeTime));
        }

      // Check total drawdown
      double totalDD = 0;
      if(g_initialBalance > 0)
         totalDD = 100.0 * (g_initialBalance - equity) / g_initialBalance;

      if(totalDD >= SafetyTotalDDLimit)
        {
         g_totalDD_Halted = true;
         g_orderManager.CancelAllPendingOrders();
         // Force close all active positions
         if(g_orderManager.HasActiveTrade())
           {
            SActiveTrade trade = g_orderManager.GetActiveTrade();
            g_orderManager.ClosePosition(trade.ticket);
           }
         Print("╔══════════════════════════════════════════════════════════╗");
         Print("║  FATAL: TOTAL DRAWDOWN LIMIT REACHED!                    ║");
         Print("║  DD: ", DoubleToString(totalDD, 2), "% > ", SafetyTotalDDLimit, "%                     ║");
         Print("║  EA PERMANENTLY HALTED — MANUAL INTERVENTION REQUIRED     ║");
         Print("╚══════════════════════════════════════════════════════════╝");
         return;
        }
     }

   // ================================================================
   // STEP 1: Update News Filter (Module 1)
   // Checks for high-impact news blackout windows
   // ================================================================
   g_newsFilter.Update();

   // ================================================================
   // STEP 2: Update Market Structure (Module 3)
   // Scans for fractal pivot highs/lows with dominant peak retention
   // ================================================================
   g_marketStructure.Update();

   // ================================================================
   // STEP 3: Update Sniper Blocks (Module 4)
   // Pairs anchors with retests, validates by ATR, checks breakage
   // ================================================================
   g_sniperBlock.Update();

   // ================================================================
   // STEP 3.5: HIVE MIND — Broadcast bias & resolve bidirectional
   // conflicts via MT5 Global Variables
   // ================================================================
   if(!g_dailyDD_Paused)
     {
      // Determine our bias based on currently valid blocks
      SSniperBlock allBlocksHive[];
      int totalHive = g_sniperBlock.GetAllBlocks(allBlocksHive);
      bool hasSupport = false, hasResistance = false;
      for(int b = 0; b < totalHive; b++)
        {
         if(!allBlocksHive[b].isValid || allBlocksHive[b].isBroken) continue;
         if(allBlocksHive[b].type == BLOCK_SUPPORT) hasSupport = true;
         if(allBlocksHive[b].type == BLOCK_RESISTANCE) hasResistance = true;
        }

      int myBias = 0;
      if(hasSupport && !hasResistance)
         myBias = 1;          // Long bias
      else if(hasResistance && !hasSupport)
         myBias = -1;         // Short bias
      else if(hasSupport && hasResistance)
        {
         // Conflict — use Hive Mind tie-breaker
         int resolution = g_correlationFilter.ResolveBidirectionalConflict();
         if(resolution == 1)
           {
            g_sniperBlock.DeleteBlockType(BLOCK_RESISTANCE);
            myBias = 1;
            if(EnableLogging)
               Print("[HiveMind] ", g_symbol, " CONFLICT: peers lean Long → kept Support, deleted Resistance");
           }
         else if(resolution == -1)
           {
            g_sniperBlock.DeleteBlockType(BLOCK_SUPPORT);
            myBias = -1;
            if(EnableLogging)
               Print("[HiveMind] ", g_symbol, " CONFLICT: peers lean Short → kept Resistance, deleted Support");
           }
         else
           {
            g_sniperBlock.DeleteBlockType(BLOCK_RESISTANCE);
            g_sniperBlock.DeleteBlockType(BLOCK_SUPPORT);
            myBias = 0;
            if(EnableLogging)
               Print("[HiveMind] ", g_symbol, " CONFLICT: no consensus → deleted both blocks");
           }
        }
      // Broadcast our bias to all other EA instances via MT5 Global Variables
      g_correlationFilter.BroadcastBias(myBias);
     }

   // ================================================================
   // STEP 4: Ghost Block Management (Module 5 + Module 8)
   // Cancel orders on broken blocks, then arm/disarm ghost blocks
   // Only if NOT in news blackout AND NOT in daily DD pause
   // ================================================================
   if(!g_newsFilter.IsInNewsBlackout() && !g_dailyDD_Paused)
     {
      // Cancel orders on broken blocks first
      SSniperBlock allBlocks[];
      int total = g_sniperBlock.GetAllBlocks(allBlocks);
      g_orderManager.CancelOrdersForBrokenBlocks(allBlocks, total);

      // Ghost blocks: dynamically arm/disarm by proximity
      g_orderManager.ManageGhostBlocks();
     }
   else if(g_newsFilter.IsInNewsBlackout())
     {
      // In blackout — log periodically
      static datetime lastBlackoutLog = 0;
      if(TimeCurrent() - lastBlackoutLog >= 60)
        {
         if(EnableLogging)
            Print("[OnTick] News blackout active — new orders paused. Ends at: ",
                  TimeToString(g_newsFilter.GetNextBlackoutEnd()));
         lastBlackoutLog = TimeCurrent();
        }
     }

   // ================================================================
   // STEP 5: Manage Active Trades — Step-Up Trailing Stop (Module 6)
   // Trail stops on active positions — ALWAYS active (including DD pause)
   // ================================================================
   g_tradeManager.Update();

   // ================================================================
   // STEP 6: Check Pending Order Fills & Reversal Handling (Module 5)
   // ================================================================
   g_orderManager.Update();

   // ================================================================
   // STEP 7: Manage Direction Conflict (Module 5)
   // Cancel same-direction limit orders when a trade is active
   // ================================================================
   g_orderManager.ManageDirectionConflict();

   // ================================================================
   // STEP 8: Periodic Status Logging
   // ================================================================
   if(EnableLogging && TimeCurrent() - g_lastStatusLog >= 300)
     {
      LogStatus();
      g_lastStatusLog = TimeCurrent();
     }
  }

//+------------------------------------------------------------------+
//| Periodic status logging to console and file                        |
//+------------------------------------------------------------------+
void LogStatus(void)
  {
   string statusLine;
   StringConcatenate(statusLine,
                     "[STATUS] Ticks: ", g_tickCount,
                     " | News: ", g_newsFilter.IsInNewsBlackout() ? "BLACKOUT" : "CLEAR",
                     " | Blocks: ", g_sniperBlock.GetBlockCount(),
                     " | ActiveTrade: ", g_orderManager.HasActiveTrade() ? "YES" : "NO",
                     " | PendingOrders: ", g_orderManager.CountMyPendingOrders(),
                     " | ATR: ", DoubleToString(g_sniperBlock.GetATR(), Digits()),
                     " | Spread: ", DoubleToString((SymbolInfoDouble(g_symbol, SYMBOL_ASK) -
                                                    SymbolInfoDouble(g_symbol, SYMBOL_BID)) /
                                                   SymbolInfoDouble(g_symbol, SYMBOL_POINT), 1),
                     " | DailyDD: ", g_dailyDD_Paused ? "PAUSED" : "OK",
                     " | TotalDD: ", g_totalDD_Halted ? "HALTED" : "OK");

   Print(statusLine);

   // Write to CSV log file
   if(g_fileHandle != INVALID_HANDLE)
     {
      FileWrite(g_fileHandle,
                TimeToString(TimeCurrent()),
                g_symbol,
                "STATUS",
                statusLine);
      FileFlush(g_fileHandle);
     }
  }

//+------------------------------------------------------------------+
//| OnChartEvent — handle chart events (optional)                      |
//+------------------------------------------------------------------+
void OnChartEvent(const int          id,
                  const long        &lparam,
                  const double      &dparam,
                  const string      &sparam)
  {
   // Reserved for future chart interaction (e.g., button to force-close trades)
  }

//+------------------------------------------------------------------+
//| OnTrade — handle trade events (optional)                            |
//+------------------------------------------------------------------+
void OnTrade(void)
  {
   // When a trade event occurs, re-sync active trade state
   if(g_initialized)
     {
      g_orderManager.SyncActiveTrade();
     }
  }

//+------------------------------------------------------------------+
//| OnTimer — handle timer events (optional)                            |
//+------------------------------------------------------------------+
void OnTimer(void)
  {
   // Can be used for heartbeat monitoring
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+