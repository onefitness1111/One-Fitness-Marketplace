-- Owner-controlled permissions for each coach.
--
-- Six switches, one boolean each, on the new table coach_permissions:
--   billing_access          see and add a client's saved cards and billing
--                           address (city and state), in the app and in
--                           list-payment-methods, create-setup-intent,
--                           save-billing-address
--   charge_fees             charge a client's card for fees: charge-client,
--                           charge-late-cancellation (coach path),
--                           charge-attendance-fee, and "charge" when a coach
--                           books a single session (staff-single-session).
--                           Refund and waive stay owner-only for everyone.
--   edit_plans              change a client's plan or membership: the plan
--                           price, expiry, remaining sessions and plan
--                           choice on the client profile, enrolling or
--                           buying a plan for a client, and cancelling a
--                           client's membership
--   send_texts              text clients from chat and from broadcasts.
--                           In-app chat, push and email are not affected
--   manage_other_schedules  put sessions on another coach's calendar
--   see_own_revenue         the coach's own earnings: My Pay, and the
--                           revenue figures in their own reports
-- Reports of a coach's own sessions are not a switch. Every coach gets them,
-- scoped to the sessions they ran and the clients they booked or served
-- (coach_report_bookings, coach_report_client_ids below). Never primary_trainer_id.
--
-- The owner always has everything. A person who is not a coach has nothing.
-- A coach with no row has nothing, so a new coach starts with all six off.
-- Coaches that exist when this runs are copied in with all six ON, because
-- today every coach can do all six; nothing changes on rollout.
--
-- Safe to run more than once. Not applied to live yet.

create table if not exists public.coach_permissions (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  billing_access boolean not null default false,
  charge_fees boolean not null default false,
  edit_plans boolean not null default false,
  send_texts boolean not null default false,
  manage_other_schedules boolean not null default false,
  see_own_revenue boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id) on delete set null
);

alter table public.coach_permissions enable row level security;

revoke all on table public.coach_permissions from public, anon;
grant select, insert, update, delete on table public.coach_permissions to authenticated;
grant all on table public.coach_permissions to service_role;

-- A coach reads their own row (so the app can hide what is off). The owner
-- reads and writes every row. Nobody else sees or changes anything.
drop policy if exists coach_permissions_select on public.coach_permissions;
create policy coach_permissions_select on public.coach_permissions
  for select to authenticated
  using ((select public.is_owner()) or profile_id = (select auth.uid()));

drop policy if exists coach_permissions_insert_owner on public.coach_permissions;
create policy coach_permissions_insert_owner on public.coach_permissions
  for insert to authenticated
  with check ((select public.is_owner()));

drop policy if exists coach_permissions_update_owner on public.coach_permissions;
create policy coach_permissions_update_owner on public.coach_permissions
  for update to authenticated
  using ((select public.is_owner()))
  with check ((select public.is_owner()));

drop policy if exists coach_permissions_delete_owner on public.coach_permissions;
create policy coach_permissions_delete_owner on public.coach_permissions
  for delete to authenticated
  using ((select public.is_owner()));

-- Today every coach can do all six, so existing coaches start with all six on.
insert into public.coach_permissions
  (profile_id, billing_access, charge_fees, edit_plans, send_texts, manage_other_schedules, see_own_revenue)
select p.id, true, true, true, true, true, true
from public.profiles p
where p.role = 'coach'
on conflict (profile_id) do nothing;

-- A coach added later gets a row with everything off.
create or replace function public.trainers_default_permissions()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.coach_permissions (profile_id) values (new.profile_id)
  on conflict (profile_id) do nothing;
  return new;
end;
$function$;

revoke all on function public.trainers_default_permissions() from public, anon, authenticated;

drop trigger if exists trg_trainers_default_permissions on public.trainers;
create trigger trg_trainers_default_permissions
  after insert on public.trainers
  for each row
  execute function public.trainers_default_permissions();

