-- "Working out now" no longer sticks around for days.
--
-- 1. close_stale_live_days() closes live-day rows with no activity (no set
--    change and no fresh start) for 3 hours. It also closes matching open
--    start-of-day marker rows in live_set_logs (__day_started_coach__ and
--    __day_started_client__), and any of those markers idle for 3 hours.
--    Real set rows and saved workouts (client_records.workoutLogs) are not
--    touched, so nothing logged is lost and the day can still be edited.
-- 2. A pg_cron job runs it every 15 minutes. Pure SQL, no edge function and
--    no secret needed.
-- 3. start_live_day also closes the same program day left open on an
--    earlier date, so one client never has two open rows for one day, and
--    closes the matching start markers for those other days.
-- 4. end_open_live_days also closes those start markers, so ending a
--    workout clears the client's "coach is live" bar.
--
-- Safe to run more than once. Not applied from the app.

create or replace function public.close_stale_live_days(p_idle interval default interval '3 hours')
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  closed integer;
begin
  update public.live_day_runs r
     set ended_at = now()
   where r.ended_at is null
     and r.started_at < now() - p_idle
     and not exists (
       select 1
       from public.live_set_logs s
       where s.client_id = r.client_id
         and s.log_date = r.log_date
         and s.day_id = r.day_id
         and s.updated_at >= now() - p_idle
     );
  get diagnostics closed = row_count;

  -- Close leftover start markers for runs that are already ended, and
  -- start markers idle for p_idle with no recent set activity. Only the
  -- two marker names; real set rows are not updated.
  update public.live_set_logs s
     set ended_at = now()
   where s.ended_at is null
     and s.exercise_name in ('__day_started_coach__', '__day_started_client__')
     and (
       not exists (
         select 1
         from public.live_day_runs r
         where r.client_id = s.client_id
           and r.log_date = s.log_date
           and r.day_id = s.day_id
           and r.ended_at is null
       )
       or (
         s.updated_at < now() - p_idle
         and not exists (
           select 1
           from public.live_set_logs a
           where a.client_id = s.client_id
             and a.log_date = s.log_date
             and a.day_id = s.day_id
             and a.updated_at >= now() - p_idle
             and a.exercise_name not in ('__day_started_coach__', '__day_started_client__')
         )
       )
     );

  return closed;
end;
$$;

-- Only the scheduler (and the service role) runs the sweep.
revoke all on function public.close_stale_live_days(interval) from public, anon, authenticated;
grant execute on function public.close_stale_live_days(interval) to service_role;

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

  -- One live day. Every other open row stops counting as live: other
  -- days, and the same day left open on an earlier date (which used to
  -- stay open next to today's row). Their set logs stay writable.
  update public.live_day_runs
     set ended_at = now()
   where client_id = p_client
     and ended_at is null
     and (day_id is distinct from p_day or log_date is distinct from p_date);

  update public.live_set_logs
     set ended_at = now()
   where client_id = p_client
     and ended_at is null
     and exercise_name in ('__day_started_coach__', '__day_started_client__')
     and (day_id is distinct from p_day or log_date is distinct from p_date);

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

-- Closes the live marker and the start-of-day rows only. Workout rows in
-- live_set_logs are not ended, so the day can still be logged after End
-- or after the clock runs out.
create or replace function public.end_open_live_days(p_client uuid)
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
  update public.live_day_runs
     set ended_at = now()
   where client_id = p_client
     and ended_at is null;
  update public.live_set_logs
     set ended_at = now()
   where client_id = p_client
     and ended_at is null
     and exercise_name in ('__day_started_coach__', '__day_started_client__');
end;
$$;

revoke all on function public.end_open_live_days(uuid) from public, anon;
grant execute on function public.end_open_live_days(uuid) to authenticated;

-- Every 15 minutes. Replaces an earlier copy of the job if there is one.
do $$
declare
  existing bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    select jobid into existing from cron.job where jobname = 'close-stale-live-days';
    if existing is not null then
      perform cron.unschedule(existing);
    end if;
    perform cron.schedule(
      'close-stale-live-days',
      '*/15 * * * *',
      $cron$ select public.close_stale_live_days(); $cron$
    );
  else
    raise notice 'pg_cron is not enabled, so the stale live-day job was not scheduled. Enable it, then run this file again.';
  end if;
end $$;

notify pgrst, 'reload schema';
