-- Merit Badge fixes. Not applied to the live database by this change.
-- Run the earlier files in this stack first. This one expects
-- public.cron_vault_secret() from the remaining-fixes migration.

-- ---------------------------------------------------------------------------
-- New client badges, and a force award the nightly sweep will not remove.
-- ---------------------------------------------------------------------------

alter table public.merit_badges drop constraint if exists merit_badges_badge_key_check;
alter table public.merit_badges add constraint merit_badges_badge_key_check check (badge_key = any (array[
  'one_fitness', 'early_bird', 'daytimer', 'night_owl', 'progress_tracker',
  'record_breaker', 'community_builder', 'squad', 'champion', 'habit', 'gym_citizen',
  'gym_citizen_rerack', 'gym_citizen_setup', 'gym_citizen_reset', 'gym_citizen_loadup',
  'gym_citizen_knowit', 'gym_citizen_countreps', 'gym_citizen_coachable', 'gym_citizen_gymaware',
  'gym_citizen_workoutready', 'gym_citizen_gymcourtesy',
  'progress_tracker_photo', 'progress_tracker_measurements', 'progress_tracker_workout',
  'first_session', 'sessions_10', 'sessions_25', 'sessions_50', 'sessions_100',
  'one_year', 'nutrition_streak', 'perfect_attendance', 'goal_reached'
]));

alter table public.merit_badges drop constraint if exists merit_badges_earned_method_check;
alter table public.merit_badges add constraint merit_badges_earned_method_check
  check (earned_method = any (array['automatic', 'coach', 'force']));

alter table public.merit_badges drop constraint if exists merit_badges_check;
alter table public.merit_badges add constraint merit_badges_check check (
  (earned_method = 'automatic' and granted_by_user_id is null)
  or (earned_method in ('coach', 'force') and granted_by_user_id is not null)
);

alter table public.merit_badges add column if not exists celebrated_at timestamptz;
update public.merit_badges set celebrated_at = earned_at where celebrated_at is null;

-- ---------------------------------------------------------------------------
-- Clients cannot edit challenge badges on their own record. Coaches, the
-- owner, and the service role still can. The app no longer writes this
-- list; Champion is a real merit_badges row.
-- ---------------------------------------------------------------------------

create or replace function public.protect_challenge_badges()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.role() = 'service_role' or public.current_user_role() in ('coach', 'owner') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.data = coalesce(new.data, '{}'::jsonb) - 'challengeBadges';
    return new;
  end if;
  new.data = jsonb_set(
    coalesce(new.data, '{}'::jsonb),
    '{challengeBadges}',
    coalesce(old.data->'challengeBadges', '[]'::jsonb),
    true
  );
  return new;
end;
$$;

drop trigger if exists protect_challenge_badges on public.client_records;
create trigger protect_challenge_badges
  before insert or update on public.client_records
  for each row execute function public.protect_challenge_badges();

revoke all on function public.protect_challenge_badges() from public, anon, authenticated;

create or replace function public.mark_merit_badges_seen(p_ids uuid[])
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in.';
  end if;
  update public.merit_badges
     set celebrated_at = now()
   where id = any (coalesce(p_ids, array[]::uuid[]))
     and client_id = auth.uid()
     and celebrated_at is null;
end;
$$;

revoke all on function public.mark_merit_badges_seen(uuid[]) from public, anon;
grant execute on function public.mark_merit_badges_seen(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- Who can see and write badges.
-- Clients read their own Merit Badges. A coach reads Merit Badges only for
-- clients they have trained, been assigned, referred, or logged a PR for.
-- The owner reads everything.
-- A coach reads only their own coach badges and their own PR rows.
-- Only the owner (or the service role, which bypasses these policies) can
-- insert a coach badge or mark one paid.
-- ---------------------------------------------------------------------------

drop policy if exists merit_badges_select_self_or_staff on public.merit_badges;
create policy merit_badges_select_scoped on public.merit_badges
  for select to authenticated
  using (
    client_id = auth.uid()
    or public.current_user_role() = 'owner'
    or (
      public.current_user_role() = 'coach'
      and (
        exists (
          select 1 from public.bookings b
          where b.client_id = merit_badges.client_id and b.trainer_id = auth.uid()
        )
        or exists (
          select 1 from public.clients c
          where c.profile_id = merit_badges.client_id
            and (c.primary_trainer_id = auth.uid() or c.referred_by_trainer_id = auth.uid())
        )
        or exists (
          select 1 from public.coach_pr_events e
          where e.client_id = merit_badges.client_id and e.trainer_id = auth.uid()
        )
      )
    )
  );

drop policy if exists coach_merit_badges_select_authenticated on public.coach_merit_badges;
create policy coach_merit_badges_select_own on public.coach_merit_badges
  for select to authenticated
  using (
    public.current_user_role() = 'owner'
    or trainer_id = auth.uid()
  );

drop policy if exists coach_merit_badges_insert_staff on public.coach_merit_badges;
create policy coach_merit_badges_insert_owner on public.coach_merit_badges
  for insert to authenticated
  with check (public.current_user_role() = 'owner');

drop policy if exists coach_merit_badges_update_owner on public.coach_merit_badges;
create policy coach_merit_badges_update_owner on public.coach_merit_badges
  for update to authenticated
  using (public.current_user_role() = 'owner')
  with check (public.current_user_role() = 'owner');

drop policy if exists coach_pr_events_select_authenticated on public.coach_pr_events;
create policy coach_pr_events_select_own on public.coach_pr_events
  for select to authenticated
  using (
    public.current_user_role() = 'owner'
    or trainer_id = auth.uid()
  );

drop policy if exists coach_pr_events_insert_staff on public.coach_pr_events;
create policy coach_pr_events_insert_own on public.coach_pr_events
  for insert to authenticated
  with check (
    public.current_user_role() = 'owner'
    or (public.current_user_role() = 'coach' and trainer_id = auth.uid())
  );

-- The app never writes these tables directly. The edge functions use the
-- service role. Leaving insert/update/delete granted to anon and
-- authenticated was unused and unsafe.
revoke insert, update, delete, truncate on public.merit_badges from public, anon, authenticated;
revoke insert, update, delete, truncate on public.points_ledger from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Nightly sweep. Same Vault password as the hourly request job:
--   Name: apply_requests_cron
-- The value is not in this file.
-- 15 8 * * * is 12:15am Pacific Standard Time, and 1:15am during daylight
-- saving, which is after the Pacific month has turned.
-- ---------------------------------------------------------------------------

do $$
declare
  existing bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_extension where extname = 'pg_net') then
    select jobid into existing from cron.job where jobname = 'sweep-merit-badges';
    if existing is not null then
      perform cron.unschedule(existing);
    end if;
    perform cron.schedule(
      'sweep-merit-badges',
      '15 8 * * *',
      $cron$
      select net.http_post(
        url := 'https://rivhgutksyddeckieknc.supabase.co/functions/v1/sweep-merit-badges',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select public.cron_vault_secret())
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 5000
      );
      $cron$
    );
  else
    raise notice 'pg_cron or pg_net is not enabled, so the nightly badge sweep was not scheduled. Enable both extensions, then run this file again.';
  end if;
end $$;

notify pgrst, 'reload schema';
