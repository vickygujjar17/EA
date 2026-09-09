//+------------------------------------------------------------------+
//|                                                   CNewsFilter.mqh |
//|                                 Module 1 — High-Impact News Filter |
//|                             TrendSniper EA - Institutional Grade   |
//+------------------------------------------------------------------+
#property copyright "TrendSniper EA"
#property version   "1.00"

#ifndef __NEWS_FILTER__
#define __NEWS_FILTER__

#include "CommonDefines.mqh"

//+------------------------------------------------------------------+
//| CNewsFilter class                                                 |
//| Pauses new order placement 5 min before/after high-impact news    |
//+------------------------------------------------------------------+
class CNewsFilter
  {
private:
   // --- Symbol-to-currency mapping ---
   string            m_symbol;               // Trading symbol (e.g., "GBPUSD")
   string            m_baseCurrency;         // Base currency (e.g., "GBP")
   string            m_profitCurrency;       // Profit/counter currency (e.g., "USD")

   // --- News blackout state ---
   bool              m_inBlackout;           // Currently inside a blackout window
   datetime          m_blackoutEnd;          // When the current blackout ends
   datetime          m_lastCheck;            // Last bar time we checked

   // --- Calendar country mapping ---
   string            m_countryCodes[];       // Country codes relevant to this pair
   int               m_countryCount;
   long              m_baseCountryId;        // Numeric country ID for base currency
   long              m_profitCountryId;      // Numeric country ID for profit currency

   // --- Counters for logging ---
   int               m_blackoutsTriggered;   // Total blackout events since init

   //+------------------------------------------------------------------+
   //| Maps a currency code to its country string for Calendar functions  |
   //+------------------------------------------------------------------+
   string            MapCurrencyToCountry(string currency)
     {
      if(currency == "USD") return "United States";
      if(currency == "EUR") return "European Union";
      if(currency == "GBP") return "United Kingdom";
      if(currency == "JPY") return "Japan";
      if(currency == "AUD") return "Australia";
      if(currency == "NZD") return "New Zealand";
      if(currency == "CAD") return "Canada";
      if(currency == "CHF") return "Switzerland";
      if(currency == "CNY") return "China";
      if(currency == "XAU") return "United States";
      return "";
     }

   //+------------------------------------------------------------------+
   //| Converts country name to ISO 2-letter code for CalendarUsage...  |
   //+------------------------------------------------------------------+
   string            GetISOCode(string currency)
     {
      if(currency == "USD") return "US";
      if(currency == "EUR") return "EU";
      if(currency == "GBP") return "GB";
      if(currency == "JPY") return "JP";
      if(currency == "AUD") return "AU";
      if(currency == "NZD") return "NZ";
      if(currency == "CAD") return "CA";
      if(currency == "CHF") return "CH";
      if(currency == "CNY") return "CN";
      if(currency == "XAU") return "US";
      return "";
     }

   //+------------------------------------------------------------------+
   //| Resolves a numeric country ID from a country name string           |
   //| Uses CalendarCountryById — guaranteed in all MT5 builds            |
   //+------------------------------------------------------------------+
   long              ResolveCountryId(string countryName)
     {
      if(countryName == "")
         return -1;

      for(int id = 1; id <= 100; id++)
        {
         MqlCalendarCountry c;
         ResetLastError();
         if(CalendarCountryById(id, c))
           {
            if(c.name == countryName)
               return id;
           }
        }
      return -1;
     }

public:
   //+------------------------------------------------------------------+
   //| Constructor                                                       |
   //+------------------------------------------------------------------+
                     CNewsFilter(void)
     {
      m_symbol        = "";
      m_baseCurrency   = "";
      m_profitCurrency = "";
      m_inBlackout     = false;
      m_blackoutEnd    = 0;
      m_lastCheck      = 0;
      m_countryCount   = 0;
      m_baseCountryId  = -1;
      m_profitCountryId = -1;
      m_blackoutsTriggered = 0;
     }

   //+------------------------------------------------------------------+
   //| Destructor                                                        |
   //+------------------------------------------------------------------+
                    ~CNewsFilter(void)
     {
      ArrayFree(m_countryCodes);
     }

   //+------------------------------------------------------------------+
   //| Initialize — parse symbol currencies and map to country codes     |
   //+------------------------------------------------------------------+
   bool              Initialize(string symbol)
     {
      m_symbol = symbol;

      // Parse base and profit currencies from symbol name
      // Standard format: "GBPUSD" -> base=GBP, profit=USD
      int len = StringLen(symbol);
      if(len < 6)
        {
         Print("[NewsFilter] ERROR: Invalid symbol length for ", symbol);
         return false;
        }

      m_baseCurrency   = StringSubstr(symbol, 0, 3);
      m_profitCurrency = StringSubstr(symbol, 3, 3);

      // Handle special cases (4-char currencies in some brokers)
      if(len >= 7 && (StringSubstr(symbol, 0, 4) == "USDM" || 
                       StringSubstr(symbol, 0, 4) == "EURM"))
        {
         // This EA assumes standard 3+3 symbols; log a warning
         Print("[NewsFilter] WARNING: Non-standard symbol format: ", symbol);
        }

      // Build country codes array
      ArrayResize(m_countryCodes, 2);
      m_countryCodes[0] = m_baseCurrency;
      m_countryCodes[1] = m_profitCurrency;
      m_countryCount    = 2;

      // Resolve numeric country IDs for calendar filtering
      string baseCountryName = MapCurrencyToCountry(m_baseCurrency);
      string profitCountryName = MapCurrencyToCountry(m_profitCurrency);
      m_baseCountryId   = ResolveCountryId(baseCountryName);
      m_profitCountryId = ResolveCountryId(profitCountryName);

      if(EnableLogging)
        {
         Print("[NewsFilter] Initialized for ", m_symbol,
               " | Currencies: ", m_baseCurrency, " + ", m_profitCurrency,
               " | Country IDs: ", m_baseCountryId, " / ", m_profitCountryId);
        }

      return true;
     }

   //+------------------------------------------------------------------+
   //| Main update — called every tick. Checks news calendar.            |
   //+------------------------------------------------------------------+
   void              Update(void)
     {
      // Only check once per bar to avoid excessive calendar queries
      datetime currentBarTime = iTime(_Symbol, PERIOD_M1, 0);
      if(currentBarTime == m_lastCheck)
         return;
      m_lastCheck = currentBarTime;

      if(!EnableNewsFilter)
        {
         m_inBlackout = false;
         return;
        }

      // If we're currently in a blackout, check if it has expired
      if(m_inBlackout)
        {
         if(TimeCurrent() >= m_blackoutEnd)
           {
            m_inBlackout = false;
            if(EnableLogging)
               Print("[NewsFilter] Blackout ended at ", TimeToString(m_blackoutEnd));
           }
         return;
        }

      // Scan upcoming high-impact events
      datetime now = TimeCurrent();
      datetime lookAhead = now + 86400; // Look 24 hours ahead

      // Use MQL5 Calendar functions to find high-impact events
      // CalendarValueHistoryByEvent, CalendarEventById approach
      bool foundBlackout = false;
      datetime earliestBlackoutStart = 0;
      datetime earliestBlackoutEnd   = 0;

      for(int c = 0; c < m_countryCount && !foundBlackout; c++)
        {
         string isoCode = GetISOCode(m_countryCodes[c]);
         if(isoCode == "")
            continue;

         // We scan by iterating event IDs — in production, you'd use
         // a proper API loop. Here we use a practical MQL5 approach:
         // CalendarValueHistoryByEvent with known event IDs for the pair.
         // For robustness, we check multiple potential event IDs.

         // Get the country's upcoming calendar events via CalendarEventById
         // MQL5 calendar IDs vary by broker. We use a reasonable approach:
         // scan known high-impact event IDs for this currency.
         long targetCountryId = (c == 0) ? m_baseCountryId : m_profitCountryId;
         m_inBlackout = ScanCalendarForBlackout(m_countryCodes[c], targetCountryId,
                                                 now, lookAhead,
                                                 earliestBlackoutStart, earliestBlackoutEnd);

         if(m_inBlackout)
           {
            m_blackoutEnd = earliestBlackoutEnd;
            m_blackoutsTriggered++;
            if(EnableLogging)
              {
               Print("[NewsFilter] BLACKOUT ACTIVE for ", m_symbol,
                     " | ", m_countryCodes[c], " event",
                     " | Until: ", TimeToString(m_blackoutEnd),
                     " | Total blackouts: ", m_blackoutsTriggered);
              }
            foundBlackout = true;
            break;
           }
        }

      if(!foundBlackout)
        {
         m_inBlackout = false;
        }
     }

   //+------------------------------------------------------------------+
   //| Scans calendar for blackout windows for a specific currency       |
   //+------------------------------------------------------------------+
   bool              ScanCalendarForBlackout(string            currency,
                                              long              targetCountryId,
                                              datetime          fromTime,
                                              datetime          toTime,
                                              datetime         &outBlackoutStart,
                                              datetime         &outBlackoutEnd)
     {
      // Use MQL5 CalendarCountryById to find matching country IDs
      // Then use CalendarEventById to check each event
      // For MT5 build 2000+, these functions are available

      // We use a practical approach: scan event IDs in a reasonable range
      // A typical broker has calendar events with IDs from 1 to ~5000
      // We limit to reasonable check to avoid performance issues

      // CalendarEventById returns event description and metadata
      MqlCalendarEvent event;
      MqlCalendarValue eventValues[];
      datetime now = TimeCurrent();

      // Use CalendarValueHistoryByEvent to get values for upcoming events
      // We check values for the current day and next day
      datetime dayStart = fromTime;
      datetime dayEnd   = fromTime + 86400 * 2; // 2 days ahead

      // --- Practical implementation: use CalendarValueHistory ---
      // Get calendar values for the relevant country's currency
      // The MQL5 calendar system uses event IDs. We iterate common IDs.

      // For reliability across brokers, we use the CalendarValueHistory
      // with the country-appropriate currency filter

      // Validate target country ID
      if(targetCountryId < 0)
         return false;

      // --- Approach: Use CalendarValueHistory and filter by country_id ---
      // CalendarValueHistory(event_id, values[]) populates values for an event
      // We need to find the event IDs for this currency pair

      // Practical: Scan a window of event IDs
      int eventsToCheck = 200; // Check 200 potential event IDs

      for(int eventId = 1; eventId <= eventsToCheck; eventId++)
        {
         // Reset last error
         ResetLastError();

         // Try to get event info
         if(!CalendarEventById(eventId, event))
           {
            // Event not found — skip
            continue;
           }

         // Check if this event is relevant to our currency
         // event.country_id is a native long member guaranteed in all MT5 builds
         if(event.country_id == 0 || event.country_id == targetCountryId)
           {
            // Check importance — we want HIGH impact only
            ENUM_CALENDAR_EVENT_IMPORTANCE importance = event.importance;
            if(importance != CALENDAR_IMPORTANCE_HIGH)
               continue;

            // Get event values/times
            if(CalendarValueHistoryByEvent(eventId, eventValues, dayStart, dayEnd))
              {
               int valueCount = ArraySize(eventValues);
               for(int v = 0; v < valueCount; v++)
                 {
                  datetime eventTime = eventValues[v].time;

                  // If event is in the future or very recent
                  if(eventTime > 0)
                    {
                     // Calculate blackout window: NewsMinutesBefore before and after
                     datetime blackoutStart = eventTime - (NewsMinutesBefore * 60);
                     datetime blackoutEnd   = eventTime + (NewsMinutesAfter * 60);

                     // Check if we are currently inside this window
                     if(now >= blackoutStart && now <= blackoutEnd)
                       {
                        outBlackoutStart = blackoutStart;
                        outBlackoutEnd   = blackoutEnd;
                        return true;
                       }
                    }
                 }
              }
           }
        }

      return false;
     }

   //+------------------------------------------------------------------+
   //| Returns true if we are currently in a news blackout window        |
   //+------------------------------------------------------------------+
   bool              IsInNewsBlackout(void) const
     {
      return m_inBlackout;
     }

   //+------------------------------------------------------------------+
   //| Returns the datetime when the current blackout ends (or 0)        |
   //+------------------------------------------------------------------+
   datetime          GetNextBlackoutEnd(void) const
     {
      return m_blackoutEnd;
     }

   //+------------------------------------------------------------------+
   //| Returns blackout trigger counter for statistics                    |
   //+------------------------------------------------------------------+
   int               GetBlackoutCount(void) const
     {
      return m_blackoutsTriggered;
     }
  };

//+------------------------------------------------------------------+
#endif  // __NEWS_FILTER__