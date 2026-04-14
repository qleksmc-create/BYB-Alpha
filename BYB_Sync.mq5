//+------------------------------------------------------------------+
//|  BYB Alpha — MT5 Sync EA v1.20                                   |
//|  Schickt Trade-History + Kontostand an BYB Alpha Dashboard        |
//|                                                                   |
//|  SETUP (einmalig):                                                |
//|  1. EA auf einen beliebigen Chart ziehen (z.B. EURUSD M1)         |
//|  2. Deinen persönlichen Sync-Token einfügen (aus dem Dashboard)   |
//|  3. Extras → Optionen → Expert Advisors →                         |
//|     "WebRequest erlauben" aktivieren, URL hinzufügen:             |
//|     https://dzlgudlurijmgjwetztf.supabase.co                      |
//|  4. OK — fertig. Läuft automatisch im Hintergrund.                |
//+------------------------------------------------------------------+
#property copyright "BYB Alpha"
#property version   "1.20"
#property strict

input string SyncToken   = "";    // << Deinen Token hier einfügen
input int    IntervalSec = 120;   // Sync-Interval in Sekunden (Standard: 2 Min)
input bool   ShowAlerts  = true;  // Benachrichtigungen anzeigen

const string API_URL = "https://dzlgudlurijmgjwetztf.supabase.co/functions/v1/sync-trades";

int OnInit()
{
   if(StringLen(SyncToken) < 10)
   {
      Alert("BYB Alpha: Bitte Sync-Token eingeben! (EA-Parameter öffnen)");
      return INIT_PARAMETERS_INCORRECT;
   }
   EventSetTimer(IntervalSec);
   SyncTrades();
   Print("BYB Alpha Sync EA v1.20 gestartet. Interval: ", IntervalSec, "s");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }
void OnTimer()                  { SyncTrades(); }

