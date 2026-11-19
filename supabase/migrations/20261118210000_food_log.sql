-- Lets a client save their own food log as one key on their record.
-- Not applied to the live database by this change. Apply it when the
-- nutrition update goes live, then the app can store a log without
-- rewriting the rest of the record.
--
-- A coach cannot write this key. The client can write their own. The
-- owner can too.

create or replace function public.patch_client_record(p_client uuid, p_patch jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  row_data jsonb;
  k text;
begin
  if auth.role() is distinct from 'service_role'
     and auth.uid() is distinct from p_client
     and public.current_user_role() not in ('coach', 'owner') then
    raise exception 'Not allowed.';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'Nothing to save.';
  end if;
  if p_patch ? 'foodLog'
     and auth.role() is distinct from 'service_role'
     and auth.uid() is distinct from p_client
     and public.current_user_role() is distinct from 'owner' then
    raise exception 'Only the client can update their food log.';
  end if;
  for k in select jsonb_object_keys(p_patch) loop
    if k not in (
      'nutrition', 'myMeals', 'savedNutritionPrograms',
      'measurements', 'trainerNotes', 'photos', 'intake',
      'foodLog'
    ) then
      raise exception 'That part of the record cannot be saved this way.';
    end if;
  end loop;

  select data into row_data from public.client_records where profile_id = p_client for update;
  if row_data is null then
    insert into public.client_records (profile_id, data) values (p_client, p_patch);
    return;
  end if;
  update public.client_records
     set data = coalesce(row_data, '{}'::jsonb) || p_patch
   where profile_id = p_client;
end;
$$;

revoke all on function public.patch_client_record(uuid, jsonb) from public, anon;
grant execute on function public.patch_client_record(uuid, jsonb) to authenticated;
