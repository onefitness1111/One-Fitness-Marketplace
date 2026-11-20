-- Only one program day per client stays live.
-- Starting another day closes the earlier live rows. It does not touch
-- the set log, so the workout itself can still be edited.
-- Ending the live session (the clock / End button) closes the live rows
-- the same way, and also leaves the set log alone.
-- Not applied from the app.

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

  -- One live day. Older open rows, including ones from a previous date,
  -- stop counting as live. Their set logs stay writable.
  update public.live_day_runs
     set ended_at = now()
   where client_id = p_client
     and ended_at is null
     and day_id is distinct from p_day;

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

-- Closes the live marker only. Workout rows in live_set_logs are not ended,
-- so the day can still be logged after End or after the clock runs out.
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
end;
$$;

revoke all on function public.end_open_live_days(uuid) from public, anon;
grant execute on function public.end_open_live_days(uuid) to authenticated;
