-- Clients have no assigned coach.
-- Every coach can access every client, and every client can access every coach.
-- Role checks stay: owner, coach, and client. Privacy stays: coaches see city
-- and state, not a phone number or a street address; clients see coach names
-- only; only the owner can override a balance block.
-- primary_trainer_id is still stored and still returned. Nothing below gates on it.
-- Not applied to the live database by this change.
-- Billing-address writes are left for the billing change. This file does not replace them.

create or replace function public.dashboard_bootstrap(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  uid uuid := auth.uid();
  v_role text;
  start_on date := coalesce(p_from, (current_date - 14));
  end_on date := coalesce(p_to, (current_date + 14));
  directory jsonb;
  contacts jsonb;
  client_rows jsonb;
  trainer_rows jsonb;
  booking_rows jsonb;
  record_rows jsonb;
  own_record jsonb;
  plan_rows jsonb;
  waiver_rows jsonb;
  settings jsonb;
  badges jsonb;
  nudges jsonb;
  live_days jsonb;
  charges jsonb;
  balance integer;
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  v_role := public.current_user_role();
  if v_role is null or v_role not in ('client', 'coach', 'owner') then
    raise exception 'not signed in';
  end if;

  select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb)
    into directory
  from public.profile_directory() d
  where d.deleted_at is null
    and (
      v_role = 'owner'
      or d.id = uid
      or d.role = 'coach'
      or d.role = 'owner'
      or (
        v_role = 'coach'
        and d.role = 'client'
      )
    );

  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'email', c.email, 'phone', c.phone)), '[]'::jsonb)
    into contacts
  from public.profile_contact_for(
    case
      when v_role = 'owner' then (
        select coalesce(array_agg(p.id), array[]::uuid[]) from public.profiles p where p.deleted_at is null
      )
      else array[uid]
    end
  ) c;

  select coalesce(jsonb_agg(jsonb_build_object(
    'profile_id', c.profile_id,
    'birthday', c.birthday,
    'city', c.city,
    'state', c.state,
    'home_lat', c.home_lat,
    'home_lng', c.home_lng,
    'membership_plan_id', c.membership_plan_id,
    'primary_trainer_id', c.primary_trainer_id,
    'plans', c.plans,
    'tour_seen', c.tour_seen,
    'membership_paused', c.membership_paused,
    'membership_paused_at', c.membership_paused_at,
    'membership_paused_days', c.membership_paused_days,
    'custom_fields', c.custom_fields,
    'membership_freeze_ends_at', c.membership_freeze_ends_at,
    'session_count_override', c.session_count_override,
    'pending_plan_id', c.pending_plan_id,
    'pending_plan_effective_at', c.pending_plan_effective_at,
    'session_count_override_month', c.session_count_override_month,
    'membership_cancels_at', c.membership_cancels_at,
    'referred_by_trainer_id', c.referred_by_trainer_id,
    'coach_code_alert_seen', c.coach_code_alert_seen,
    'sms_opt_in', c.sms_opt_in,
    'emergency_contact_name', c.emergency_contact_name,
    'booking_restricted', c.booking_restricted,
    'booking_restricted_reason', c.booking_restricted_reason
  )), '[]'::jsonb)
    into client_rows
  from public.clients c
  where (
    v_role = 'client' and c.profile_id = uid
  ) or v_role in ('coach', 'owner');

  select coalesce(jsonb_agg(jsonb_build_object(
    'profile_id', t.profile_id,
    'disciplines', t.disciplines,
    'session_types', t.session_types,
    'slot_interval', t.slot_interval,
    'availability', t.availability,
    'locations', t.locations,
    'coach_code', t.coach_code,
    'unavailability', t.unavailability,
    'title', t.title,
    'coach_name', t.coach_name
  )), '[]'::jsonb)
    into trainer_rows
  from public.trainers t
  join public.profiles p on p.id = t.profile_id
  where p.deleted_at is null and p.role = 'coach';

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id,
    'client_id', b.client_id,
    'trainer_id', b.trainer_id,
    'date', b.date,
    'slot_min', b.slot_min,
    'session_type', b.session_type,
    'discipline', b.discipline,
    'attendance_status', b.attendance_status,
    'client_started_at', b.client_started_at,
    'location', b.location,
    'is_physical_assessment', b.is_physical_assessment,
    'overridden_by', b.overridden_by,
    'overridden_at', b.overridden_at,
    'override_reason', b.override_reason,
    'plan_id', b.plan_id,
    'duration_min', b.duration_min,
    'counts_toward_pay', b.counts_toward_pay,
    'cancelled_at', b.cancelled_at
  )), '[]'::jsonb)
    into booking_rows
  from public.bookings b
  where b.date between start_on and end_on
    and (
      v_role = 'owner'
      or (v_role = 'client' and b.client_id = uid)
      or (v_role = 'coach' and b.trainer_id = uid)
    );

  if v_role = 'client' then
    select r.data into own_record
    from public.client_records r
    where r.profile_id = uid;
    record_rows := '[]'::jsonb;
  else
    own_record := null;
    select coalesce(jsonb_agg(jsonb_build_object(
      'profile_id', r.profile_id,
      'savedPrograms', r.data->'savedPrograms',
      'nutrition', r.data->'nutrition',
      'trainerNotes', r.data->'trainerNotes',
      'programRefresh', r.data->'programRefresh'
    )), '[]'::jsonb)
      into record_rows
    from public.client_records r
    where v_role in ('owner', 'coach');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'data', m.data)), '[]'::jsonb)
    into plan_rows
  from public.membership_plans m;

  select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'data', w.data)), '[]'::jsonb)
    into waiver_rows
  from public.waiver_docs w;

  select s.data into settings
  from public.platform_settings s
  where s.id = 'global';

  if v_role = 'client' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', mb.id,
      'client_id', mb.client_id,
      'badge_key', mb.badge_key,
      'earned_at', mb.earned_at,
      'earned_method', mb.earned_method,
      'granted_by_user_id', mb.granted_by_user_id,
      'note', mb.note,
      'revoked_at', mb.revoked_at,
      'revoked_by_user_id', mb.revoked_by_user_id,
      'celebrated_at', mb.celebrated_at
    )), '[]'::jsonb)
      into badges
    from public.merit_badges mb
    where mb.client_id = uid;
  else
    badges := '[]'::jsonb;
  end if;

  select b.balance_cents into balance
  from public.client_balances_for(array[uid]) b
  limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'client_id', q.client_id,
    'last_activity_on', q.last_activity_on,
    'text_sent_on', q.text_sent_on,
    'coach_id', q.coach_id
  )), '[]'::jsonb)
    into nudges
  from public.quiet_nudges q
  where v_role = 'owner' or q.coach_id = uid;

  select coalesce(jsonb_agg(jsonb_build_object('client_id', l.client_id, 'day_id', l.day_id)), '[]'::jsonb)
    into live_days
  from public.live_day_runs l
  where l.ended_at is null
    and v_role in ('owner', 'coach');

  if v_role = 'owner' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', ch.id,
      'client_id', ch.client_id,
      'client_name', ch.client_name,
      'type', ch.type,
      'date', ch.date,
      'at', ch.at,
      'amount', ch.amount,
      'category', ch.category,
      'description', ch.description,
      'plan_id', ch.plan_id,
      'plan_name', ch.plan_name,
      'trainer_id', ch.trainer_id,
      'trainer_name', ch.trainer_name,
      'waived_at', ch.waived_at
    )), '[]'::jsonb)
      into charges
    from public.charges ch
    where ch.date::text = current_date::text;
  else
    charges := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'role', v_role,
    'directory', directory,
    'contacts', contacts,
    'clientRows', client_rows,
    'trainerRows', trainer_rows,
    'bookingRows', booking_rows,
    'recordRows', record_rows,
    'ownRecord', own_record,
    'planRows', plan_rows,
    'waiverRows', waiver_rows,
    'settings', settings,
    'badges', badges,
    'balanceCents', balance,
    'quietNudges', nudges,
    'liveDays', live_days,
    'charges', charges
  );
