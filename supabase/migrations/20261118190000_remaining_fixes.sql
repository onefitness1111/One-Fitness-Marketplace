-- Remaining fixes. Not applied to the live database. Do not run this
-- from an automated job. Coach Chris pastes it in the SQL editor once,
-- after the earlier security files, when he is ready.
--
-- What this does:
-- 1. Owner checks use the role on the account, not an email address.
-- 2. Phone rules: a client and a coach cannot share a number unless both
--    accounts use the same email. Coaches may share the owner's number or
--    the gym's number. Two clients cannot share a number. Two coaches
--    cannot share a number unless it is the owner's or the gym's.
-- 3. Cancel fees: 12 hours is $15, 4 hours is $25. Both give the session
--    back. A coach-marked no-show uses the session and is the $25 fee.
-- 4. Progress photos and intake files sit in private storage. The client,
--    coaches who work with them, and the owner can open them.
-- 5. Nutrition, measurements, notes, photos, and intake save one piece at
--    a time, so two saves cannot wipe each other out.
-- 6. The hourly freeze job reads its password from Vault. The password is
--    not in this file. See the Vault section at the bottom.

-- ---------------------------------------------------------------------------
-- Owner role
-- ---------------------------------------------------------------------------

create or replace function public.current_user_role()
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select p.role
  from public.profiles p
  where p.id = auth.uid()
    and p.deleted_at is null;
$$;

create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.current_user_role() = 'owner';
$$;

revoke all on function public.current_user_role() from public, anon;
revoke all on function public.is_owner() from public, anon;
grant execute on function public.current_user_role() to authenticated, service_role;
grant execute on function public.is_owner() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Phone rules
-- ---------------------------------------------------------------------------

create or replace function public.phone_digits(raw text)
returns text
language sql
immutable
as $$
  select case
    when length(d) = 11 and left(d, 1) = '1' then substr(d, 2)
    else d
  end
  from (select regexp_replace(coalesce(raw, ''), '\D', '', 'g') as d) s;
$$;

create or replace function public.enforce_profile_phone()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  digits text := public.phone_digits(new.phone);
  other record;
  business text;
  owner_digits text;
  shared_ok boolean;
