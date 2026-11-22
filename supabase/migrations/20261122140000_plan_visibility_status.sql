-- Plan visibility: active, ghost, archived.
-- Not applied to the live database by this change. Do not run it here.
-- Apply it before any plan is marked ghost. Until it is applied, a ghost
-- write is only a jsonb field and installed clients can still read the row.
--
-- Ghost is hidden from client catalog reads:
--   * SELECT on membership_plans hides ghost rows from a client who does
--     not hold that plan. A client can select a ghost plan they hold
--     (membership slot, pending switch, or an active enrollment) so a
--     plan reload still finds it. Everyone else still cannot see it.
--     Purchase of a ghost plan stays refused in the checkout functions.
--   * dashboard_bootstrap is security definer, so it bypasses that policy.
--     For a client it omits ghost plans they do not hold. A ghost plan they
--     do hold comes back with archived set true in the payload only, which
--     is what 1.1.3 uses to keep a plan off the storefront. Their current
--     plan card looks the plan up by id and still shows it.
--   * my_held_plan_rows returns only the caller's own ghost plans, with the
--     stored row unchanged, for the app version that filters on status.
--
-- archived stays the boolean it always was. Ghost does not set it. Existing
-- rows get status from that flag. A trigger keeps the two in step when an
-- older app writes only the flag.

create or replace function public.plan_visibility(p_data jsonb)
returns text
language sql
immutable
as $$
  select case
    when lower(btrim(coalesce(p_data->>'status', ''))) in ('active', 'ghost', 'archived')
      then lower(btrim(p_data->>'status'))
    when p_data->>'archived' in ('true', 't') then 'archived'
    else 'active'
  end;
$$;

comment on function public.plan_visibility(jsonb) is
  'active, ghost, or archived. Missing status follows the archived flag.';

revoke all on function public.plan_visibility(jsonb) from public, anon;
grant execute on function public.plan_visibility(jsonb) to authenticated, service_role;

-- True when this client currently holds the plan: the membership slot,
-- a pending switch, or an active enrollment. Used to return a held ghost
-- plan to its owner without listing it for everyone else.
create or replace function public.client_holds_plan(p_uid uuid, p_plan_id text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    p_uid is not null
    and p_plan_id is not null
    and (
      p_uid = auth.uid()
      or auth.role() = 'service_role'
      or public.current_user_role() in ('owner', 'coach')
    )
    and exists (
      select 1
      from public.clients c
      where c.profile_id = p_uid
        and (
          c.membership_plan_id = p_plan_id
          or c.pending_plan_id = p_plan_id
          or (
            jsonb_typeof(c.plans) = 'array'
            and exists (
              select 1
              from jsonb_array_elements(c.plans) e
              where e->>'planId' = p_plan_id
                and coalesce(e->>'status', 'active') = 'active'
            )
          )
        )
    );
$$;

revoke all on function public.client_holds_plan(uuid, text) from public, anon;
grant execute on function public.client_holds_plan(uuid, text) to authenticated, service_role;

create or replace function public.sync_membership_plan_visibility()
returns trigger
language plpgsql
as $$
declare
  prev jsonb := coalesce(old.data, '{}'::jsonb);
  next jsonb := coalesce(new.data, '{}'::jsonb);
  prev_status text := public.plan_visibility(prev);
  next_status text := lower(btrim(coalesce(next->>'status', '')));
  prev_archived boolean := coalesce(prev->>'archived', '') in ('true', 't');
  next_archived boolean := coalesce(next->>'archived', '') in ('true', 't');
  explicit boolean := next_status in ('active', 'ghost', 'archived');
  resolved text;
begin
  if explicit and next_status is distinct from prev_status then
    resolved := next_status;
  elsif next_archived is distinct from prev_archived then
    resolved := case when next_archived then 'archived' else 'active' end;
  elsif explicit then
    resolved := next_status;
  else
    resolved := case when next_archived then 'archived' else 'active' end;
  end if;
  new.data := next || jsonb_build_object(
    'status', resolved,
    'archived', to_jsonb(resolved = 'archived')
  );
  return new;
end;
$$;

drop trigger if exists membership_plans_sync_visibility on public.membership_plans;
create trigger membership_plans_sync_visibility
  before insert or update of data
  on public.membership_plans
  for each row
  execute function public.sync_membership_plan_visibility();

update public.membership_plans
set data = data || jsonb_build_object('status', public.plan_visibility(data))
where coalesce(data->>'status', '') not in ('active', 'ghost', 'archived');

drop policy if exists membership_plans_select_authenticated on public.membership_plans;
create policy membership_plans_select_authenticated
  on public.membership_plans
  for select
  to authenticated
  using (
    (select public.current_user_role()) in ('owner', 'coach')
    or public.plan_visibility(data) is distinct from 'ghost'
    or public.client_holds_plan(auth.uid(), id)
  );

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

  -- Clients never receive another person's ghost plan. A ghost plan this
  -- client already holds is returned with archived forced true, so app
  -- 1.1.3 (which only knows that flag) keeps it off the storefront and
  -- still shows it as the current plan. The stored row is not changed.
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'data', case
      when v_role = 'client' and public.plan_visibility(m.data) = 'ghost'
      then m.data || jsonb_build_object('archived', true)
      else m.data
    end
  )), '[]'::jsonb)
    into plan_rows
  from public.membership_plans m
  where v_role in ('owner', 'coach')
     or public.plan_visibility(m.data) is distinct from 'ghost'
     or public.client_holds_plan(uid, m.id);

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

-- The signed-in client's own ghost plans, and nothing else. Staff already
-- see every plan through the table policy, so this returns an empty list
-- for them. The stored archived flag is not rewritten.
create or replace function public.my_held_plan_rows()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  if public.current_user_role() is distinct from 'client' then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', m.id, 'data', m.data))
    from public.membership_plans m
    where public.plan_visibility(m.data) = 'ghost'
      and public.client_holds_plan(uid, m.id)
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.my_held_plan_rows() from public, anon;
grant execute on function public.my_held_plan_rows() to authenticated, service_role;

notify pgrst, 'reload schema';
