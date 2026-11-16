// Same webhook as sms-inbound (kept so a Twilio number already pointed at this
// URL keeps working). See _shared/inboundSms.ts.
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { handleInbound } from "../_shared/inboundSms.ts";

serve(handleInbound);