begin
  if tg_op = 'UPDATE'
     and new.phone is not distinct from old.phone
     and new.role is not distinct from old.role
     and new.email is not distinct from old.email then
    return new;
  end if;
  if digits is null or length(digits) < 7 then
    return new;
  end if;

  select public.phone_digits(data #>> '{location,supportPhone}')
    into business
  from public.platform_settings
  where id = 'global';

  select public.phone_digits(p.phone)
    into owner_digits
  from public.profiles p
  where p.role = 'owner'
    and p.deleted_at is null
    and p.id is distinct from new.id
    and length(public.phone_digits(p.phone)) >= 7
  limit 1;

  shared_ok := digits = business or digits = owner_digits;

  if new.role = 'client' and shared_ok then
    raise exception 'phone_gym_client: That number belongs to the gym.'
      using errcode = 'check_violation';
  end if;

  for other in
    select p.id, p.role, p.email
    from public.profiles p
    where p.deleted_at is null
      and p.id is distinct from new.id
      and public.phone_digits(p.phone) = digits
  loop
    if new.role = 'client' and other.role = 'client' then
      raise exception 'phone_same_role_client: That phone number is already on another client account.'
        using errcode = 'check_violation';
    end if;
    if new.role = 'coach' and other.role = 'coach' and not shared_ok then
      raise exception 'phone_same_role_coach: That phone number is already on another coach account.'
        using errcode = 'check_violation';
    end if;
    if (new.role = 'client' and other.role = 'coach')
       or (new.role = 'coach' and other.role = 'client') then
      if lower(btrim(coalesce(new.email, ''))) is distinct from lower(btrim(coalesce(other.email, '')))
         or btrim(coalesce(new.email, '')) = '' then
        raise exception 'phone_client_coach: A client and a coach cannot share a phone number unless both accounts use the same email.'
          using errcode = 'check_violation';
      end if;
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists profiles_enforce_phone on public.profiles;
create trigger profiles_enforce_phone
  before insert or update of phone, role, email
  on public.profiles
  for each row
  execute function public.enforce_profile_phone();

-- Older unique indexes, if they are on the live database, would block a
-- coach from using the gym number. The trigger above is the rule now.
drop index if exists public.profiles_unique_phone_digits_coach;
drop index if exists public.profiles_unique_phone_digits_client;
drop index if exists public.profiles_unique_phone_digits;

-- ---------------------------------------------------------------------------
-- Cancel fees. Money only. A cancel does not use the session.
-- ---------------------------------------------------------------------------

create or replace function public.cancel_fee_for(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  b record;
  starts timestamptz;
  hours numeric;
  late_hours integer := 12;
  close_hours integer := 4;
  late_cents integer := 1500;
  close_cents integer := 2500;
  sched jsonb;
  cents integer;
  kind text;
begin
  select date, slot_min, client_id
    into b
  from public.bookings
  where id = p_booking;
  if not found then
    return jsonb_build_object('cents', 0, 'kind', 'missing', 'returnsSession', true);
  end if;

  select data -> 'scheduling' into sched
  from public.platform_settings
  where id = 'global';

  -- A saved 24-hour / $25 row with no short window is the old default.
  if sched is not null and sched ? 'noShowCancelHours' then
    late_hours := coalesce((sched ->> 'lateCancellationHours')::integer, 12);
    close_hours := coalesce((sched ->> 'noShowCancelHours')::integer, 4);
    late_cents := coalesce((sched ->> 'lateCancellationFeeCents')::integer, 1500);
    close_cents := coalesce((sched ->> 'noShowFeeCents')::integer, 2500);
  end if;

  starts := (b.date::timestamp + make_interval(mins => b.slot_min)) at time zone 'America/Los_Angeles';
  hours := extract(epoch from (starts - now())) / 3600.0;
  if hours >= late_hours then
    cents := 0;
    kind := 'free';
  elsif hours >= close_hours then
    cents := late_cents;
    kind := 'late';
  else
    cents := close_cents;
    kind := 'close';
  end if;

  return jsonb_build_object(
    'cents', cents,
    'kind', kind,
    'returnsSession', true,
    'clientId', b.client_id
  );
end;
$$;

create or replace function public.attendance_fee_for(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  status text;
  clock jsonb;
  close_cents integer := 2500;
  sched jsonb;
begin
  select attendance_status into status from public.bookings where id = p_booking;
  if status is null then
    return jsonb_build_object('cents', 0, 'kind', 'none', 'returnsSession', true);
  end if;
  if status = 'early-cancel' then
    return jsonb_build_object('cents', 0, 'kind', 'free', 'returnsSession', true);
  end if;
  if status = 'late-cancel' then
    clock := public.cancel_fee_for(p_booking);
    return clock || jsonb_build_object('returnsSession', true);
  end if;
  if status = 'no-show' then
    select data -> 'scheduling' into sched from public.platform_settings where id = 'global';
    if sched is not null and sched ? 'noShowFeeCents' then
      close_cents := coalesce((sched ->> 'noShowFeeCents')::integer, 2500);
    end if;
    return jsonb_build_object('cents', close_cents, 'kind', 'noshow', 'returnsSession', false);
  end if;
  return jsonb_build_object('cents', 0, 'kind', 'none', 'returnsSession', true);
end;
$$;

revoke all on function public.cancel_fee_for(uuid) from public, anon, authenticated;
revoke all on function public.attendance_fee_for(uuid) from public, anon, authenticated;
grant execute on function public.cancel_fee_for(uuid) to service_role;
grant execute on function public.attendance_fee_for(uuid) to service_role;

alter table public.charges add column if not exists booking_id uuid;

create unique index if not exists charges_one_fee_per_booking
  on public.charges (booking_id)
  where booking_id is not null and type in ('late', 'noshow');

-- Write the new windows onto the settings row only when it still has the
-- old default (24 hours and $25) and has never stored the short window.
update public.platform_settings
set data = jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(coalesce(data, '{}'::jsonb), '{scheduling,lateCancellationHours}', '12'),
          '{scheduling,lateCancellationFeeCents}', '1500'),
        '{scheduling,noShowCancelHours}', '4'),
      '{scheduling,noShowFeeCents}', '2500')