-- has_coach_permission(uid, perm): owner -> true; coach -> their switch;
-- anyone else, no row, or an unknown permission name -> false.
-- A signed-in person can only ask about themselves (the owner and the
-- service role can ask about anyone), so this cannot be used to look up
-- another coach's switches.
create or replace function public.has_coach_permission(p_uid uuid, p_perm text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role text;
  v_value boolean;
begin
  if p_uid is null or p_perm is null then
    return false;
  end if;
  if p_perm not in ('billing_access', 'charge_fees', 'edit_plans', 'send_texts', 'manage_other_schedules', 'see_own_revenue') then
    return false;
  end if;
  if auth.role() is distinct from 'service_role'
     and p_uid is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner' then
    return false;
  end if;

  select p.role into v_role from public.profiles p where p.id = p_uid and p.deleted_at is null;
  if v_role = 'owner' then
    return true;
  end if;
  if v_role is distinct from 'coach' then
    return false;
  end if;

  select (to_jsonb(cp) ->> p_perm)::boolean into v_value
  from public.coach_permissions cp
  where cp.profile_id = p_uid;
  return coalesce(v_value, false);
end;
$function$;

revoke all on function public.has_coach_permission(uuid, text) from public, anon;
grant execute on function public.has_coach_permission(uuid, text) to authenticated, service_role;

-- The only way the app changes a switch. Owner only. Turns one switch on or
-- off for one coach, and records who did it in the owner's activity feed.
create or replace function public.set_coach_permission(p_coach uuid, p_perm text, p_allowed boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_caller uuid := auth.uid();
  v_role text;
  v_name text;
  v_row jsonb;
  v_label text;
begin
  if v_caller is null or public.current_user_role() is distinct from 'owner' then
    raise exception 'Only the owner can change a coach''s permissions.';
  end if;
  if p_perm is null or p_perm not in ('billing_access', 'charge_fees', 'edit_plans', 'send_texts', 'manage_other_schedules', 'see_own_revenue') then
    raise exception 'Unknown permission.';
  end if;
  if p_allowed is null then
    raise exception 'Choose on or off.';
  end if;

  select p.role, p.name into v_role, v_name
  from public.profiles p
  where p.id = p_coach and p.deleted_at is null;
  if not found then
    raise exception 'That coach was not found.';
  end if;
  if v_role is distinct from 'coach' then
    raise exception 'Permissions can only be set for a coach.';
  end if;

  insert into public.coach_permissions (profile_id) values (p_coach)
  on conflict (profile_id) do nothing;

  execute format(
    'update public.coach_permissions set %I = $1, updated_at = now(), updated_by = $2 where profile_id = $3',
    p_perm
  ) using p_allowed, v_caller, p_coach;

  v_label := case p_perm
    when 'billing_access' then 'billing and payments access'
    when 'charge_fees' then 'charging fees'
    when 'edit_plans' then 'editing plans and memberships'
    when 'send_texts' then 'sending texts to clients'
    when 'manage_other_schedules' then 'managing other coaches'' schedules'
    else 'seeing their own revenue'
  end;

  insert into public.activity_log (actor_id, actor_name, action, entity, entity_id, subject, summary, details)
  values (
    v_caller,
    coalesce((select p.name from public.profiles p where p.id = v_caller), 'Owner'),
    'edited',
    'permissions',
    p_coach::text,
    nullif(btrim(coalesce(v_name, '')), ''),
    case when p_allowed then 'Allowed ' else 'Stopped ' end || v_label,
    jsonb_build_object('kind', 'coach_permission', 'targetId', p_coach, 'permission', p_perm, 'allowed', p_allowed)
  );

  select to_jsonb(cp) into v_row from public.coach_permissions cp where cp.profile_id = p_coach;
  return v_row;
end;
$function$;

revoke all on function public.set_coach_permission(uuid, text, boolean) from public, anon;
grant execute on function public.set_coach_permission(uuid, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- see_own_revenue
-- ---------------------------------------------------------------------------

-- A coach sees only charges for their own sessions, and only with the switch
-- on. Clients still see their own, and the owner sees all.
drop policy if exists charges_select_scoped on public.charges;
create policy charges_select_scoped on public.charges
  for select to authenticated
  using (
    (select public.is_owner())
    or client_id = (select auth.uid())
    or (
      (select public.current_user_role()) = 'coach'
      and trainer_id = (select auth.uid())
      and public.has_coach_permission((select auth.uid()), 'see_own_revenue')
    )
  );

-- Shop orders carry amounts but no coach, so they are not "own revenue" for
-- anyone. Only the owner and the buying client read or change them. No
-- coach screen uses them.
drop policy if exists orders_select_own_or_staff on public.orders;
create policy orders_select_own_or_staff on public.orders
  for select to public
  using (client_id = (select auth.uid()) or (select public.is_owner()));

drop policy if exists orders_update_staff_only on public.orders;
create policy orders_update_staff_only on public.orders
  for update to public
  using ((select public.is_owner()))
  with check ((select public.is_owner()));

-- Pay rates: the owner, or the coach for their own row with the switch on.
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
      (select public.is_owner())
      or (
        t.profile_id = (select auth.uid())
        and public.has_coach_permission((select auth.uid()), 'see_own_revenue')
      )
    );
$function$;

revoke all on function public.trainer_pay_for(uuid[]) from public, anon;
grant execute on function public.trainer_pay_for(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- Reports of a coach's own sessions (no switch)
-- ---------------------------------------------------------------------------

-- Sessions in a date range. The owner gets every session. A coach gets only
-- sessions where they are the coach. Not assigned clients: a session they ran.
create or replace function public.coach_report_bookings(p_from date, p_to date)
returns setof public.bookings
language sql
stable
security definer
set search_path to 'public'
as $function$
  select b.*
  from public.bookings b
  where b.date between p_from and p_to
    and (
      public.is_owner()
      or (public.current_user_role() = 'coach' and b.trainer_id = auth.uid())
    );
$function$;

revoke all on function public.coach_report_bookings(date, date) from public, anon;
grant execute on function public.coach_report_bookings(date, date) to authenticated;

-- Clients a coach has booked or served: anyone with a session on that
-- coach's own calendar, past or future. The owner gets every client.
create or replace function public.coach_report_client_ids()
returns table (client_id uuid)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select c.profile_id
  from public.clients c
  where public.is_owner()
  union
  select distinct b.client_id
  from public.bookings b
  where public.current_user_role() = 'coach'
    and b.trainer_id = auth.uid()
    and b.client_id is not null;
$function$;

revoke all on function public.coach_report_client_ids() from public, anon;
grant execute on function public.coach_report_client_ids() to authenticated;

-- ---------------------------------------------------------------------------
-- billing_access
-- ---------------------------------------------------------------------------

-- City and state of a billing address. A coach without the switch gets an
-- empty answer rather than an error.
create or replace function public.client_billing_locality(p_client uuid)
returns table (city text, state text)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  addr jsonb;
begin
  select c.billing_address
    into addr
  from public.clients c
  where c.profile_id = p_client;

  if auth.role() is distinct from 'service_role'
     and p_client is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner'
     and public.current_user_role() is distinct from 'coach' then
    raise exception 'Not allowed to read that billing address.';
  end if;

  if public.current_user_role() = 'coach'
     and p_client is distinct from auth.uid()
     and auth.role() is distinct from 'service_role'
     and not public.has_coach_permission(auth.uid(), 'billing_access') then
    city := null;
    state := null;
    return next;
    return;
  end if;

  city := nullif(btrim(addr->>'city'), '');
  state := nullif(btrim(addr->>'state'), '');
  return next;
end;
$$;

revoke all on function public.client_billing_locality(uuid) from public, anon;
grant execute on function public.client_billing_locality(uuid) to authenticated, service_role;

create or replace function public.set_client_billing_address(p_client uuid, p_address jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  existing jsonb;
  actor_is_coach boolean;
begin
  select c.billing_address
    into existing
  from public.clients c
  where c.profile_id = p_client;

  if auth.role() is distinct from 'service_role'
     and p_client is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner'
     and public.current_user_role() is distinct from 'coach' then
    raise exception 'Not allowed to update that billing address.';
  end if;

  -- Any coach may fill an empty address and may not replace one. The client
  -- and the owner may replace it. service_role is the path Profile Settings
  -- already uses; save-billing-address applies this same lock for a coach.
  actor_is_coach := public.current_user_role() = 'coach'
    and p_client is distinct from auth.uid()
    and auth.role() is distinct from 'service_role';
  if actor_is_coach and not public.has_coach_permission(auth.uid(), 'billing_access') then
    raise exception 'You don''t have billing and payments access. Ask the owner.';
  end if;
  if actor_is_coach and coalesce(btrim(existing->>'line1'), '') <> '' then
    raise exception 'Only the owner can change an address that''s already on file.';
  end if;

  if coalesce(p_address->>'line1', '') = '' or coalesce(p_address->>'city', '') = '' then
    raise exception 'Enter the street and city.';
  end if;
  update public.clients
  set billing_address = p_address,
      city = nullif(btrim(p_address->>'city'), ''),
      state = nullif(btrim(p_address->>'state'), '')
  where profile_id = p_client;
end;
$function$;

revoke all on function public.set_client_billing_address(uuid, jsonb) from public, anon;
grant execute on function public.set_client_billing_address(uuid, jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- edit_plans
-- ---------------------------------------------------------------------------

-- A coach without the switch cannot write a client's plan fields straight
-- to the table. This is a plain (invoker) trigger on purpose: it only sees
-- writes made as the signed-in coach. The server's own functions (the
-- Stripe webhook, enroll-free-plan, rollover, request approval) run with
-- the service role or as the function owner and are not touched.
create or replace function public.guard_coach_plan_edits()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  if current_user is distinct from 'authenticated' then
    return new;
  end if;
  if public.current_user_role() is distinct from 'coach'
     or auth.uid() is not distinct from old.profile_id then
    return new;
  end if;
  if public.has_coach_permission(auth.uid(), 'edit_plans') then
    return new;
  end if;
  if new.plans is distinct from old.plans
     or new.membership_plan_id is distinct from old.membership_plan_id
     or new.session_count_override is distinct from old.session_count_override
     or new.session_count_override_month is distinct from old.session_count_override_month
     or new.membership_cancels_at is distinct from old.membership_cancels_at then
    raise exception 'You don''t have permission to edit plans and memberships. Ask the owner.'
      using errcode = '42501';
  end if;
  return new;
end;
$function$;

revoke all on function public.guard_coach_plan_edits() from public, anon;
grant execute on function public.guard_coach_plan_edits() to authenticated, service_role;

drop trigger if exists trg_guard_coach_plan_edits on public.clients;
create trigger trg_guard_coach_plan_edits
  before update on public.clients
  for each row
  execute function public.guard_coach_plan_edits();

-- ---------------------------------------------------------------------------
-- send_texts
-- ---------------------------------------------------------------------------

-- A coach without the switch can still send an in-app message. The text
-- (SMS) part is dropped from the saved channel, so the database never asks
-- chat-auto-reply-sms to text the client. 'inappsms' becomes 'inapp' and
-- 'both' becomes 'inapp,email'.
create or replace function public.messages_guard_coach_sms()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text;
  v_tokens text[];
begin
  if new.who is distinct from 'trainer'
     or new.sender_id is null
     or coalesce(auth.role(), '') = 'service_role' then
    return new;
  end if;

  select p.role into v_role from public.profiles p where p.id = new.sender_id;
  if v_role is distinct from 'coach' then
    return new;
  end if;
  if public.has_coach_permission(new.sender_id, 'send_texts') then
    return new;
  end if;

  v_tokens := array(
    select btrim(t)
    from unnest(string_to_array(lower(coalesce(new.channel, '')), ',')) as t
    where btrim(t) <> ''
  );
  if not (v_tokens && array['sms', 'inappsms', 'both']) then
    return new;
  end if;

  select array_agg(distinct x) into v_tokens
  from (
    select unnest(
      case t
        when 'inappsms' then array['inapp']
        when 'both' then array['inapp', 'email']
        when 'sms' then array['inapp']
        else array[t]
      end
    ) as x
    from unnest(v_tokens) as t
  ) s;

  new.channel := array_to_string(v_tokens, ',');
  return new;
end;
$function$;

revoke all on function public.messages_guard_coach_sms() from public, anon, authenticated;

drop trigger if exists trg_messages_guard_coach_sms on public.messages;
create trigger trg_messages_guard_coach_sms
  before insert on public.messages
  for each row
  execute function public.messages_guard_coach_sms();

-- ---------------------------------------------------------------------------
-- manage_other_schedules
-- ---------------------------------------------------------------------------

-- A coach may add a session to their own calendar or to their own booking
-- as a client. Adding a session to another coach's calendar needs the
-- switch. Moving or cancelling someone else's session was already
-- owner-only (bookings_update_involved_or_staff, bookings_delete_involved_or_staff).
drop policy if exists bookings_insert_self_or_staff on public.bookings;
create policy bookings_insert_self_or_staff on public.bookings
  for insert to authenticated
  with check (
    client_id = (select auth.uid())
    or trainer_id = (select auth.uid())
    or (select public.current_user_role()) = 'owner'
    or (
      (select public.current_user_role()) = 'coach'
      and public.has_coach_permission((select auth.uid()), 'manage_other_schedules')
    )
  );

notify pgrst, 'reload schema';
