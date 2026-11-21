-- Health and wearable stats the client chooses to share.
-- Not applied to the live database by this change. The owner applies it
-- separately. Until then the app keeps the numbers on the phone and hides
-- the coach's health section.
--
-- The client owns every row. The assigned coach and the owner can read
-- only after share_with_coach is true. They cannot write. Phone numbers,
-- billing addresses, and legal names are not stored here.

create table if not exists public.health_connections (
  client_id uuid primary key references public.profiles (id) on delete cascade,
  source text not null check (source in ('apple_health', 'health_connect')),
  share_with_coach boolean not null default false,
  last_synced_at timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.health_daily_stats (
  client_id uuid not null references public.profiles (id) on delete cascade,
  day date not null,
  steps integer,
  active_energy_kcal numeric,
  resting_heart_rate integer,
  heart_rate integer,
  sleep_minutes integer,
  hrv_ms numeric,
  weight_lb numeric,
  body_fat_pct numeric,
  lean_mass_lb numeric,
  updated_at timestamptz not null default now(),
  primary key (client_id, day)
);

create table if not exists public.health_workouts (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles (id) on delete cascade,
  external_id text not null,
  started_at timestamptz not null,
  ended_at timestamptz,
  duration_min integer,
  activity text not null,
  energy_kcal numeric,
  source text not null check (source in ('apple_health', 'health_connect')),
  updated_at timestamptz not null default now(),
  unique (client_id, external_id)
);

comment on table public.health_connections is
  'One row per client. share_with_coach starts false and is the only way a coach or the owner can read the other two tables.';

create index if not exists health_daily_stats_day_idx
  on public.health_daily_stats (client_id, day desc);

create index if not exists health_workouts_started_idx
  on public.health_workouts (client_id, started_at desc);

alter table public.health_connections enable row level security;
alter table public.health_daily_stats enable row level security;
alter table public.health_workouts enable row level security;

revoke all on table public.health_connections from public, anon;
revoke all on table public.health_daily_stats from public, anon;
revoke all on table public.health_workouts from public, anon;

grant select, insert, update, delete on table public.health_connections to authenticated;
grant select, insert, update, delete on table public.health_daily_stats to authenticated;
grant select, insert, update, delete on table public.health_workouts to authenticated;

-- True only for the owner, or the coach assigned on clients.primary_trainer_id,
-- and only when the client has turned sharing on. Security definer so the
-- policy can see the connection row without recursing through RLS.
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
        or (
          public.current_user_role() = 'coach'
          and exists (
            select 1
            from public.clients c
            where c.profile_id = p_client
              and c.primary_trainer_id = (select auth.uid())
          )
        )
      )
  );
$$;

revoke all on function public.health_shared_with_me(uuid) from public, anon;
grant execute on function public.health_shared_with_me(uuid) to authenticated;

drop policy if exists health_connections_own on public.health_connections;
create policy health_connections_own
  on public.health_connections
  for all
  to authenticated
  using (client_id = (select auth.uid()))
  with check (client_id = (select auth.uid()));

drop policy if exists health_connections_shared_read on public.health_connections;
create policy health_connections_shared_read
  on public.health_connections
  for select
  to authenticated
  using ((select public.health_shared_with_me(client_id)));

drop policy if exists health_daily_stats_own on public.health_daily_stats;
create policy health_daily_stats_own
  on public.health_daily_stats
  for all
  to authenticated
  using (client_id = (select auth.uid()))
  with check (client_id = (select auth.uid()));

drop policy if exists health_daily_stats_shared_read on public.health_daily_stats;
create policy health_daily_stats_shared_read
  on public.health_daily_stats
  for select
  to authenticated
  using ((select public.health_shared_with_me(client_id)));

drop policy if exists health_workouts_own on public.health_workouts;
create policy health_workouts_own
  on public.health_workouts
  for all
  to authenticated
  using (client_id = (select auth.uid()))
  with check (client_id = (select auth.uid()));

drop policy if exists health_workouts_shared_read on public.health_workouts;
create policy health_workouts_shared_read
  on public.health_workouts
  for select
  to authenticated
  using ((select public.health_shared_with_me(client_id)));
