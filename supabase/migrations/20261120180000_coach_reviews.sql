-- Client ratings of a checked-in session, and the aggregate a profile shows.
-- Reviewer names are not returned by the read functions.
-- Not applied from the app.

create table if not exists public.coach_reviews (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique,
  client_id uuid not null,
  trainer_id uuid not null,
  stars integer not null check (stars between 1 and 5),
  body text,
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.review_prompts (
  booking_id uuid primary key,
  client_id uuid not null,
  trainer_id uuid not null,
  deferred_on date,
  updated_at timestamptz not null default now()
);

alter table public.coach_reviews enable row level security;
alter table public.review_prompts enable row level security;

drop policy if exists coach_reviews_insert_own on public.coach_reviews;
create policy coach_reviews_insert_own on public.coach_reviews
  for insert
  with check (
    client_id = auth.uid()
    and exists (
      select 1 from public.bookings b
      where b.id = booking_id
        and b.client_id = auth.uid()
        and b.trainer_id = coach_reviews.trainer_id
        and b.attendance_status = 'checked-in'
        and b.cancelled_at is null
    )
  );

drop policy if exists coach_reviews_update_own on public.coach_reviews;
create policy coach_reviews_update_own on public.coach_reviews
  for update
  using (client_id = auth.uid() and created_at > now() - interval '2 days')
  with check (client_id = auth.uid());

drop policy if exists coach_reviews_owner on public.coach_reviews;
create policy coach_reviews_owner on public.coach_reviews
  for all
  using (public.is_owner())
  with check (public.is_owner());

drop policy if exists review_prompts_own on public.review_prompts;
create policy review_prompts_own on public.review_prompts
  for all
  using (client_id = auth.uid())
  with check (client_id = auth.uid());

grant select, insert, update on public.coach_reviews to authenticated;
grant select, insert, update on public.review_prompts to authenticated;

create or replace function public.coach_review_summary(p_trainer uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  total integer;
  avg numeric;
  clients integer;
  repeaters integer;
  rebook numeric;
  stars jsonb;
begin
  select count(*), avg(r.stars) into total, avg
  from public.coach_reviews r
  where r.trainer_id = p_trainer and r.hidden = false;

  select coalesce(jsonb_object_agg(s.stars, s.n), '{}'::jsonb) into stars
  from (
    select r.stars, count(*)::integer as n
    from public.coach_reviews r
    where r.trainer_id = p_trainer and r.hidden = false
    group by r.stars
  ) s;

  select count(*)::integer into clients from (
    select b.client_id
    from public.bookings b
    where b.trainer_id = p_trainer
      and b.attendance_status = 'checked-in'
      and b.cancelled_at is null
    group by b.client_id
  ) c;

  select count(*)::integer into repeaters from (
    select b.client_id
    from public.bookings b
    where b.trainer_id = p_trainer
      and b.attendance_status = 'checked-in'
      and b.cancelled_at is null
    group by b.client_id
    having count(*) >= 2
  ) c;

  if clients >= 5 then
    rebook := round(100.0 * repeaters / clients);
  end if;

  return jsonb_build_object(
    'count', coalesce(total, 0),
    'average', avg,
    'stars', stars,
    'rebookPercent', rebook
  );
end;
$$;

create or replace function public.coach_reviews_page(
  p_trainer uuid,
  p_stars integer,
  p_offset integer,
  p_limit integer
)
returns table (stars integer, body text, created_at timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $$
  select r.stars, r.body, r.created_at
  from public.coach_reviews r
  where r.trainer_id = p_trainer
    and r.hidden = false
    and (p_stars is null or r.stars = p_stars)
  order by r.created_at desc
  offset greatest(coalesce(p_offset, 0), 0)
  limit least(greatest(coalesce(p_limit, 20), 1), 20);
$$;

revoke all on function public.coach_review_summary(uuid) from public, anon;
revoke all on function public.coach_reviews_page(uuid, integer, integer, integer) from public, anon;
grant execute on function public.coach_review_summary(uuid) to authenticated;
grant execute on function public.coach_reviews_page(uuid, integer, integer, integer) to authenticated;
