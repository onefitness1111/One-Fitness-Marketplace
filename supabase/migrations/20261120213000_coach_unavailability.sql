-- Coach unavailability can cancel the sessions it covers.
-- Not applied to the live database. Do not run this from an automated job.
-- Apply this file in the SQL editor after 20261120185110_my_rated_booking_ids.sql,
-- then deploy the save-coach-unavailability edge function.
--
-- What a coach (or the owner, for any coach) can do:
-- 1. Add a block of time off. It can be one day or several, all day or
--    only some hours. The reason is shown to clients. A note is sent to
--    clients whose sessions are cancelled.
-- 2. Every session that overlaps that window is marked cancelled with
--    reason coach_unavailable. The session goes back on the client's
--    package or single-session credit. No card refund is issued.
-- 3. Each affected client gets one in-app chat message from the coach
--    (coach name only, or "your coach") containing the note. Push, and a
--    text for someone who already opted in, are sent by the edge function
--    after this succeeds. A retry of the same entry does not cancel,
--    credit, or message anyone again.
-- 4. Deleting the block lets clients book that time again. It does not
--    put cancelled sessions back.

alter table public.bookings
  add column if not exists cancel_reason text;

comment on column public.bookings.cancel_reason is
  'Why the row was cancelled. coach_unavailable means the coach blocked this time and the session was returned to the client.';