//+------------------------------------------------------------------+
void SyncTrades()
{
   // ── Kontostand & Equity ────────────────────────────────────────
   double acc_balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double acc_equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double acc_margin      = AccountInfoDouble(ACCOUNT_MARGIN);
   double acc_free_margin = AccountInfoDouble(ACCOUNT_FREEMARGIN);

   // ── Trade History laden ────────────────────────────────────────
   datetime from = D'2000.01.01';
   datetime to   = TimeCurrent();

   if(!HistorySelect(from, to))
   {
      Print("BYB: HistorySelect fehlgeschlagen");
      return;
   }

   int total = HistoryDealsTotal();

   string trades_json = "";
   int    count       = 0;

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      ENUM_DEAL_ENTRY entry_type = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      ENUM_DEAL_TYPE  deal_type  = (ENUM_DEAL_TYPE) HistoryDealGetInteger(ticket, DEAL_TYPE);

      // Nur abgeschlossene Handelspositionen
      if(entry_type != DEAL_ENTRY_OUT)       continue;
      if(deal_type  == DEAL_TYPE_BALANCE)    continue;
      if(deal_type  == DEAL_TYPE_CREDIT)     continue;
      if(deal_type  == DEAL_TYPE_CORRECTION) continue;

      string symbol     = HistoryDealGetString (ticket, DEAL_SYMBOL);
      double exit_price = HistoryDealGetDouble (ticket, DEAL_PRICE);    // Exit-Preis
      double volume     = HistoryDealGetDouble (ticket, DEAL_VOLUME);
      double profit     = HistoryDealGetDouble (ticket, DEAL_PROFIT);
      double commission = HistoryDealGetDouble (ticket, DEAL_COMMISSION);
      double swap_val   = HistoryDealGetDouble (ticket, DEAL_SWAP);
      long   close_ts   = HistoryDealGetInteger(ticket, DEAL_TIME);
      long   position_id= HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      string comment    = HistoryDealGetString (ticket, DEAL_COMMENT);

      // ── Eröffnungs-Deal suchen → Entry-Preis + echte Direction ──
      long   open_ts    = close_ts;  // Fallback
      long   hold_s     = 0;
      double entry_price = exit_price; // Fallback
      // Direction aus dem SCHLIESS-Deal ist invertiert (sell=Long, buy=Short)
      // Wir suchen den ÖFFNUNGS-Deal um die echte Direction zu bekommen
      string direction  = (deal_type == DEAL_TYPE_SELL) ? "sell" : "buy"; // Fallback (invertiert!)

      if(position_id > 0)
      {
         for(int j = 0; j < total; j++)
         {
            ulong t2 = HistoryDealGetTicket(j);
            if(t2 == 0) continue;
            if(HistoryDealGetInteger(t2, DEAL_POSITION_ID) != position_id) continue;
            if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(t2, DEAL_ENTRY) == DEAL_ENTRY_IN)
            {
               open_ts     = HistoryDealGetInteger(t2, DEAL_TIME);
               hold_s      = close_ts - open_ts;
               entry_price = HistoryDealGetDouble (t2, DEAL_PRICE);
               // BUY-Deal beim Öffnen = LONG-Position; SELL-Deal beim Öffnen = SHORT
               ENUM_DEAL_TYPE open_type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(t2, DEAL_TYPE);
               direction = (open_type == DEAL_TYPE_BUY) ? "buy" : "sell";
               break;
            }
         }
      }

      // Anführungszeichen im Kommentar escapen
      StringReplace(comment, "\"", "'");

      // Preisformat: Gold/BTC 2 Dezimalstellen, sonst 5
      bool is_crypto_or_metal = (StringFind(symbol, "XAU") >= 0 ||
                                  StringFind(symbol, "BTC") >= 0 ||
                                  StringFind(symbol, "ETH") >= 0 ||
                                  StringFind(symbol, "XAG") >= 0);

      string trade;
      if(is_crypto_or_metal)
         trade = StringFormat(
            "{\"ticket\":%I64u,\"position_id\":%I64d,\"symbol\":\"%s\","
            "\"direction\":\"%s\",\"entry\":%.2f,\"exit_price\":%.2f,"
            "\"volume\":%.2f,\"profit\":%.2f,\"commission\":%.2f,\"swap\":%.2f,"
            "\"open_time\":%I64d,\"close_time\":%I64d,\"hold_secs\":%I64d,"
            "\"comment\":\"%s\"}",
            ticket, position_id, symbol,
            direction, entry_price, exit_price,
            volume, profit, commission, swap_val,
            open_ts, close_ts, hold_s, comment);
      else
         trade = StringFormat(
            "{\"ticket\":%I64u,\"position_id\":%I64d,\"symbol\":\"%s\","
            "\"direction\":\"%s\",\"entry\":%.5f,\"exit_price\":%.5f,"
            "\"volume\":%.2f,\"profit\":%.2f,\"commission\":%.2f,\"swap\":%.2f,"
            "\"open_time\":%I64d,\"close_time\":%I64d,\"hold_secs\":%I64d,"
            "\"comment\":\"%s\"}",
            ticket, position_id, symbol,
            direction, entry_price, exit_price,
            volume, profit, commission, swap_val,
            open_ts, close_ts, hold_s, comment);

      if(count > 0) trades_json += ",";
      trades_json += trade;
      count++;

      if(count >= 500) break;  // Max 500 Trades pro Batch
   }

   // ── JSON-Payload: Kontostand + Trades ─────────────────────────
   string payload;
   if(count > 0)
      payload = StringFormat(
         "{\"token\":\"%s\","
         "\"balance\":%.2f,\"equity\":%.2f,\"margin\":%.2f,\"free_margin\":%.2f,"
         "\"trades\":[%s]}",
         SyncToken,
         acc_balance, acc_equity, acc_margin, acc_free_margin,
         trades_json);
   else
      payload = StringFormat(
         "{\"token\":\"%s\","
         "\"balance\":%.2f,\"equity\":%.2f,\"margin\":%.2f,\"free_margin\":%.2f,"
         "\"trades\":[]}",
         SyncToken,
         acc_balance, acc_equity, acc_margin, acc_free_margin);

   // ── HTTP POST ──────────────────────────────────────────────────
   char   post_data[];
   char   result_data[];
   string result_headers;
   string req_headers = "Content-Type: application/json\r\n";

   int payload_len = StringLen(payload);
   ArrayResize(post_data, payload_len);
   StringToCharArray(payload, post_data, 0, payload_len);

   int http_code = WebRequest(
      "POST", API_URL, req_headers, 5000,
      post_data, result_data, result_headers);

   string response = CharArrayToString(result_data);

   if(http_code == 200 || http_code == 201)
   {
      Print("BYB Sync OK — ", count, " Trades + Kontostand $",
            DoubleToString(acc_balance, 2), " gesendet.");
      if(ShowAlerts)
         Comment("BYB Alpha ✓  Kontostand: $", DoubleToString(acc_balance, 2),
                 "  |  Equity: $", DoubleToString(acc_equity, 2),
                 "  |  Letzter Sync: ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
   }
   else if(http_code == -1)
   {
      Print("BYB Sync Fehler: WebRequest nicht erlaubt.");
      Print("→ Extras → Optionen → Expert Advisors → WebRequest + URL hinzufügen:");
      Print("→ https://dzlgudlurijmgjwetztf.supabase.co");
      if(ShowAlerts)
         Alert("BYB Alpha: WebRequest nicht aktiviert! Siehe MT5-Log.");
   }
   else
   {
      Print("BYB Sync Fehler: HTTP ", http_code, " — ", response);
   }
}
