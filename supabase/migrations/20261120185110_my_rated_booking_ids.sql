-- The rating card asks which of this client's sessions are already rated.
-- coach_reviews has no client SELECT policy on purpose: a table read would
-- hand a client their review text, and a wider policy would show reviewers
-- to coaches and other clients.
-- This function returns booking ids only, and only rows where the reviewer
-- is the signed-in caller. It takes no user id argument.
-- Not applied from the app.

create index if not exists coach_reviews_client_id_idx
  on public.coach_reviews (client_id);

create or replace function public.my_rated_booking_ids()
returns setof uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select r.booking_id
  from public.coach_reviews r
  where r.client_id = (select auth.uid());
$$;

revoke all on function public.my_rated_booking_ids() from public, anon;
grant execute on function public.my_rated_booking_ids() to authenticated;

comment on function public.my_rated_booking_ids() is
  'Booking ids the signed-in client has already rated. No names, stars, or other clients.';
