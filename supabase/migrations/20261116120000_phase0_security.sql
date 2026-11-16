-- Phase 0 security (review only — not applied to the live database).
--
-- What this does, in plain language:
-- 1. A new account is always a client. Coach is granted only after the
--    approval code checks out on the server, or when the owner promotes
--    someone. The code itself is no longer readable without being the owner.
-- 2. Email, phone, and the private calendar token are not returned by
--    ordinary profile reads. The signed-in person and the owner can still
--    read email and phone through profile_contact_for(). The calendar token
--    is readable only by the account it belongs to, and only by the
--    get-calendar-link function (service role).
-- 3. Card, bank, Stripe, and balance fields are not returned on ordinary
--    client reads, and are left off the live updates stream. The person
--    themselves and the owner read them through client_billing_for().
-- 4. Coach pay rates are not on ordinary trainer reads. A coach sees their
--    own through trainer_pay_for(); the owner sees everyone's.
-- 5. Charges: a client sees their own, a coach sees the lines that name
--    them as the coach, the owner sees all. Only the owner can add, edit,
--    or delete a charge row from the app. Real card payments still insert
--    charges from the server.
-- 6. Only the owner can set a client's balance.
--
-- After you run this, reload the API schema (the last statement does that)
-- and deploy the Edge Functions in supabase/functions/ that this pull
-- request lists. The app on this branch expects both.

-- ---------------------------------------------------------------------------
-- Coach approval
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  -- Ignore requested_role. A caller can put anything in sign-up metadata,
  -- so the role is never taken from there. Coach comes later, from
  -- grant_coach_with_code or owner_promote_coach.
  insert into public.profiles (id, role, name, email, phone)
  values (
    new.id,
    'client',
    coalesce(new.raw_user_meta_data->>'name', ''),
    new.email,
    coalesce(new.raw_user_meta_data->>'phone', '')
  );
  return new;
end;
$function$;

create or replace function public.prevent_role_escalation()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.role is distinct from old.role
     and public.current_user_role() is distinct from 'owner'
     and coalesce(current_setting('app.coach_code_grant', true), '') is distinct from 'on'
  then
    new.role := old.role;
  end if;
  return new;
end;
$function$;

-- Failed code guesses. No policies: only the functions below (which run as
-- the database owner) can read or write it.
create table if not exists public.coach_code_attempts (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  ok boolean not null default false
);

alter table public.coach_code_attempts enable row level security;
revoke all on table public.coach_code_attempts from public, anon, authenticated;

create or replace function public._coach_code_attempt_limited()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select count(*) >= 30
  from public.coach_code_attempts
  where ok = false
    and created_at > now() - interval '1 hour';
$function$;

revoke all on function public._coach_code_attempt_limited() from public, anon, authenticated;

