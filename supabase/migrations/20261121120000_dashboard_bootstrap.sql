-- One read for the home screen. Not applied by this change.
-- Apply it when you want the cold open to be a single round trip.
-- Until then the app uses the existing queries.
--
-- security definer, so the filters below are the privacy boundary.
-- A client receives their own email and phone, coach names (never a legal
-- name), and no one else's email or phone. Coaches and the owner keep the
-- access they already have from profile_directory and profile_contact_for.

create or replace function public.dashboard_bootstrap(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  uid uuid := auth.uid();
  role text;
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
  role := public.current_user_role();
  if role is null or role not in ('client', 'coach', 'owner') then
    raise exception 'not signed in';
  end if;

  select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb)
    into directory
  from public.profile_directory() d
  where d.deleted_at is null
    and (
      role = 'owner'
      or d.id = uid
      or d.role = 'coach'
      or d.role = 'owner'
      or (
        role = 'coach'
        and d.role = 'client'
        and exists (
          select 1 from public.clients c
          where c.profile_id = d.id
            and (
              c.primary_trainer_id = uid
              or c.referred_by_trainer_id = uid
              or exists (
                select 1 from public.bookings b
                where b.client_id = c.profile_id and b.trainer_id = uid
              )
            )
        )
      )
    );

  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'email', c.email, 'phone', c.phone)), '[]'::jsonb)
    into contacts
  from public.profile_contact_for(
    case
      when role = 'owner' then (
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
    role = 'client' and c.profile_id = uid
  ) or (
    role = 'coach' and (
      c.primary_trainer_id = uid
      or c.referred_by_trainer_id = uid
      or exists (
        select 1 from public.bookings b
        where b.client_id = c.profile_id and b.trainer_id = uid
      )
    )
  ) or role = 'owner';

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
      role = 'owner'
      or (role = 'client' and b.client_id = uid)
      or (role = 'coach' and b.trainer_id = uid)
    );

  if role = 'client' then
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
    where role = 'owner'
      or exists (
        select 1 from public.clients c
        where c.profile_id = r.profile_id
          and (
            c.primary_trainer_id = uid
            or c.referred_by_trainer_id = uid
            or exists (
              select 1 from public.bookings b
              where b.client_id = c.profile_id and b.trainer_id = uid
            )
          )
      );
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

  if role = 'client' then
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
  where role = 'owner' or q.coach_id = uid;

  select coalesce(jsonb_agg(jsonb_build_object('client_id', l.client_id, 'day_id', l.day_id)), '[]'::jsonb)
    into live_days
  from public.live_day_runs l
  where l.ended_at is null
    and (
      role = 'owner'
      or (role = 'coach' and exists (
        select 1 from public.clients c
        where c.profile_id = l.client_id and c.primary_trainer_id = uid
      ))
    );

  if role = 'owner' then
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
    'role', role,
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

create index if not exists bookings_date_idx on public.bookings (date);
create index if not exists bookings_client_date_idx on public.bookings (client_id, date);
create index if not exists bookings_trainer_date_idx on public.bookings (trainer_id, date);
create index if not exists merit_badges_client_idx on public.merit_badges (client_id);
create index if not exists live_day_runs_open_idx on public.live_day_runs (client_id) where ended_at is null;

notify pgrst, 'reload schema';
