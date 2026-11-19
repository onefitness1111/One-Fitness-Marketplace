-- A client only ever hears a coach's coach name. A missing coach name is
-- "your coach". The legal name is not used, even as a first name.
-- Run after 20261119130000_bookings_updated_at.sql.
--
-- The owner and the coach still read the legal name from profiles. This
-- function is what chat, texts, and the calendar use for everyone else.

create or replace function public.coach_public_name(p_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(nullif(btrim(t.coach_name), ''), 'your coach')
  from public.profiles p
  left join public.trainers t on t.profile_id = p.id
  where p.id = p_id
    and p.role = 'coach';
$$;

revoke all on function public.coach_public_name(uuid) from public, anon;
grant execute on function public.coach_public_name(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