-- One row per saved block. A second call with the same entry id returns
-- the first result and does nothing else.
create table if not exists public.coach_unavailability_applies (
  entry_id text primary key,
  trainer_id uuid not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.coach_unavailability_applies enable row level security;
revoke all on public.coach_unavailability_applies from public, anon, authenticated;

create or replace function public.apply_coach_unavailability(
  p_trainer_id uuid,
  p_entry jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_role text;
  v_caller uuid;
  v_id text;
  v_start date;
  v_end date;
  v_all_day boolean;
  v_start_min integer;
  v_end_min integer;
  v_reason text;
  v_note text;
  v_entry jsonb;
  v_prev jsonb;
  v_coach text;
  b public.bookings%rowtype;
  v_updated integer;
  v_still_there boolean;
  v_ids jsonb := '[]'::jsonb;
  v_clients jsonb := '{}'::jsonb;
  v_client uuid;
  v_info jsonb;
  v_sessions integer;
  v_credit uuid;
  v_result jsonb;
begin
  v_caller := auth.uid();
  v_role := public.current_user_role();
  if v_role is distinct from 'owner'
     and not (v_role = 'coach' and v_caller = p_trainer_id) then
    raise exception 'You can only set unavailability for yourself.'
      using errcode = '42501';
  end if;

  if not exists (select 1 from public.trainers t where t.profile_id = p_trainer_id) then
    raise exception 'That coach was not found.';
  end if;

  v_id := nullif(btrim(p_entry->>'id'), '');
  if v_id is null or char_length(v_id) > 80 then
    raise exception 'A time-off entry needs an id.';
  end if;

  -- A second tap, or a retry after a lost response, must not cancel,
  -- credit, or message anyone again.
  perform pg_advisory_xact_lock(hashtextextended('unavail:' || v_id, 0));
  select result into v_prev
  from public.coach_unavailability_applies
  where entry_id = v_id;
  if found then
    return v_prev || jsonb_build_object('alreadyApplied', true, 'shouldNotify', false);
  end if;

  begin
    v_start := (p_entry->>'startDate')::date;
  exception when others then
    raise exception 'Choose a start date.';
  end;
  if v_start is null then
    raise exception 'Choose a start date.';
  end if;
  if nullif(btrim(p_entry->>'endDate'), '') is null then
    v_end := v_start;
  else
    begin
      v_end := (p_entry->>'endDate')::date;
    exception when others then
      raise exception 'That end date is not a real date.';
    end;
  end if;
  if v_end < v_start then
    raise exception 'The end date cannot be before the start date.';
  end if;

  v_start_min := nullif(p_entry->>'startMin', '')::integer;
  v_end_min := nullif(p_entry->>'endMin', '')::integer;
  v_all_day := coalesce((p_entry->>'allDay')::boolean, false) = true
    or (v_start_min is null and v_end_min is null);
  if v_all_day then
    v_start_min := null;
    v_end_min := null;
  else
    if v_start_min is null or v_start_min < 0 or v_start_min > 1439 then
      raise exception 'Choose a start time.';
    end if;
    if v_end_min is null then
      v_end_min := 24 * 60;
    elsif v_end_min <= v_start_min or v_end_min > 24 * 60 then
      raise exception 'The end time has to be after the start time.';
    end if;
  end if;

  v_reason := nullif(btrim(p_entry->>'reason'), '');
  if v_reason is null then
    v_reason := nullif(btrim(p_entry->>'note'), '');
  end if;
  if v_reason is null then
    raise exception 'A reason is required.';
  end if;
  if char_length(v_reason) > 80 then
    raise exception 'Keep the reason short.';
  end if;
  v_note := nullif(btrim(p_entry->>'clientNote'), '');
  if v_note is not null and char_length(v_note) > 500 then
    raise exception 'Keep the note to clients shorter.';
  end if;

  -- Lock the coach row, then the overlapping bookings, in id order.
  perform 1 from public.trainers where profile_id = p_trainer_id for update;

  if v_note is null and exists (
    select 1
    from public.bookings
    where trainer_id = p_trainer_id
      and cancelled_at is null
      and coalesce(attendance_status, '') not in ('checked-in', 'no-show', 'early-cancel', 'late-cancel')
      and date between v_start and v_end
      and (
        v_all_day
        or (
          v_start_min < (slot_min + coalesce(duration_min, 60))
          and v_end_min > slot_min
        )
      )
  ) then
    raise exception 'Write a note for the clients whose sessions will be cancelled.';
  end if;

  for b in
    select *
    from public.bookings
    where trainer_id = p_trainer_id
      and cancelled_at is null
      and coalesce(attendance_status, '') not in ('checked-in', 'no-show', 'early-cancel', 'late-cancel')
      and date between v_start and v_end
      and (
        v_all_day
        or (
          v_start_min < (slot_min + coalesce(duration_min, 60))
          and v_end_min > slot_min
        )
      )
    order by id
    for update
  loop
    -- Same history row a coach cancel writes, when that function is installed.
    -- A failure here does not stop the cancel. No card is refunded.
    begin
      perform public.archive_cancelled_booking(b.id);
    exception when others then
      raise warning 'archive_cancelled_booking skipped: %', sqlerrm;
    end;

    update public.bookings
       set cancelled_at = now(),
           cancel_reason = 'coach_unavailable'
     where id = b.id
       and cancelled_at is null;
    get diagnostics v_updated = row_count;

    if v_updated = 0 then
      select exists (select 1 from public.bookings where id = b.id) into v_still_there;
      if v_still_there then
        continue;
      end if;
    else
      -- Single-session credit: clear the reservation, the same update
      -- release_single_session_credit does when a booking is deleted.
      -- Checked-in and no-show never reach this loop. No Stripe refund.
      if b.plan_id like 'single:%' then
        v_credit := substr(b.plan_id, 8)::uuid;
        update public.single_session_credits
           set booking_id = null
         where id = v_credit
           and booking_id = b.id;
      end if;
      -- A package or membership session is returned because
      -- sessions_toward_booking_limit ignores rows with cancelled_at set.
    end if;

    v_ids := v_ids || to_jsonb(b.id::text);
    v_info := coalesce(v_clients->(b.client_id::text), jsonb_build_object(
      'id', b.client_id,
      'sessions', 0,
      'date', to_char(b.date, 'YYYY-MM-DD'),
      'slot', b.slot_min
    ));
    v_sessions := coalesce((v_info->>'sessions')::integer, 0) + 1;
    if (v_info->>'date') > to_char(b.date, 'YYYY-MM-DD')
       or ((v_info->>'date') = to_char(b.date, 'YYYY-MM-DD') and (v_info->>'slot')::integer > b.slot_min) then
      v_info := v_info || jsonb_build_object(
        'date', to_char(b.date, 'YYYY-MM-DD'),
        'slot', b.slot_min
      );
    end if;
    v_info := v_info || jsonb_build_object('sessions', v_sessions);
    v_clients := v_clients || jsonb_build_object(b.client_id::text, v_info);
  end loop;

  v_coach := coalesce(nullif(btrim(public.coach_public_name(p_trainer_id)), ''), 'your coach');

  -- One chat message per client, from the coach, containing the note.
  -- The message trigger prefixes the coach name (never the legal name).
  -- Channel is in-app only. A text, for someone who opted in, is sent
  -- afterwards by save-coach-unavailability, the same way a coach cancel does.
  if v_note is not null then
    for v_client in
      select (value->>'id')::uuid from jsonb_each(v_clients)
    loop
      insert into public.messages (
        client_id, trainer_id, sender_id, who, body, channel, read_by_coach
      ) values (
        v_client, p_trainer_id, p_trainer_id, 'trainer', v_note, 'inapp', true
      );
    end loop;
  end if;

  v_entry := jsonb_build_object(
    'id', v_id,
    'startDate', to_char(v_start, 'YYYY-MM-DD'),
    'endDate', to_char(v_end, 'YYYY-MM-DD'),
    'allDay', v_all_day,
    'reason', v_reason,
    'note', v_reason
  );
  if not v_all_day then
    v_entry := v_entry || jsonb_build_object('startMin', v_start_min);
    if nullif(btrim(p_entry->>'endMin'), '') is not null then
      v_entry := v_entry || jsonb_build_object('endMin', (p_entry->>'endMin')::integer);
    end if;
  end if;
  if v_note is not null then
    v_entry := v_entry || jsonb_build_object('clientNote', v_note);
  end if;

  update public.trainers
     set unavailability = coalesce(unavailability, '[]'::jsonb) || jsonb_build_array(v_entry)
   where profile_id = p_trainer_id
     and not exists (
       select 1
       from jsonb_array_elements(coalesce(unavailability, '[]'::jsonb)) e
       where e->>'id' = v_id
     );

  v_result := jsonb_build_object(
    'ok', true,
    'alreadyApplied', false,
    'shouldNotify', v_clients <> '{}'::jsonb,
    'cancelled', jsonb_array_length(v_ids),
    'bookingIds', v_ids,
    'clients', coalesce((select jsonb_agg(value) from jsonb_each(v_clients)), '[]'::jsonb),
    'coachName', v_coach,
    'clientNote', v_note,
    'entry', v_entry
  );

  insert into public.coach_unavailability_applies (entry_id, trainer_id, result)
  values (v_id, p_trainer_id, v_result);

  return v_result;
end;
$$;

revoke all on function public.apply_coach_unavailability(uuid, jsonb) from public, anon;
grant execute on function public.apply_coach_unavailability(uuid, jsonb) to authenticated;

-- Removes the block only. Cancelled sessions stay cancelled.
create or replace function public.remove_coach_unavailability(
  p_trainer_id uuid,
  p_entry_id text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_role text;
begin
  v_role := public.current_user_role();
  if v_role is distinct from 'owner'
     and not (v_role = 'coach' and auth.uid() = p_trainer_id) then
    raise exception 'You can only set unavailability for yourself.'
      using errcode = '42501';
  end if;

  update public.trainers
     set unavailability = coalesce((
       select jsonb_agg(e)
       from jsonb_array_elements(coalesce(unavailability, '[]'::jsonb)) e
       where e->>'id' is distinct from p_entry_id
     ), '[]'::jsonb)
   where profile_id = p_trainer_id;
end;
$$;

revoke all on function public.remove_coach_unavailability(uuid, text) from public, anon;
grant execute on function public.remove_coach_unavailability(uuid, text) to authenticated;

notify pgrst, 'reload schema';
