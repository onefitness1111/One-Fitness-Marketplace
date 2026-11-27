-- Texting safety net shared by every Edge Function (see _shared/sendSms.ts
-- and _shared/autoSms.ts).
--
-- 1. STOP sync. sms_mark_phone(phone, 'stop') marks every profile on that
--    number opted out, the same way an inbound STOP does. sendSms calls it
--    when Twilio answers 21610 ("unsubscribed recipient"), and twilio-status
--    calls it from delivery reports. START (inbound) still reverses it.
-- 2. Unreachable numbers. sms_mark_phone(phone, 'undeliverable') stamps
--    profiles.sms_undeliverable_at. Changing the phone number clears it.
-- 3. sms_phone_status(phone): sendSms asks before every text. STOP on any
--    profile with that number blocks the text.
-- 4. sms_outbox: automatic texts that fall in quiet hours (9pm-8am Pacific)
--    wait here until 8:00am. send-scheduled-reminders sends them hourly.
-- 5. sms_log: Twilio message SIDs and delivery status. No phone numbers and
--    no message text.
--
-- Only the service role can call the two functions. Only the owner can read
-- the two tables. No coach-assignment field is used.
-- Not applied to the live database by this change.

alter table public.profiles
  add column if not exists sms_undeliverable_at timestamptz;

comment on column public.profiles.sms_undeliverable_at is
  'Twilio said this number cannot get texts (not a mobile, unreachable). Cleared when the phone changes.';

create or replace function public.profiles_phone_resets_sms_flags()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if new.phone is distinct from old.phone then
    new.sms_undeliverable_at := null;
  end if;
  return new;
end;
$$;

revoke all on function public.profiles_phone_resets_sms_flags() from public, anon, authenticated;

-- Named to run after profiles_guard_private (triggers fire in name order).
drop trigger if exists trg_profiles_phone_resets_sms_flags on public.profiles;
create trigger trg_profiles_phone_resets_sms_flags
  before update of phone on public.profiles
  for each row execute function public.profiles_phone_resets_sms_flags();

create or replace function public.sms_phone_tail(raw_phone text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select case
    when length(regexp_replace(coalesce(raw_phone, ''), '[^0-9]', '', 'g')) < 7 then null
    else right(regexp_replace(coalesce(raw_phone, ''), '[^0-9]', '', 'g'), 10)
  end;
$$;

create or replace function public.sms_phone_status(raw_phone text)
returns table (opted_out boolean, undeliverable boolean)
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    coalesce(bool_or(p.sms_opted_out is true), false),
    coalesce(bool_or(p.sms_undeliverable_at is not null), false)
  from public.profiles p
  where public.sms_phone_tail(raw_phone) is not null
    and right(regexp_replace(coalesce(p.phone, ''), '[^0-9]', '', 'g'), 10) = public.sms_phone_tail(raw_phone);
$$;

create or replace function public.sms_mark_phone(raw_phone text, p_kind text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  tail text := public.sms_phone_tail(raw_phone);
  ids uuid[];
begin
  if tail is null or p_kind not in ('stop', 'undeliverable') then
    return 0;
  end if;
  select array_agg(p.id) into ids
  from public.profiles p
  where right(regexp_replace(coalesce(p.phone, ''), '[^0-9]', '', 'g'), 10) = tail;
  if ids is null then
    return 0;
  end if;

  if p_kind = 'stop' then
    update public.profiles
    set sms_opted_out = true, sms_consent_at = null, sms_consent_text = null
    where id = any (ids);
    update public.clients
    set sms_opt_in = false, sms_opt_in_at = null, sms_consent_text = null
    where profile_id = any (ids);
  else
    update public.profiles
    set sms_undeliverable_at = coalesce(sms_undeliverable_at, now())
    where id = any (ids);
  end if;
  return cardinality(ids);
end;
$$;

revoke all on function public.sms_phone_tail(text) from public, anon, authenticated;
revoke all on function public.sms_phone_status(text) from public, anon, authenticated;
revoke all on function public.sms_mark_phone(text, text) from public, anon, authenticated;
grant execute on function public.sms_phone_tail(text) to service_role;
grant execute on function public.sms_phone_status(text) to service_role;
grant execute on function public.sms_mark_phone(text, text) to service_role;

create table if not exists public.sms_outbox (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  body text not null,
  kind text not null,
  ref text,
  not_before timestamptz not null,
  expires_at timestamptz,
  status text not null default 'pending'
    check (status in ('pending', 'sending', 'sent', 'skipped', 'expired')),
  outcome text,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index if not exists sms_outbox_once
  on public.sms_outbox (kind, ref, profile_id)
  where ref is not null;
create index if not exists sms_outbox_due
  on public.sms_outbox (status, not_before);

alter table public.sms_outbox enable row level security;
drop policy if exists sms_outbox_owner_select on public.sms_outbox;
create policy sms_outbox_owner_select on public.sms_outbox
  for select to authenticated
  using ((select public.is_owner()));
revoke all on public.sms_outbox from anon;
grant select on public.sms_outbox to authenticated;

create table if not exists public.sms_log (
  sid text primary key,
  kind text,
  status text not null,
  error_code integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.sms_log enable row level security;
drop policy if exists sms_log_owner_select on public.sms_log;
create policy sms_log_owner_select on public.sms_log
  for select to authenticated
  using ((select public.is_owner()));
revoke all on public.sms_log from anon;
grant select on public.sms_log to authenticated;
