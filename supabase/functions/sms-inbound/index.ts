// Inbound SMS from Twilio: STOP / START / HELP, and replies to texts a coach
// sent from the app (stored in the chat thread and the coach is notified).
// The logic lives in _shared/inboundSms.ts so this and twilio-inbound behave
// identically whichever URL the Twilio number is pointed at.
// Deploy WITHOUT jwt verification: Twilio sends no JWT; the request is
// authenticated by Twilio's signature instead.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { handleInbound } from "../_shared/inboundSms.ts";

serve(handleInbound);
