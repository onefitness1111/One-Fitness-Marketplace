-- Live program days, safer workout saves, and who may see a client's live log.
--
-- Not applied to the live database. Do not run the closer against existing
-- rows from here: stuck session_runs are left as they are until the app
-- calls close_recent_expired_session_runs after this is deployed, and that
-- function only finishes a run whose clock ended within the last day and a
-- half.

-- ---------------------------------------------------------------------------
-- Who works with a client
-- ---------------------------------------------------------------------------

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
    or exists (
      select 1 from public.clients c
      where c.profile_id = p_client
        and c.primary_trainer_id = auth.uid()
    )
    or exists (
      select 1 from public.bookings b
      where b.client_id = p_client
        and b.trainer_id = auth.uid()
        and b.cancelled_at is null
    );
$$;

revoke all on function public.coach_works_with_client(uuid) from public, anon;
grant execute on function public.coach_works_with_client(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- A program day that has been started, before any set is typed
-- ---------------------------------------------------------------------------

create table if not exists public.live_day_runs (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null,
  log_date date not null,
  day_id text not null,
  program_id text,
  started_by uuid,
  started_role text not null check (started_role in ('client', 'coach', 'owner')),
  trainer_id uuid,
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

create unique index if not exists live_day_runs_open_uniq
  on public.live_day_runs (client_id, log_date, day_id)
  where ended_at is null;

alter table public.live_day_runs enable row level security;

drop policy if exists live_day_runs_rw on public.live_day_runs;
create policy live_day_runs_rw on public.live_day_runs
  for all
  using (
    client_id = auth.uid()
    or public.is_owner()
    or public.coach_works_with_client(client_id)
  )
  with check (
    client_id = auth.uid()
    or public.is_owner()
    or public.coach_works_with_client(client_id)
  );

grant select, insert, update on public.live_day_runs to authenticated;

-- Live sets and notes: the client, the owner, and a coach who works with
-- that client. Not every coach in the gym.
drop policy if exists live_set_logs_all on public.live_set_logs;
drop policy if exists live_set_logs_rw on public.live_set_logs;
create policy live_set_logs_rw on public.live_set_logs
  for all
  using (
    client_id = auth.uid()
    or public.is_owner()
    or public.coach_works_with_client(client_id)
  )
  with check (
    client_id = auth.uid()
    or public.is_owner()
    or public.coach_works_with_client(client_id)
  );

drop policy if exists live_log_notes_select on public.live_log_notes;
drop policy if exists live_log_notes_insert on public.live_log_notes;
drop policy if exists live_log_notes_rw on public.live_log_notes;
create policy live_log_notes_rw on public.live_log_notes
  for all
  using (
    client_id = auth.uid()
    or public.is_owner()
    or public.coach_works_with_client(client_id)
  )
  with check (
    author_id = auth.uid()
    and (
      client_id = auth.uid()
      or public.is_owner()
      or public.coach_works_with_client(client_id)
    )
  );

create or replace function public.start_live_day(
  p_client uuid,
  p_date date,
  p_day text,
  p_program text,
  p_role text,
  p_trainer uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  existing uuid;
  new_id uuid;
  marker text;
begin
  if p_role not in ('client', 'coach', 'owner') then
    raise exception 'Not allowed.';
  end if;
  if auth.uid() is distinct from p_client
     and not public.is_owner()
     and not public.coach_works_with_client(p_client) then
    raise exception 'Not allowed.';
  end if;
  if p_role = 'client' and auth.uid() is distinct from p_client and not public.is_owner() then
    raise exception 'Not allowed.';
  end if;

  select id into existing
  from public.live_day_runs
  where client_id = p_client and log_date = p_date and day_id = p_day and ended_at is null
  limit 1;
  if existing is not null then
    if p_role in ('coach', 'owner') then
      update public.live_day_runs
         set started_role = p_role,
             trainer_id = coalesce(p_trainer, trainer_id),
             started_by = auth.uid()
       where id = existing;
    end if;
    return existing;
  end if;

  insert into public.live_day_runs (
    client_id, log_date, day_id, program_id, started_by, started_role, trainer_id
  ) values (
    p_client, p_date, p_day, p_program, auth.uid(), p_role, p_trainer
  ) returning id into new_id;

  -- A marker row so the other phone sees the day before the first set.
  marker := case when p_role = 'client' then '__day_started_client__' else '__day_started_coach__' end;
  insert into public.live_set_logs (
    client_id, log_date, day_id, program_id, exercise_name, set_num, reps, reps_at, reps_by
  ) values (
    p_client, p_date, p_day, p_program, marker, 0, 0, now(), auth.uid()
  )
  on conflict (client_id, log_date, day_id, exercise_name, set_num)
  do update set ended_at = null, updated_at = now(), reps_at = now(), reps_by = auth.uid();

  return new_id;
end;
$$;

revoke all on function public.start_live_day(uuid, date, text, text, text, uuid) from public, anon;
grant execute on function public.start_live_day(uuid, date, text, text, text, uuid) to authenticated;

-- Ending one day does not end a different day logged on the same date.
-- The live database already has end_live_logs(uuid, date). A new argument
-- does not replace that copy, so drop it first. Otherwise both exist and
-- the app's call (which names the day) can miss the new one.
drop function if exists public.end_live_logs(uuid, date);

create or replace function public.end_live_logs(p_client uuid, p_date date, p_day text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is distinct from p_client
     and not public.is_owner()
     and not public.coach_works_with_client(p_client) then
    raise exception 'Not allowed.';
  end if;
  -- The App Store app calls this with only the client and the date, and that
  -- finishes every open log for that date. The new app names one day, so a
  -- different day logged on the same date stays open.
  if p_day is null then
    update public.live_set_logs set ended_at = now()
     where client_id = p_client and log_date = p_date and ended_at is null;
    update public.live_day_runs set ended_at = now()
     where client_id = p_client and log_date = p_date and ended_at is null;
    return;
  end if;
  update public.live_set_logs set ended_at = now()
   where client_id = p_client and log_date = p_date and day_id = p_day and ended_at is null;
  update public.live_day_runs set ended_at = now()
   where client_id = p_client and log_date = p_date and day_id = p_day and ended_at is null;
end;
$$;

revoke all on function public.end_live_logs(uuid, date, text) from public, anon;
grant execute on function public.end_live_logs(uuid, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- One workout log at a time, without rewriting the rest of the record
-- ---------------------------------------------------------------------------

create or replace function public.append_workout_log(p_client uuid, p_entry jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  row_data jsonb;
  logs jsonb;
  entry_id text;
  i int;
  found boolean := false;
begin
  if auth.uid() is distinct from p_client
     and not public.is_owner()
     and not public.coach_works_with_client(p_client) then
    raise exception 'Not allowed.';
  end if;
  if p_entry is null or coalesce(p_entry->>'id', '') = '' then
    raise exception 'A workout needs an id.';
  end if;

  select data into row_data from public.client_records where profile_id = p_client for update;
  if row_data is null then
    insert into public.client_records (profile_id, data)
    values (p_client, jsonb_build_object('workoutLogs', jsonb_build_array(p_entry)));
    return;
  end if;

  logs := coalesce(row_data->'workoutLogs', '[]'::jsonb);
  if jsonb_typeof(logs) <> 'array' then
    logs := '[]'::jsonb;
  end if;
  entry_id := p_entry->>'id';
  for i in 0 .. jsonb_array_length(logs) - 1 loop
    if logs->i->>'id' = entry_id then
      logs := jsonb_set(logs, array[i::text], p_entry);
      found := true;
      exit;
    end if;
  end loop;
  if not found then
    logs := logs || jsonb_build_array(p_entry);
  end if;
  update public.client_records
     set data = jsonb_set(row_data, '{workoutLogs}', logs, true)
   where profile_id = p_client;
end;
$$;

revoke all on function public.append_workout_log(uuid, jsonb) from public, anon;
grant execute on function public.append_workout_log(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Beep only while a coach has started a program day
-- ---------------------------------------------------------------------------

alter table public.beeps alter column session_run_id drop not null;

-- The App Store app still beeps against an open session run. That insert
-- policy stays. This adds the program-day path beside it. An insert is
-- allowed when either policy accepts it.
drop policy if exists beeps_insert_live_day on public.beeps;
create policy beeps_insert_live_day on public.beeps
  for insert
  with check (
    client_id = auth.uid()
    and exists (
      select 1 from public.live_day_runs d
      where d.client_id = auth.uid()
        and d.ended_at is null
        and d.started_role in ('coach', 'owner')
        and d.trainer_id = beeps.trainer_id
    )
  );

-- ---------------------------------------------------------------------------
-- Finish a booked session whose clock has run out.
-- Only recent ones. Older rows left open are not touched.
-- This function is not called by the migration itself.
-- ---------------------------------------------------------------------------

create or replace function public.close_recent_expired_session_runs()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  n integer;
begin
  if public.current_user_role() not in ('coach', 'owner', 'client') then
    return 0;
  end if;
  update public.session_runs
     set ended_at = started_at + make_interval(mins => duration_min)
   where ended_at is null
     and started_at + make_interval(mins => duration_min) <= now()
     and started_at + make_interval(mins => duration_min) > now() - interval '36 hours'
     and (
       trainer_id = auth.uid()
       or public.is_owner()
       or exists (
         select 1 from public.bookings b
         where b.trainer_id = session_runs.trainer_id
           and b.date = session_runs.date
           and b.slot_min = session_runs.slot_min
           and b.client_id = auth.uid()
           and b.cancelled_at is null
       )
     );
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public.close_recent_expired_session_runs() from public, anon;
grant execute on function public.close_recent_expired_session_runs() to authenticated;
