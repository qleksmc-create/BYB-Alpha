//+------------------------------------------------------------------+
//|  BYB Alpha — MT5 Sync EA                                        |
//|  Schickt deine Trade-History automatisch an BYB Alpha Dashboard  |
//|                                                                  |
//|  SETUP (einmalig):                                               |
//|  1. EA auf einen beliebigen Chart ziehen (z.B. EURUSD M1)        |
//|  2. Deinen persönlichen Sync-Token einfügen (aus dem Dashboard)  |
//|  3. In MT5: Extras → Optionen → Expert Advisors →               |
//|     "WebRequest erlauben" aktivieren und diese URL hinzufügen:   |
//|     https://dzlgudlurijmgjwetztf.supabase.co                     |
//|  4. OK — fertig. Läuft jetzt automatisch im Hintergrund.         |
//+------------------------------------------------------------------+
#property copyright "BYB Alpha"
#property version   "1.10"
#property strict

input string SyncToken    = "";   // << Deinen Token hier einfügen (aus BYB Dashboard)
input int    IntervalSec  = 120;  // Sync alle X Sekunden (Standard: 2 Minuten)
input bool   ShowAlerts   = true; // Benachrichtigungen anzeigen

// Edge Function URL
const string API_URL = "https://dzlgudlurijmgjwetztf.supabase.co/functions/v1/sync-trades";

//+------------------------------------------------------------------+
//| Initialisierung                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(SyncToken) < 10)
   {
      Alert("BYB Alpha: Bitte Sync-Token eingeben! (EA-Parameter öffnen)");
      return INIT_PARAMETERS_INCORRECT;
   }

   EventSetTimer(IntervalSec);

   // Sofort beim Start einmal syncen
   SyncTrades();

   Print("BYB Alpha Sync EA gestartet. Interval: ", IntervalSec, "s");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialisierung                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("BYB Alpha Sync EA gestoppt.");
}

//+------------------------------------------------------------------+
//| Timer — wird alle IntervalSec aufgerufen                         |
//+------------------------------------------------------------------+
void OnTimer()
{
   SyncTrades();
}

//+------------------------------------------------------------------+
//| Haupt-Sync-Funktion                                              |
//+------------------------------------------------------------------+
void SyncTrades()
{
   // Gesamte History laden
   datetime from = D'2000.01.01';
   datetime to   = TimeCurrent();

   if(!HistorySelect(from, to))
   {
      Print("BYB: HistorySelect fehlgeschlagen");
      return;
   }

   int total = HistoryDealsTotal();
   if(total == 0) return;

   string trades_json = "";
   int    count       = 0;

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      // Nur abgeschlossene Buy/Sell Deals
      ENUM_DEAL_ENTRY entry_type = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      ENUM_DEAL_TYPE  deal_type  = (ENUM_DEAL_TYPE) HistoryDealGetInteger(ticket, DEAL_TYPE);

      if(entry_type != DEAL_ENTRY_OUT)          continue;
      if(deal_type  == DEAL_TYPE_BALANCE)        continue;
      if(deal_type  == DEAL_TYPE_CREDIT)         continue;
      if(deal_type  == DEAL_TYPE_CORRECTION)     continue;

      string symbol     = HistoryDealGetString (ticket, DEAL_SYMBOL);
      double price      = HistoryDealGetDouble (ticket, DEAL_PRICE);
      double volume     = HistoryDealGetDouble (ticket, DEAL_VOLUME);
      double profit     = HistoryDealGetDouble (ticket, DEAL_PROFIT);
      double commission = HistoryDealGetDouble (ticket, DEAL_COMMISSION);
      double swap_val   = HistoryDealGetDouble (ticket, DEAL_SWAP);
      long   close_ts   = HistoryDealGetInteger(ticket, DEAL_TIME);
      long   position_id= HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      string comment    = HistoryDealGetString (ticket, DEAL_COMMENT);
      string direction  = (deal_type == DEAL_TYPE_BUY) ? "buy" : "sell";

      // Eröffnungszeit über position_id suchen
      long open_ts = 0;
      long hold_s  = 0;
      if(position_id > 0)
      {
         for(int j = 0; j < total; j++)
         {
            ulong t2 = HistoryDealGetTicket(j);
            if(t2 == 0) continue;
            if(HistoryDealGetInteger(t2, DEAL_POSITION_ID) != position_id) continue;
            if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(t2, DEAL_ENTRY) == DEAL_ENTRY_IN)
            {
               open_ts = HistoryDealGetInteger(t2, DEAL_TIME);
               hold_s  = close_ts - open_ts;
               break;
            }
         }
      }
      if(open_ts == 0) open_ts = close_ts;

      // JSON für diesen Trade aufbauen
      string escape_comment = comment;
      StringReplace(escape_comment, "\"", "'");

      string trade = StringFormat(
         "{\"ticket\":%I64u,\"position_id\":%I64d,\"symbol\":\"%s\","
         "\"direction\":\"%s\",\"entry\":%.5f,\"exit_price\":%.5f,"
         "\"volume\":%.2f,\"profit\":%.2f,\"commission\":%.2f,\"swap\":%.2f,"
         "\"open_time\":%I64d,\"close_time\":%I64d,\"hold_secs\":%I64d,"
         "\"comment\":\"%s\"}",
         ticket, position_id, symbol,
         direction, price, price,
         volume, profit, commission, swap_val,
         open_ts, close_ts, hold_s,
         escape_comment
      );

      if(count > 0) trades_json += ",";
      trades_json += trade;
      count++;

      // Max 200 Trades pro Batch (verhindert zu große Requests)
      if(count >= 200) break;
   }

   if(count == 0)
   {
      Print("BYB: Keine abgeschlossenen Trades gefunden.");
      return;
   }

   // JSON-Payload zusammenbauen
   string payload = StringFormat(
      "{\"token\":\"%s\",\"trades\":[%s]}",
      SyncToken, trades_json
   );

   // HTTP POST senden
   char   post_data[];
   char   result_data[];
   string result_headers;
   string req_headers = "Content-Type: application/json\r\n";

   int payload_len = StringLen(payload);
   ArrayResize(post_data, payload_len);
   StringToCharArray(payload, post_data, 0, payload_len);

   int http_code = WebRequest(
      "POST",
      API_URL,
      req_headers,
      5000,
      post_data,
      result_data,
      result_headers
   );

   string response = CharArrayToString(result_data);

   if(http_code == 200 || http_code == 201)
   {
      Print("BYB Sync ✓ — ", count, " Trades gesendet. Response: ", response);
      if(ShowAlerts && StringFind(response, "\"synced\"") >= 0)
         Comment("BYB Alpha ✓  Letzter Sync: ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
   }
   else if(http_code == -1)
   {
      Print("BYB Sync Fehler: WebRequest nicht erlaubt.");
      Print("→ Gehe zu: Extras → Optionen → Expert Advisors → WebRequest aktivieren");
      Print("→ URL hinzufügen: https://dzlgudlurijmgjwetztf.supabase.co");
      if(ShowAlerts)
         Alert("BYB Alpha: WebRequest nicht aktiviert! Siehe MT5-Log für Anleitung.");
   }
   else
   {
      Print("BYB Sync Fehler: HTTP ", http_code, " — ", response);
   }
}
