-- Batch 2 (review only — not applied to the live database).
--
-- What this does, in plain language:
-- 1. A coach can ask the owner to freeze a membership, restrict a client,
--    add a second free session, change a balance, delete an account, or
--    lift one of those. Nothing changes until the owner approves.
-- 2. A freeze that is approved does not start for 48 hours, and not before
--    the "from" date the coach entered.
-- 3. Each coach gets one free session-add per week (Monday to Sunday,
--    Los Angeles time). Another one is refused here until the owner has
--    approved it. Free adds are marked so they do not count toward coach pay.
-- 4. Coach applications (Apply now) are stored for the owner to approve.
--    The files sit in a private Storage bucket.
--
-- Run this after 20261116120000_phase0_security.sql. The last line reloads
-- the API so the app can see the new tables.

-- ---------------------------------------------------------------------------
-- Columns the app and the pay screen read
-- ---------------------------------------------------------------------------

alter table public.bookings
  add column if not exists counts_toward_pay boolean not null default true;

alter table public.clients
  add column if not exists booking_restricted boolean not null default false;

alter table public.clients
  add column if not exists booking_restricted_reason text;

alter table public.clients
  add column if not exists booking_restricted_at timestamptz;

comment on column public.bookings.counts_toward_pay is
  'False for a free session a coach or the owner comped. Those sessions stay on the schedule and do not count toward coach pay.';

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

create table if not exists public.coach_requests (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  coach_id uuid not null references public.profiles (id),
  client_id uuid references public.profiles (id),
  kind text not null,
  status text not null default 'pending',
  reason text,
  payload jsonb not null default '{}'::jsonb,
  decided_by uuid,
  decided_at timestamptz,
  decision_note text,
  effective_at timestamptz,
  applied_at timestamptz,
  constraint coach_requests_kind_chk check (kind in (
    'freeze_membership',
    'unfreeze_membership',
    'restrict_client',
    'lift_restriction',
    'extra_free_session',
    'adjust_balance',
    'delete_client'
  )),
  constraint coach_requests_status_chk check (status in ('pending', 'approved', 'denied'))
);

create index if not exists coach_requests_status_idx
  on public.coach_requests (status, created_at desc);

create index if not exists coach_requests_coach_idx
  on public.coach_requests (coach_id, created_at desc);

alter table public.coach_requests enable row level security;

drop policy if exists coach_requests_select on public.coach_requests;
create policy coach_requests_select
  on public.coach_requests
  for select
  to authenticated
  using (
    public.is_owner()
    or coach_id = auth.uid()
  );

revoke insert, update, delete on table public.coach_requests from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Applications
-- ---------------------------------------------------------------------------

create table if not exists public.coach_applications (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  status text not null default 'pending',
  first_name text not null,
  last_name text not null,
  email text not null,
  birthday date,
  phone text,
  pitch text,
  bio text,
  location_name text,
  location_address text,
  location_checks jsonb not null default '{}'::jsonb,
  clip_path text,
  document_paths jsonb not null default '[]'::jsonb,
  before_after_paths jsonb not null default '[]'::jsonb,
  location_photo_paths jsonb not null default '[]'::jsonb,
  decided_by uuid,
  decided_at timestamptz,
  decision_note text,
  constraint coach_applications_status_chk check (status in ('pending', 'approved', 'denied'))
);

create index if not exists coach_applications_status_idx
  on public.coach_applications (status, created_at desc);

alter table public.coach_applications enable row level security;

drop policy if exists coach_applications_owner_select on public.coach_applications;
create policy coach_applications_owner_select
  on public.coach_applications
  for select
  to authenticated
  using (public.is_owner());

revoke insert, update, delete on table public.coach_applications from public, anon, authenticated;

insert into storage.buckets (id, name, public)
values ('coach-applications', 'coach-applications', false)
on conflict (id) do nothing;

drop policy if exists coach_applications_owner_read on storage.objects;
create policy coach_applications_owner_read
  on storage.objects
  for select
  to authenticated
  using (bucket_id = 'coach-applications' and public.is_owner());

-- A coach can put a client on any session, including another coach's.
-- They still cannot change attendance on a session that is not theirs.
drop policy if exists bookings_insert_self_or_staff on public.bookings;
create policy bookings_insert_self_or_staff
  on public.bookings
  for insert
  to authenticated
  with check (
    client_id = auth.uid()
    or trainer_id = auth.uid()
    or public.current_user_role() = 'owner'
    or public.current_user_role() = 'coach'
  );