where id = 'global'
  and coalesce(data #>> '{scheduling,noShowCancelHours}', '') = ''
  and coalesce(data #>> '{scheduling,lateCancellationHours}', '24') in ('24', '')
  and coalesce(data #>> '{scheduling,lateCancellationFeeCents}', '2500') in ('2500', '');

-- ---------------------------------------------------------------------------
-- One piece of a client record at a time
-- ---------------------------------------------------------------------------

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
  for k in select jsonb_object_keys(p_patch) loop
    if k not in (
      'nutrition', 'myMeals', 'savedNutritionPrograms',
      'measurements', 'trainerNotes', 'photos', 'intake'
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

create or replace function public.patch_client_intake(p_client uuid, p_assessment text, p_entry jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  row_data jsonb;
  intake jsonb;
begin
  if auth.role() is distinct from 'service_role'
     and auth.uid() is distinct from p_client
     and public.current_user_role() not in ('coach', 'owner') then
    raise exception 'Not allowed.';
  end if;
  if btrim(coalesce(p_assessment, '')) = '' then
    raise exception 'Which form?';
  end if;

  select data into row_data from public.client_records where profile_id = p_client for update;
  if row_data is null then
    insert into public.client_records (profile_id, data)
    values (p_client, jsonb_build_object('intake', jsonb_build_object(p_assessment, p_entry)));
    return;
  end if;
  intake := row_data -> 'intake';
  if intake is null or jsonb_typeof(intake) <> 'object' then
    intake := '{}'::jsonb;
  end if;
  intake := jsonb_set(intake, array[p_assessment], coalesce(p_entry, '{}'::jsonb), true);
  update public.client_records
     set data = jsonb_set(coalesce(row_data, '{}'::jsonb), '{intake}', intake, true)
   where profile_id = p_client;
end;
$$;

revoke all on function public.patch_client_record(uuid, jsonb) from public, anon;
revoke all on function public.patch_client_intake(uuid, text, jsonb) from public, anon;
grant execute on function public.patch_client_record(uuid, jsonb) to authenticated;
grant execute on function public.patch_client_intake(uuid, text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Private photos
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('progress-photos', 'progress-photos', false)
on conflict (id) do update set public = false;

insert into storage.buckets (id, name, public)
values ('intake-files', 'intake-files', false)
on conflict (id) do update set public = false;

create or replace function public.can_read_client_file(p_bucket text, p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public', 'storage'
as $$
declare
  folder text;
  client_id uuid;
begin
  if p_bucket not in ('progress-photos', 'intake-files') then
    return false;
  end if;
  folder := (storage.foldername(p_name))[1];
  begin
    client_id := folder::uuid;
  exception when others then
    return false;
  end;
  return public.coach_works_with_client(client_id);
end;
$$;

revoke all on function public.can_read_client_file(text, text) from public, anon;
grant execute on function public.can_read_client_file(text, text) to authenticated;

drop policy if exists progress_photos_select on storage.objects;
drop policy if exists progress_photos_insert on storage.objects;
drop policy if exists progress_photos_update on storage.objects;
drop policy if exists progress_photos_delete on storage.objects;
drop policy if exists intake_files_select on storage.objects;
drop policy if exists intake_files_insert on storage.objects;
drop policy if exists intake_files_update on storage.objects;
drop policy if exists intake_files_delete on storage.objects;

create policy progress_photos_select on storage.objects
  for select to authenticated
  using (bucket_id = 'progress-photos' and public.can_read_client_file(bucket_id, name));
create policy progress_photos_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'progress-photos' and public.can_read_client_file(bucket_id, name));
create policy progress_photos_update on storage.objects
  for update to authenticated
  using (bucket_id = 'progress-photos' and public.can_read_client_file(bucket_id, name))
  with check (bucket_id = 'progress-photos' and public.can_read_client_file(bucket_id, name));
create policy progress_photos_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'progress-photos' and public.can_read_client_file(bucket_id, name));

create policy intake_files_select on storage.objects
  for select to authenticated
  using (bucket_id = 'intake-files' and public.can_read_client_file(bucket_id, name));
create policy intake_files_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'intake-files' and public.can_read_client_file(bucket_id, name));
create policy intake_files_update on storage.objects
  for update to authenticated
  using (bucket_id = 'intake-files' and public.can_read_client_file(bucket_id, name))
  with check (bucket_id = 'intake-files' and public.can_read_client_file(bucket_id, name));
create policy intake_files_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'intake-files' and public.can_read_client_file(bucket_id, name));

-- ---------------------------------------------------------------------------
-- Hourly job password, read from Vault. The value is not in this file.
--
-- Before this job can run, Coach Chris creates one Vault secret:
--   Name: apply_requests_cron
--   Value: a long random password he chooses and does not put in the app
-- The old edge-function secret APPLY_REQUESTS_SECRET is no longer used.
-- ---------------------------------------------------------------------------

create or replace function public.cron_vault_secret()
returns text
language sql
stable
security definer
set search_path to 'public', 'vault'
as $$
  select decrypted_secret
  from vault.decrypted_secrets
  where name = 'apply_requests_cron'
  limit 1;
$$;

revoke all on function public.cron_vault_secret() from public, anon, authenticated;
grant execute on function public.cron_vault_secret() to service_role;

do $$
declare
  existing bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_extension where extname = 'pg_net') then
    select jobid into existing from cron.job where jobname = 'apply-due-requests';
    if existing is not null then
      perform cron.unschedule(existing);
    end if;
    perform cron.schedule(
      'apply-due-requests',
      '0 * * * *',
      $cron$
      select net.http_post(
        url := 'https://rivhgutksyddeckieknc.supabase.co/functions/v1/apply-due-requests',
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
    raise notice 'pg_cron or pg_net is not enabled, so the hourly job was not scheduled. Enable both extensions, then run this file again.';
  end if;
end $$;

notify pgrst, 'reload schema';
