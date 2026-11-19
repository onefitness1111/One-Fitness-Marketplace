// Inbound SMS from Twilio. STOP / UNSUBSCRIBE / HELP, and routing into the
// right chat. The logic lives in _shared/inboundSms.ts so this and
// twilio-inbound behave the same whichever URL the business number uses.
//
// Deploy WITHOUT jwt verification:
//   supabase functions deploy sms-inbound --no-verify-jwt
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { handleInbound } from "../_shared/inboundSms.ts";

serve(handleInbound);