-- ---------------------------------------------------------------------------
-- Coaches cannot flip a freeze or a restriction themselves
-- ---------------------------------------------------------------------------

create or replace function public.guard_coach_gated_client_fields()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.role() = 'service_role' or public.current_user_role() = 'owner' then
    return new;
  end if;
  new.membership_paused := old.membership_paused;
  new.membership_paused_at := old.membership_paused_at;
  new.membership_paused_days := old.membership_paused_days;
  new.membership_freeze_ends_at := old.membership_freeze_ends_at;
  new.booking_restricted := old.booking_restricted;
  new.booking_restricted_reason := old.booking_restricted_reason;
  new.booking_restricted_at := old.booking_restricted_at;
  return new;
end;
$function$;

drop trigger if exists guard_coach_gated_client_fields on public.clients;
create trigger guard_coach_gated_client_fields
  before update on public.clients
  for each row
  execute function public.guard_coach_gated_client_fields();

create or replace function public.block_restricted_client_booking()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.role() = 'service_role' or public.current_user_role() = 'owner' then
    return new;
  end if;
  if exists (
    select 1 from public.clients
    where profile_id = new.client_id
      and booking_restricted
  ) then
    raise exception 'This client is restricted from booking until the owner lifts it.';
  end if;
  return new;
end;
$function$;

drop trigger if exists block_restricted_client_booking on public.bookings;
create trigger block_restricted_client_booking
  before insert on public.bookings
  for each row
  execute function public.block_restricted_client_booking();

-- ---------------------------------------------------------------------------
-- One free add per coach per week. Free adds do not count toward pay.
-- This replaces book_single_session. The booking it creates is unchanged,
-- except for the pay flag and the weekly cap.
-- ---------------------------------------------------------------------------

create or replace function public.book_single_session(
  p_credit_id uuid,
  p_trainer_id uuid,
  p_date date,
  p_slot integer,
  p_session_type text,
  p_discipline text,
  p_location_name text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  c public.single_session_credits%rowtype;
  new_id uuid := gen_random_uuid();
  creator_role text;
  week_start date;
  used_count integer;
  pay_it boolean := true;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_trainer_id::text || p_date::text || p_slot::text, 0));
  select * into c from public.single_session_credits where id = p_credit_id for update;
  if not found then return jsonb_build_object('status', 'error', 'message', 'Credit not found.'); end if;
  if c.status = 'refunded' then return jsonb_build_object('status', 'error', 'message', 'This session was refunded.'); end if;
  if c.booking_id is not null then
    return jsonb_build_object('status', 'booked', 'booking_id', c.booking_id);
  end if;

  if c.source = 'staff_free' then
    pay_it := false;
    select role into creator_role from public.profiles where id = c.created_by;
    if creator_role is distinct from 'owner' then
      week_start := date_trunc('week', timezone('America/Los_Angeles', now()))::date;
      select count(*) into used_count
      from public.single_session_credits sc
      join public.bookings b on b.plan_id = 'single:' || sc.id::text
      where sc.source = 'staff_free'
        and sc.created_by = c.created_by
        and sc.id <> c.id
        and sc.purchased_at >= (week_start::timestamp at time zone 'America/Los_Angeles')
        and sc.purchased_at < ((week_start + 7)::timestamp at time zone 'America/Los_Angeles');
      if used_count >= 1 then
        return jsonb_build_object(
          'status', 'error',
          'code', 'FREE_ADD_LIMIT',
          'message', 'This coach already used the one free session add for this week. Ask the owner to approve another.'
        );
      end if;
    end if;
  end if;

  begin
    insert into public.bookings (
      id, client_id, trainer_id, date, slot_min, session_type, discipline, location, plan_id, counts_toward_pay
    )
    values (
      new_id, c.client_id, p_trainer_id, p_date, p_slot, p_session_type, p_discipline,
      case when p_location_name is null or p_location_name = '' then null else jsonb_build_object('name', p_location_name) end,
      'single:' || p_credit_id::text,
      pay_it
    );
  exception
    when others then
      if sqlerrm like '%capacity%' or sqlerrm like '%overlaps%' or sqlerrm like '%restricted%' then
        return jsonb_build_object('status', 'full', 'message', sqlerrm);
      end if;
      return jsonb_build_object('status', 'error', 'message', sqlerrm);
  end;

  return jsonb_build_object('status', 'booked', 'booking_id', new_id);
end;
$function$;

