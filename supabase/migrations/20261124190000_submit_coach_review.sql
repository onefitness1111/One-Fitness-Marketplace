-- Submit coach reviews via a security-definer RPC and allow clients to read
-- only their own review rows.
-- Not applied from the app.

-- Clients can read only their own coach_reviews rows; coaches and other
-- clients still cannot read reviewer identities from the table.
drop policy if exists coach_reviews_select_own on public.coach_reviews;
create policy coach_reviews_select_own on public.coach_reviews
  for select
  to authenticated
  using (client_id = (select auth.uid()));

create or replace function public.submit_coach_review(
  p_booking_id uuid,
  p_trainer_id uuid,
  p_stars integer,
  p_body text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := nullif(btrim(coalesce(p_body, '')), '');
  v_booking record;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if p_stars is null or p_stars < 1 or p_stars > 5 then
    raise exception 'Rating must be between 1 and 5 stars' using errcode = '22023';
  end if;

  select
    b.client_id,
    b.trainer_id,
    b.attendance_status,
    b.cancelled_at,
    ((b.date::timestamp + make_interval(mins => b.slot_min + greatest(coalesce(b.duration_min, 60), 1))) at time zone 'America/Los_Angeles') as ended_at
  into v_booking
  from public.bookings b
  where b.id = p_booking_id;

  if not found or v_booking.client_id <> v_uid or v_booking.trainer_id <> p_trainer_id then
    raise exception 'Booking not found for this client and coach' using errcode = '42501';
  end if;

  if v_booking.cancelled_at is not null or v_booking.attendance_status is distinct from 'checked-in' then
    raise exception 'Only checked-in sessions can be reviewed' using errcode = '42501';
  end if;

  if v_booking.ended_at > now() then
    raise exception 'Session has not finished yet' using errcode = '42501';
  end if;

  insert into public.coach_reviews (booking_id, client_id, trainer_id, stars, body)
  values (p_booking_id, v_uid, p_trainer_id, p_stars, v_body)
  on conflict (booking_id) do update
    set stars = excluded.stars,
        body = excluded.body,
        updated_at = now()
    where public.coach_reviews.client_id = v_uid
  returning id into v_id;

  if v_id is null then
    raise exception 'Review could not be saved' using errcode = '42501';
  end if;

  return v_id;
end;
$$;

revoke all on function public.submit_coach_review(uuid, uuid, integer, text) from public, anon;
grant execute on function public.submit_coach_review(uuid, uuid, integer, text) to authenticated;

comment on function public.submit_coach_review(uuid, uuid, integer, text) is
  'Submits or updates the signed-in client''s review for one of their own finished, checked-in, uncancelled bookings.';

notify pgrst, 'reload schema';
