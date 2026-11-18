-- Coaches may write a client's phone and billing address, and may not read them.
-- Not applied to the live database by this change.
-- Run it after 20261119060000_billing_address.sql.
--
-- profile_contact_for and client_billing_address stay limited to the client
-- and the owner. The new calls return no phone number and no street address.

create or replace function public.client_file_flags(p_client uuid)
returns table (phone_on_file boolean, billing_on_file boolean)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  coach uuid;
  phone text;
  addr jsonb;
begin
  select c.primary_trainer_id, nullif(btrim(p.phone), ''), c.billing_address
    into coach, phone, addr
  from public.clients c
  join public.profiles p on p.id = c.profile_id
  where c.profile_id = p_client;

  if auth.role() is distinct from 'service_role'
     and p_client is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner'
     and not (public.current_user_role() = 'coach' and coach = auth.uid()) then
    raise exception 'Not allowed.';
  end if;

  phone_on_file := phone is not null;
  billing_on_file := coalesce(addr->>'line1', '') <> '';
  return next;
end;
$$;

revoke all on function public.client_file_flags(uuid) from public, anon;
grant execute on function public.client_file_flags(uuid) to authenticated, service_role;

create or replace function public.set_client_phone(p_client uuid, p_phone text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  coach uuid;
  digits text;
begin
  select primary_trainer_id into coach from public.clients where profile_id = p_client;
  if auth.role() is distinct from 'service_role'
     and p_client is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner'
     and not (public.current_user_role() = 'coach' and coach = auth.uid()) then
    raise exception 'Not allowed to update that phone.';
  end if;
  digits := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  if length(digits) < 7 then
    raise exception 'Enter a phone number.';
  end if;
  update public.profiles set phone = btrim(p_phone) where id = p_client;
end;
$$;

revoke all on function public.set_client_phone(uuid, text) from public, anon;
grant execute on function public.set_client_phone(uuid, text) to authenticated, service_role;

create or replace function public.set_client_billing_address(p_client uuid, p_address jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  coach uuid;
begin
  select primary_trainer_id into coach from public.clients where profile_id = p_client;
  if auth.role() is distinct from 'service_role'
     and p_client is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner'
     and not (public.current_user_role() = 'coach' and coach = auth.uid()) then
    raise exception 'Not allowed to update that billing address.';
  end if;
  if coalesce(p_address->>'line1', '') = '' or coalesce(p_address->>'city', '') = '' then
    raise exception 'Enter the street and city.';
  end if;
  update public.clients
  set billing_address = p_address,
      city = nullif(btrim(p_address->>'city'), ''),
      state = nullif(btrim(p_address->>'state'), '')
  where profile_id = p_client;
end;
$$;

revoke all on function public.set_client_billing_address(uuid, jsonb) from public, anon;
grant execute on function public.set_client_billing_address(uuid, jsonb) to authenticated, service_role;

-- The emergency-contact number was readable on the client row by every
-- signed-in person, including coaches. It now comes back only from
-- client_billing_address's sibling below, for the client and the owner.
revoke select (emergency_contact_phone) on table public.clients from authenticated;

create or replace function public.client_emergency_phone(p_client uuid)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  found text;
begin
  if auth.role() is distinct from 'service_role'
     and p_client is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner' then
    return null;
  end if;
  select emergency_contact_phone into found from public.clients where profile_id = p_client;
  return found;
end;
$$;

revoke all on function public.client_emergency_phone(uuid) from public, anon;
grant execute on function public.client_emergency_phone(uuid) to authenticated, service_role;
