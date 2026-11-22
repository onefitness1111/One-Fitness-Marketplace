-- Read-only review before any invite text goes out.
-- Do not run this file as a migration. Paste it in the SQL editor.
-- It does not update, insert, or delete anything.
--
-- App 1.1.3 stored "turn texts off" as clients.sms_opt_in = false and did
-- not set sms_declined_at. That is the same shape as someone who never
-- answered, because sms_opt_in defaults to false. Do not backfill a
-- decline from that. The audit found 21 people in the candidate set
-- below; this query returns whoever matches now.
--
-- An invite can be sent only when sms_invite_enabled is true AND the
-- client has never been invited AND sms_declined_at is null AND they
-- have not opted out AND they have not already agreed. The flag is
-- inserted false. Leave it false until this list has been checked.
--
-- After marking anyone who said no:
--   update public.clients
--      set sms_declined_at = now()
--    where profile_id = '<their profile id>'
--      and sms_declined_at is null;
-- Then, only when the list looks right:
--   update public.app_config
--      set sms_invite_enabled = true
--    where id = 'mobile';

-- Candidates an invite would reach once the flag is turned on.
-- Never invited, no recorded decline, not opted out, no consent on file.
select
  c.profile_id,
  p.name,
  p.phone,
  c.sms_opt_in,
  c.sms_opt_in_at,
  c.sms_consent_text,
  c.sms_declined_at,
  c.sms_invite_sent_at,
  p.sms_opted_out,
  p.sms_consent_at,
  (select a.sms_invite_enabled from public.app_config a where a.id = 'mobile') as sms_invite_enabled
from public.clients c
join public.profiles p on p.id = c.profile_id
where p.deleted_at is null
  and p.role = 'client'
  and c.sms_declined_at is null
  and p.sms_opted_out is not true
  and c.sms_invite_sent_at is null
  and c.sms_opt_in is not true
  and p.sms_consent_at is null
  and nullif(btrim(coalesce(p.phone, '')), '') is not null
order by p.name;

-- Separate list: sms_opt_in is off, but a consent timestamp is still on
-- the profile. Those people are texted the coach's message, not an invite,
-- because the consent timestamp still counts. Not backfilled here. Set
-- sms_declined_at if they turned texts off.
select
  c.profile_id,
  p.name,
  p.phone,
  c.sms_opt_in,
  c.sms_opt_in_at,
  p.sms_consent_at,
  c.sms_declined_at,
  p.sms_opted_out
from public.clients c
join public.profiles p on p.id = c.profile_id
where p.deleted_at is null
  and p.role = 'client'
  and c.sms_opt_in is not true
  and p.sms_consent_at is not null
  and c.sms_declined_at is null
  and p.sms_opted_out is not true
order by p.name;