-- Returns ok / used / expired / invalid / limited. Never returns the code.
-- Used by the signup screen before the form, so a wrong code stops there.
create or replace function public.coach_code_status(entered_code text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  row_code text;
  row_used timestamptz;
  row_expires date;
  trimmed text := btrim(coalesce(entered_code, ''));
begin
  if public._coach_code_attempt_limited() then
    return 'limited';
  end if;

  select code, used_at, expires_at
    into row_code, row_used, row_expires
  from public.coach_approval_code
  where id = true;

  if row_code is null or row_code is distinct from trimmed then
    insert into public.coach_code_attempts (ok) values (false);
    return 'invalid';
  end if;
  if row_used is not null then
    return 'used';
  end if;
  if row_expires is not null and row_expires < current_date then
    return 'expired';
  end if;
  return 'ok';
end;
$function$;

revoke all on function public.coach_code_status(text) from public;
grant execute on function public.coach_code_status(text) to anon, authenticated;

-- The signed-in person becomes a coach if the code is valid. Consumes the
-- code in the same step, so two people cannot spend one code.
create or replace function public.grant_coach_with_code(entered_code text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  row_code text;
  row_used timestamptz;
  row_expires date;
  trimmed text := btrim(coalesce(entered_code, ''));
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Sign in before using a coach code.';
  end if;
  if public.current_user_role() = 'owner' then
    raise exception 'The owner account stays the owner.';
  end if;
  if public.current_user_role() = 'coach' then
    return;
  end if;
  if public._coach_code_attempt_limited() then
    raise exception 'Too many tries. Wait an hour, or ask the owner for a new code.';
  end if;

  select code, used_at, expires_at
    into row_code, row_used, row_expires
  from public.coach_approval_code
  where id = true
  for update;

  if row_code is null or row_code is distinct from trimmed then
    insert into public.coach_code_attempts (ok) values (false);
    raise exception 'That code is invalid or has expired. Contact ONE Fitness for a current code.';
  end if;
  if row_used is not null then
    raise exception 'That approval code has already been used.';
  end if;
  if row_expires is not null and row_expires < current_date then
    raise exception 'That approval code has expired — ask the owner for a new one.';
  end if;

  insert into public.coach_code_attempts (ok) values (true);
  perform set_config('app.coach_code_grant', 'on', true);
  update public.profiles set role = 'coach' where id = me;
  -- handle_new_user always creates a client row. A coach is a separate
  -- account, so that empty client row should not put them on the roster.
  delete from public.clients where profile_id = me;
  update public.coach_approval_code set used_at = now() where id = true;
end;
$function$;

revoke all on function public.grant_coach_with_code(text) from public, anon;
grant execute on function public.grant_coach_with_code(text) to authenticated;

-- Owner adds a coach directly (no code). The new login is created as a
-- client first; this promotes it.
create or replace function public.owner_promote_coach(p_user uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if public.current_user_role() is distinct from 'owner' then
    raise exception 'Only the owner can add a coach this way.';
  end if;
  if p_user is null then
    raise exception 'Missing account.';
  end if;
  update public.profiles
     set role = 'coach'
   where id = p_user
     and role = 'client';
  delete from public.clients where profile_id = p_user;
end;
$function$;

revoke all on function public.owner_promote_coach(uuid) from public, anon;
grant execute on function public.owner_promote_coach(uuid) to authenticated;

-- Burning the code without becoming a coach is no longer possible from the app.
revoke all on function public.mark_coach_code_used(text) from public, anon, authenticated;

drop policy if exists coach_approval_code_select_public on public.coach_approval_code;
create policy coach_approval_code_select_owner
  on public.coach_approval_code
  for select
  to authenticated
  using ((select public.current_user_role()) = 'owner');

-- A trainers row is only for a real coach, and only the owner sets pay.
create or replace function public.trainers_guard_role_and_pay()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  their_role text;
begin
  if auth.role() is distinct from 'service_role'
     and public.current_user_role() is distinct from 'owner'
  then
    select role into their_role from public.profiles where id = new.profile_id;
    if their_role is distinct from 'coach' then
      raise exception 'Only a coach account can have a coach profile.';
    end if;
    if tg_op = 'INSERT' then
      new.commission_rate := 0;
      new.payout_rate_cents := 0;
      new.payout_mode := 'perSession';
      new.referral_commission_percent := 0;
    else
      new.commission_rate := old.commission_rate;
      new.payout_rate_cents := old.payout_rate_cents;
      new.payout_mode := old.payout_mode;
      new.referral_commission_percent := old.referral_commission_percent;
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists trainers_guard_role_and_pay on public.trainers;
create trigger trainers_guard_role_and_pay
  before insert or update on public.trainers
  for each row
  execute function public.trainers_guard_role_and_pay();

-- ---------------------------------------------------------------------------
-- Private profile fields
-- ---------------------------------------------------------------------------

create or replace function public.profiles_guard_private()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  caller uuid := auth.uid();
  privileged boolean := auth.role() = 'service_role' or public.current_user_role() = 'owner';
begin
  if not privileged and caller is distinct from old.id then
    if new.email is distinct from old.email then
      new.email := old.email;
    end if;
    if new.phone is distinct from old.phone then
      new.phone := old.phone;
    end if;
  end if;
  -- The calendar link is minted by get-calendar-link. Nobody else writes it.
  if auth.role() is distinct from 'service_role'
     and new.calendar_token is distinct from old.calendar_token
  then
    new.calendar_token := old.calendar_token;
  end if;
  return new;
end;
$function$;

drop trigger if exists profiles_guard_private on public.profiles;
create trigger profiles_guard_private
  before update on public.profiles
  for each row
  execute function public.profiles_guard_private();

-- Email and phone for yourself, or every account if you are the owner.
create or replace function public.profile_contact_for(p_ids uuid[])
returns table (id uuid, email text, phone text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.id, p.email, p.phone
  from public.profiles p
  where p.id = any (coalesce(p_ids, array[]::uuid[]))
    and (
      p.id = (select auth.uid())
      or (select public.is_owner())
    );
$function$;

revoke all on function public.profile_contact_for(uuid[]) from public, anon;
grant execute on function public.profile_contact_for(uuid[]) to authenticated;

revoke select on table public.profiles from public, anon, authenticated;
grant select (
  id,
  role,
  name,
  first_name,
  last_name,
  photo_url,
  created_at,
  push_opt_in,
  accepted_terms_at,
  accepted_terms_version,
  over_18_confirmed_at,
  banned_at,
  ban_reason,
  deleted_at
) on table public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Client billing (owner and the client themselves)
-- ---------------------------------------------------------------------------

create or replace function public.guard_client_balance()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if tg_op = 'UPDATE'
     and new.balance_cents is distinct from old.balance_cents
     and not (auth.role() = 'service_role' or public.current_user_role() = 'owner')
  then
    new.balance_cents := old.balance_cents;
  end if;
  return new;
end;
$function$;

create or replace function public.set_client_balance(p_client uuid, p_cents integer)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v integer;
begin
  if public.current_user_role() is distinct from 'owner' then
    raise exception 'Only the owner can change a balance.';
  end if;
  update public.clients
     set balance_cents = p_cents
   where profile_id = p_client
  returning balance_cents into v;
  return v;
end;
$function$;

create or replace function public.clients_guard_billing()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  caller uuid := auth.uid();
  allowed boolean := auth.role() = 'service_role'
    or public.current_user_role() = 'owner'
    or caller = old.profile_id;
begin
  if allowed then
    return new;
  end if;
  new.stripe_customer_id := old.stripe_customer_id;
  new.stripe_subscription_id := old.stripe_subscription_id;
  new.stripe_schedule_id := old.stripe_schedule_id;
  new.pending_plan_price_id := old.pending_plan_price_id;
  new.billing_address := old.billing_address;
  new.billing_anchor_day := old.billing_anchor_day;
  new.balance_cents := old.balance_cents;
  new.has_outstanding_balance := old.has_outstanding_balance;
  new.outstanding_balance_cents := old.outstanding_balance_cents;
  new.outstanding_invoice_id := old.outstanding_invoice_id;
  new.outstanding_invoice_url := old.outstanding_invoice_url;
  new.outstanding_since := old.outstanding_since;
  return new;
end;
$function$;

drop trigger if exists clients_guard_billing on public.clients;
create trigger clients_guard_billing
  before update on public.clients
  for each row
  execute function public.clients_guard_billing();

create or replace function public.client_billing_for(p_ids uuid[])
returns table (
  profile_id uuid,
  stripe_customer_id text,
  stripe_subscription_id text,
  stripe_schedule_id text,
  pending_plan_price_id text,
  billing_address jsonb,
  billing_anchor_day integer,
  balance_cents integer,
  has_outstanding_balance boolean,
  outstanding_balance_cents integer,
  outstanding_invoice_id text,
  outstanding_invoice_url text,
  outstanding_since timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select
    c.profile_id,
    c.stripe_customer_id,
    c.stripe_subscription_id,
    c.stripe_schedule_id,
    c.pending_plan_price_id,
    c.billing_address,
    c.billing_anchor_day,
    c.balance_cents,
    c.has_outstanding_balance,
    c.outstanding_balance_cents,
    c.outstanding_invoice_id,
    c.outstanding_invoice_url,
    c.outstanding_since
  from public.clients c
  where c.profile_id = any (coalesce(p_ids, array[]::uuid[]))
    and (
      c.profile_id = (select auth.uid())
      or (select public.is_owner())
    );
$function$;

revoke all on function public.client_billing_for(uuid[]) from public, anon;
grant execute on function public.client_billing_for(uuid[]) to authenticated;

revoke select on table public.clients from public, anon, authenticated;
grant select (
  profile_id,
  birthday,
  city,
  state,
  home_lat,
  home_lng,
  membership_plan_id,
  primary_trainer_id,
  plans,
  tour_seen,
  membership_paused,
  membership_paused_at,
  membership_paused_days,
  updated_at,
  custom_fields,
  membership_freeze_ends_at,
  session_count_override,
  pending_plan_id,
  pending_plan_effective_at,
  session_count_override_month,
  membership_cancels_at,
  referred_by_trainer_id,
  coach_code_alert_seen,
  sms_opt_in,
  redeem_points_next_renewal,
  marketing_opt_out,
  sms_opt_in_at,
  sms_consent_text,
  emergency_contact_name,
  emergency_contact_phone
) on table public.clients to authenticated;

-- Live updates of a client row should not carry card or balance fields.
alter publication supabase_realtime drop table public.clients;
alter publication supabase_realtime add table public.clients (
  profile_id,
  birthday,
  city,
  state,
  home_lat,
  home_lng,
  membership_plan_id,
  primary_trainer_id,
  plans,
  tour_seen,
  membership_paused,
  membership_paused_at,
  membership_paused_days,
  updated_at,
  custom_fields,
  membership_freeze_ends_at,
  session_count_override,
  pending_plan_id,
  pending_plan_effective_at,
  session_count_override_month,
  membership_cancels_at,
  referred_by_trainer_id,
  coach_code_alert_seen,
  sms_opt_in,
  redeem_points_next_renewal,
  marketing_opt_out,
  sms_opt_in_at,
  sms_consent_text,
  emergency_contact_name,
  emergency_contact_phone
);

-- ---------------------------------------------------------------------------
-- Coach pay
-- ---------------------------------------------------------------------------

create or replace function public.trainer_pay_for(p_ids uuid[])
returns table (
  profile_id uuid,
  commission_rate numeric,
  payout_mode text,
  payout_rate_cents integer,
  referral_commission_percent numeric
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select
    t.profile_id,
    t.commission_rate,
    t.payout_mode,
    t.payout_rate_cents,
    t.referral_commission_percent
  from public.trainers t
  where t.profile_id = any (coalesce(p_ids, array[]::uuid[]))
    and (
      t.profile_id = (select auth.uid())
      or (select public.is_owner())
    );
$function$;

revoke all on function public.trainer_pay_for(uuid[]) from public, anon;
grant execute on function public.trainer_pay_for(uuid[]) to authenticated;

revoke select on table public.trainers from public, anon, authenticated;
grant select (
  profile_id,
  disciplines,
  session_types,
  slot_interval,
  availability,
  programmer_availability,
  locations,
  bio,
  before_afters,
  avail_lock_until,
  signup_at,
  reviewed_by_owner,
  updated_at,
  coach_code,
  unavailability,
  title
) on table public.trainers to authenticated;

-- ---------------------------------------------------------------------------
-- Charges
-- ---------------------------------------------------------------------------

drop policy if exists charges_select_authenticated on public.charges;
create policy charges_select_scoped
  on public.charges
  for select
  to authenticated
  using (
    (select public.is_owner())
    or client_id = (select auth.uid())
    or (
      (select public.current_user_role()) = 'coach'
      and trainer_id = (select auth.uid())
    )
  );

drop policy if exists charges_insert_self_or_staff on public.charges;
create policy charges_insert_owner
  on public.charges
  for insert
  to authenticated
  with check ((select public.is_owner()));

drop policy if exists charges_update_staff_only on public.charges;
create policy charges_update_owner
  on public.charges
  for update
  to authenticated
  using ((select public.is_owner()))
  with check ((select public.is_owner()));

drop policy if exists charges_delete_staff_only on public.charges;
create policy charges_delete_owner
  on public.charges
  for delete
  to authenticated
  using ((select public.is_owner()));

create index if not exists charges_trainer_idx on public.charges (trainer_id);

-- ---------------------------------------------------------------------------
-- Outbound message log (Edge Functions only)
-- ---------------------------------------------------------------------------

create table if not exists public.outbound_message_log (
  id bigint generated always as identity primary key,
  sender_id uuid not null,
  channel text not null,
  created_at timestamptz not null default now()
);

alter table public.outbound_message_log enable row level security;
revoke all on table public.outbound_message_log from public, anon, authenticated;

notify pgrst, 'reload schema';
