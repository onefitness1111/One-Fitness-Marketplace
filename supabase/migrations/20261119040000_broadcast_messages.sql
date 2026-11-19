-- Who a broadcast may reach.
-- Not applied to the live database by this change.
-- Run it after 20261119030000_fix_leg_press_equipment.sql.
--
-- The owner may reach every client. A coach may reach only the clients
-- whose primary coach is them. The broadcast function calls this. A signed-in
-- client cannot. No new Vault secret.

create or replace function public.broadcast_allowed_clients(p_sender uuid)
returns table (client_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  sender_role text;
begin
  select p.role into sender_role
  from public.profiles p
  where p.id = p_sender
    and p.deleted_at is null;

  if sender_role = 'owner' then
    return query
      select p.id
      from public.profiles p
      where p.role = 'client'
        and p.deleted_at is null;
  elsif sender_role = 'coach' then
    return query
      select c.profile_id
      from public.clients c
      join public.profiles p on p.id = c.profile_id
      where c.primary_trainer_id = p_sender
        and p.role = 'client'
        and p.deleted_at is null;
  end if;
end;
$$;

revoke all on function public.broadcast_allowed_clients(uuid) from public, anon, authenticated;
grant execute on function public.broadcast_allowed_clients(uuid) to service_role;

-- The broadcast function reads the public coach name. It must not read a
-- legal name. service_role is what the function runs as.
grant execute on function public.coach_public_name(uuid) to service_role;
grant execute on function public.message_sender_label(uuid, text) to service_role;

notify pgrst, 'reload schema';