end;
$$;


revoke all on function public.dashboard_bootstrap(date, date) from public, anon;
grant execute on function public.dashboard_bootstrap(date, date) to authenticated, service_role;

-- Any coach works with any client. The client still works with their own rows.
-- The owner still works with every row. A coach must be a coach, and the
-- profile must be a client, so this does not open the tables to other roles.
create or replace function public.coach_works_with_client(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    public.is_owner()
    or auth.uid() = p_client
    or (
      public.current_user_role() = 'coach'
      and exists (
        select 1 from public.clients c
        where c.profile_id = p_client
      )
    );
$$;

revoke all on function public.coach_works_with_client(uuid) from public, anon;
grant execute on function public.coach_works_with_client(uuid) to authenticated, service_role;

-- A coach may message every client. The owner may too. A client may not call this.
create or replace function public.broadcast_allowed_clients(p_sender uuid)
returns table (client_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  sender_role text;
begin
  select p.role into sender_role
  from public.profiles p
  where p.id = p_sender
    and p.deleted_at is null;

  if sender_role in ('owner', 'coach') then
    return query
      select p.id
      from public.profiles p
      where p.role = 'client'
        and p.deleted_at is null;
  end if;
end;
$$;

revoke all on function public.broadcast_allowed_clients(uuid) from public, anon, authenticated;
grant execute on function public.broadcast_allowed_clients(uuid) to service_role;

-- On file, or not. Never the phone number and never the street.
-- Any coach may ask. The client and the owner may ask.
create or replace function public.client_file_flags(p_client uuid)
returns table (phone_on_file boolean, billing_on_file boolean)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  phone text;
  addr jsonb;
begin
  select nullif(btrim(p.phone), ''), c.billing_address
    into phone, addr
  from public.clients c
  join public.profiles p on p.id = c.profile_id
  where c.profile_id = p_client;

  if auth.role() is distinct from 'service_role'
     and p_client is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner'
     and public.current_user_role() is distinct from 'coach' then
    raise exception 'Not allowed.';
  end if;

  phone_on_file := phone is not null;
  billing_on_file := coalesce(addr->>'line1', '') <> '';
  return next;
end;
$$;

revoke all on function public.client_file_flags(uuid) from public, anon;
grant execute on function public.client_file_flags(uuid) to authenticated, service_role;

-- A coach may enter a phone and may not read it back. Any coach, any client.
create or replace function public.set_client_phone(p_client uuid, p_phone text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  digits text;
begin
  if auth.role() is distinct from 'service_role'
     and p_client is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner'
     and public.current_user_role() is distinct from 'coach' then
    raise exception 'Not allowed to update that phone.';
  end if;
  if public.current_user_role() = 'coach'
     and not exists (select 1 from public.clients c where c.profile_id = p_client) then
    raise exception 'Not allowed to update that phone.';
  end if;
  digits := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  if length(digits) < 7 then
    raise exception 'Enter a phone number.';
  end if;
  update public.profiles set phone = btrim(p_phone) where id = p_client;
end;
$$;

revoke all on function public.set_client_phone(uuid, text) from public, anon;
grant execute on function public.set_client_phone(uuid, text) to authenticated, service_role;

-- Amounts only. Any coach may read any client's ledger and balance.
create or replace function public.client_ledger_for(p_client uuid)
returns table (
  id uuid,
  fee_type text,
  amount_cents integer,
  booking_id uuid,
  created_by uuid,
  status text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    l.id,
    l.fee_type,
    l.amount_cents,
    l.booking_id,
    l.created_by,
    l.status,
    l.created_at
  from public.client_balance_ledger l
  where l.client_id = p_client
    and (
      l.client_id = auth.uid()
      or public.is_owner()
      or public.current_user_role() = 'coach'
    );
$$;

revoke all on function public.client_ledger_for(uuid) from public, anon;
grant execute on function public.client_ledger_for(uuid) to authenticated, service_role;

create or replace function public.client_balances_for(p_ids uuid[])
returns table (profile_id uuid, balance_cents integer)
language sql
stable
security definer
set search_path to 'public'
as $$
  select c.profile_id, coalesce(c.balance_cents, 0)
  from public.clients c
  where c.profile_id = any (coalesce(p_ids, array[]::uuid[]))
    and (
      c.profile_id = auth.uid()
      or public.is_owner()
      or public.current_user_role() = 'coach'
    );
$$;

revoke all on function public.client_balances_for(uuid[]) from public, anon;
grant execute on function public.client_balances_for(uuid[]) to authenticated, service_role;

-- The assignment clause here did not limit access, because any coach was
-- already allowed. It is removed so the function does not read primary_trainer_id.
create or replace function public.client_booking_hold(p_client uuid)
returns table (balance_cents integer, grace_booking_used boolean)
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(c.balance_cents, 0), coalesce(c.grace_booking_used, false)
  from public.clients c
  where c.profile_id = p_client
    and (
      c.profile_id = auth.uid()
      or public.is_owner()
      or public.current_user_role() = 'coach'
    );
$$;

revoke all on function public.client_booking_hold(uuid) from public, anon;
grant execute on function public.client_booking_hold(uuid) to authenticated, service_role;

-- Sharing stays off until the client turns it on. When it is on, every coach
-- and the owner can read it. Not one assigned coach.
create or replace function public.health_shared_with_me(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1
    from public.health_connections h
    where h.client_id = p_client
      and h.share_with_coach
      and (
        public.is_owner()
        or public.current_user_role() = 'coach'
      )
  );
$$;

revoke all on function public.health_shared_with_me(uuid) from public, anon;
grant execute on function public.health_shared_with_me(uuid) to authenticated, service_role;

-- A client reads their own Merit Badges. Any coach reads every client's.
-- The owner reads everything. Coach badges and PR rows stay the coach's own.
drop policy if exists merit_badges_select_scoped on public.merit_badges;
create policy merit_badges_select_scoped on public.merit_badges
  for select to authenticated
  using (
    client_id = (select auth.uid())
    or public.current_user_role() = 'owner'
    or public.current_user_role() = 'coach'
  );

-- Who gets the quiet-client notice. Last coach they messaged, otherwise the
-- coach on their latest booking. No assigned coach. If neither exists, the
-- notice has no single coach.
create or replace function public.quiet_nudge_roster(p_today date)
returns table (
  client_id uuid,
  first_name text,
  phone text,
  may_text boolean,
  last_activity_on date,
  quiet_days integer,
  push_sent boolean,
  text_sent boolean,
  coach_id uuid
)
language plpgsql
set search_path to 'public'
as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Not allowed.';
  end if;

  return query
  select
    p.id,
    nullif(btrim(coalesce(nullif(btrim(p.first_name), ''), split_part(btrim(p.name), ' ', 1))), ''),
    nullif(btrim(p.phone), ''),
    (
      c.sms_opt_in is true
      and c.marketing_opt_out is not true
      and p.sms_opted_out is not true
      and (
        c.sms_opt_in_at is not null
        or nullif(btrim(c.sms_consent_text), '') is not null
        or p.sms_consent_at is not null
      )
      and nullif(btrim(p.phone), '') is not null
    ),
    logged.last_on,
    (p_today - logged.last_on)::integer,
    (q.push_sent_on is not null and q.last_activity_on = logged.last_on),
    (q.text_sent_on is not null and q.last_activity_on = logged.last_on),
    coalesce(chat.coach, booked.coach)
  from public.profiles p
  join public.clients c on c.profile_id = p.id
  left join public.client_records cr on cr.profile_id = p.id
  left join public.quiet_nudges q on q.client_id = p.id
  cross join lateral (
    select public.client_last_log_on(cr.data, p.created_at) as last_on
  ) as logged
  left join lateral (
    select m.trainer_id as coach
    from public.messages m
    join public.profiles tp on tp.id = m.trainer_id
    where m.client_id = p.id
      and tp.role = 'coach'
      and tp.deleted_at is null
      and tp.banned_at is null
    order by m.created_at desc
    limit 1
  ) as chat on true
  left join lateral (
    select b.trainer_id as coach
    from public.bookings b
    join public.profiles tp on tp.id = b.trainer_id
    where b.client_id = p.id
      and b.cancelled_at is null
      and tp.role = 'coach'
      and tp.deleted_at is null
      and tp.banned_at is null
    order by b.date desc, b.slot_min desc
    limit 1
  ) as booked on true
  where p.role = 'client'
    and p.deleted_at is null
    and p.banned_at is null;
end;
$$;

revoke all on function public.quiet_nudge_roster(date) from public, anon, authenticated;
grant execute on function public.quiet_nudge_roster(date) to service_role;

notify pgrst, 'reload schema';
