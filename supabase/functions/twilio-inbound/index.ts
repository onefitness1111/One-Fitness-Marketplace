// Same inbound SMS handler as sms-inbound. The business number's webhook
// may point at either name. Deploy WITHOUT jwt verification:
//   supabase functions deploy twilio-inbound --no-verify-jwt
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { handleInbound } from "../_shared/inboundSms.ts";

serve(handleInbound);