-- How many free adds the signed-in coach has already used this week.
create or replace function public.coach_free_adds_used()
returns integer
language sql
stable
security definer
set search_path to 'public'
as $function$
  select count(*)::integer
  from public.single_session_credits sc
  join public.bookings b on b.plan_id = 'single:' || sc.id::text
  where sc.source = 'staff_free'
    and sc.created_by = auth.uid()
    and sc.purchased_at >= (
      date_trunc('week', timezone('America/Los_Angeles', now()))::date::timestamp
      at time zone 'America/Los_Angeles'
    )
    and sc.purchased_at < (
      (date_trunc('week', timezone('America/Los_Angeles', now()))::date + 7)::timestamp
      at time zone 'America/Los_Angeles'
    );
$function$;

revoke all on function public.coach_free_adds_used() from public, anon;
grant execute on function public.coach_free_adds_used() to authenticated;

-- ---------------------------------------------------------------------------
-- Submit and decide
-- ---------------------------------------------------------------------------

create or replace function public.submit_coach_request(
  p_kind text,
  p_client uuid,
  p_reason text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid := auth.uid();
  new_id uuid;
  owners jsonb;
  trimmed text := btrim(coalesce(p_reason, ''));
begin
  if public.current_user_role() is distinct from 'coach' then
    raise exception 'Only a coach sends a request. The owner can do this directly.';
  end if;
  if p_kind not in (
    'freeze_membership', 'unfreeze_membership', 'restrict_client', 'lift_restriction',
    'extra_free_session', 'adjust_balance', 'delete_client'
  ) then
    raise exception 'That request type is not one the owner reviews.';
  end if;
  if p_client is null then
    raise exception 'Pick the client this request is about.';
  end if;
  if not exists (select 1 from public.profiles where id = p_client and role = 'client') then
    raise exception 'That client was not found.';
  end if;
  if p_kind in ('freeze_membership', 'restrict_client', 'adjust_balance', 'delete_client')
     and trimmed = '' then
    raise exception 'Add a reason so the owner can decide.';
  end if;
  if p_kind = 'freeze_membership' then
    if coalesce(p_payload->>'from', '') = '' or coalesce(p_payload->>'to', '') = '' then
      raise exception 'A freeze needs a from date and a to date.';
    end if;
    if (p_payload->>'to') <= (p_payload->>'from') then
      raise exception 'The end date must be after the start date.';
    end if;
  end if;
  if p_kind = 'extra_free_session' then
    if coalesce(p_payload->>'trainerId', '') = ''
       or coalesce(p_payload->>'date', '') = ''
       or p_payload->>'slot' is null
       or coalesce(p_payload->>'sessionType', '') = '' then
      raise exception 'The free-session request is missing the session.';
    end if;
  end if;
  if p_kind = 'adjust_balance' and p_payload->>'cents' is null then
    raise exception 'Enter the balance you are asking for.';
  end if;
  if exists (
    select 1 from public.coach_requests
    where coach_id = me
      and client_id = p_client
      and kind = p_kind
      and status = 'pending'
  ) then
    raise exception 'You already have a request like this waiting on the owner.';
  end if;

  insert into public.coach_requests (coach_id, client_id, kind, reason, payload)
  values (me, p_client, p_kind, nullif(trimmed, ''), coalesce(p_payload, '{}'::jsonb))
  returning id into new_id;

  select coalesce(jsonb_agg(id), '[]'::jsonb)
    into owners
  from public.profiles
  where role = 'owner' and deleted_at is null;

  return jsonb_build_object('id', new_id, 'ownerIds', owners);
end;
$function$;

revoke all on function public.submit_coach_request(text, uuid, text, jsonb) from public, anon;
grant execute on function public.submit_coach_request(text, uuid, text, jsonb) to authenticated;

create or replace function public.decide_coach_request(
  p_id uuid,
  p_approve boolean,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r public.coach_requests%rowtype;
  starts_at timestamptz;
  cents integer;
begin
  if public.current_user_role() is distinct from 'owner' then
    raise exception 'Only the owner can approve or deny a request.';
  end if;

  select * into r from public.coach_requests where id = p_id for update;
  if not found then
    raise exception 'That request was not found.';
  end if;
  if r.status = 'approved' and r.applied_at is null and p_approve then
    return jsonb_build_object(
      'id', r.id, 'kind', r.kind, 'status', 'approved',
      'coachId', r.coach_id, 'clientId', r.client_id,
      'reason', r.reason, 'payload', r.payload, 'effectiveAt', r.effective_at
    );
  end if;
  if r.status <> 'pending' then
    raise exception 'This request was already decided.';
  end if;

  if not p_approve then
    update public.coach_requests
       set status = 'denied',
           decided_by = auth.uid(),
           decided_at = now(),
           decision_note = nullif(btrim(coalesce(p_note, '')), '')
     where id = r.id;
    return jsonb_build_object(
      'id', r.id, 'kind', r.kind, 'status', 'denied',
      'coachId', r.coach_id, 'clientId', r.client_id, 'payload', r.payload
    );
  end if;

  starts_at := null;
  if r.kind = 'freeze_membership' then
    starts_at := greatest(
      ((r.payload->>'from')::date::timestamp at time zone 'America/Los_Angeles'),
      now() + interval '48 hours'
    );
  elsif r.kind = 'restrict_client' then
    update public.clients
       set booking_restricted = true,
           booking_restricted_reason = r.reason,
           booking_restricted_at = now()
     where profile_id = r.client_id;
  elsif r.kind = 'lift_restriction' then
    update public.clients
       set booking_restricted = false,
           booking_restricted_reason = null,
           booking_restricted_at = null
     where profile_id = r.client_id;
  elsif r.kind = 'adjust_balance' then
    cents := (r.payload->>'cents')::integer;
    update public.clients
       set balance_cents = cents
     where profile_id = r.client_id;
  end if;

  update public.coach_requests
     set status = 'approved',
         decided_by = auth.uid(),
         decided_at = now(),
         decision_note = nullif(btrim(coalesce(p_note, '')), ''),
         effective_at = starts_at,
         applied_at = case
           when r.kind in ('restrict_client', 'lift_restriction', 'adjust_balance', 'unfreeze_membership')
             then now()
           else null
         end
   where id = r.id;

  return jsonb_build_object(
    'id', r.id,
    'kind', r.kind,
    'status', 'approved',
    'coachId', r.coach_id,
    'clientId', r.client_id,
    'reason', r.reason,
    'payload', r.payload,
    'effectiveAt', starts_at
  );
end;
$function$;

revoke all on function public.decide_coach_request(uuid, boolean, text) from public, anon;
grant execute on function public.decide_coach_request(uuid, boolean, text) to authenticated;

create or replace function public.mark_request_applied(p_id uuid, p_booking uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.role() is distinct from 'service_role'
     and public.current_user_role() is distinct from 'owner' then
    raise exception 'Only the owner can finish a request.';
  end if;
  update public.coach_requests
     set applied_at = now(),
         payload = payload || case
           when p_booking is null then '{}'::jsonb
           else jsonb_build_object('bookingId', p_booking)
         end
   where id = p_id
     and status = 'approved';
end;
$function$;

revoke all on function public.mark_request_applied(uuid, uuid) from public, anon;
grant execute on function public.mark_request_applied(uuid, uuid) to authenticated, service_role;

-- Freezes the owner already approved, whose 48 hours (and from-date) have passed.
create or replace function public.due_freeze_requests()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
begin
  if auth.role() is distinct from 'service_role'
     and public.current_user_role() is distinct from 'owner' then
    raise exception 'Only the owner can apply freezes.';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', id,
      'clientId', client_id,
      'coachId', coach_id,
      'from', payload->>'from',
      'to', payload->>'to'
    )), '[]'::jsonb)
    from public.coach_requests
    where kind = 'freeze_membership'
      and status = 'approved'
      and applied_at is null
      and effective_at is not null
      and effective_at <= now()
  );
end;
$function$;

revoke all on function public.due_freeze_requests() from public, anon;
grant execute on function public.due_freeze_requests() to authenticated, service_role;

create or replace function public.owner_set_client_restriction(
  p_client uuid,
  p_restricted boolean,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if public.current_user_role() is distinct from 'owner' then
    raise exception 'Only the owner can restrict a client directly.';
  end if;
  update public.clients
     set booking_restricted = p_restricted,
         booking_restricted_reason = case when p_restricted then nullif(btrim(coalesce(p_reason, '')), '') else null end,
         booking_restricted_at = case when p_restricted then now() else null end
   where profile_id = p_client;
end;
$function$;

revoke all on function public.owner_set_client_restriction(uuid, boolean, text) from public, anon;
grant execute on function public.owner_set_client_restriction(uuid, boolean, text) to authenticated;

notify pgrst, 'reload schema';
