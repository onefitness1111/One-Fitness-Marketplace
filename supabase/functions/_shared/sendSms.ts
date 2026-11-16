// Twilio SMS — raw REST API via fetch (same reasoning as
// generate-ai-workout-program's raw-HTTP-over-SDK choice: no extra
// dependency to fail to resolve in the edge bundler, and Twilio's Messages
// API is simple enough not to need a client library). Best-effort by
// design: returns quietly if TWILIO_ACCOUNT_SID/TWILIO_AUTH_TOKEN/
// TWILIO_FROM_NUMBER aren't set yet (they aren't, until the owner adds them
// via `supabase secrets set`) or `to` is empty, so this can never be the
// reason a real event (a failed payment, a waitlist opening) fails to
// process, and it's already safe to deploy before those secrets exist.
export async function sendSms(to: string, body: string): Promise<void> {
  const sid = Deno.env.get("TWILIO_ACCOUNT_SID");
  const token = Deno.env.get("TWILIO_AUTH_TOKEN");
  const from = Deno.env.get("TWILIO_FROM_NUMBER");
  if (!sid || !token || !from || !to) return;

  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${sid}:${token}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ To: to, From: from, Body: body }).toString(),
  });
  if (!res.ok) {
    const detail = await res.text();
    console.error(`sendSms failed (${res.status}): ${detail}`);
  }
}
