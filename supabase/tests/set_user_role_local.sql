-- Local test for set_user_role (20261126120000_owner_set_user_role.sql).
-- Not for the live database: it makes throwaway tables and roles, so run it
-- only against an empty scratch Postgres, from the repository root:
--
--   createdb rt && psql -d rt -v ON_ERROR_STOP=1 -f supabase/tests/set_user_role_local.sql
--
-- Part 1 stubs just enough of the live shape (profiles, trainers, clients,
-- client_records, bookings, activity_log, and the three live triggers that
-- fire on a role change). Part 2 runs the checks and prints what happened:
-- every refusal reads "ERR ...", every success "OK {...}".
-- Expected: scenarios 1-8 are ERR (only the owner; not the owner's own
-- account; Client or Coach only; unknown account), 9-13 are OK, rows and
-- bookings are kept, no-op writes no log row, anon has no EXECUTE.

create schema if not exists auth;
create or replace function auth.role() returns text language sql stable as $$ select coalesce(current_setting('test.role', true), 'authenticated') $$;
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
do $$ declare r text; begin
  foreach r in array array['authenticated','anon','service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I', r); end if;
  end loop;
end $$;
create table public.profiles (id uuid primary key, role text check (role in ('owner','coach','client')), name text, deleted_at timestamptz);
create table public.trainers (profile_id uuid primary key references public.profiles(id), reviewed_by_owner boolean default false, signup_at date, coach_name text, commission_rate numeric default 0);
create table public.clients (profile_id uuid primary key references public.profiles(id), membership_plan_id text, stripe_subscription_id text, primary_trainer_id uuid references public.trainers(profile_id), balance_cents int default 0);
create table public.client_records (profile_id uuid primary key references public.clients(profile_id) on delete cascade, data jsonb not null default '{}');
create table public.bookings (id uuid primary key default gen_random_uuid(), client_id uuid, trainer_id uuid references public.trainers(profile_id) on delete cascade, date date, cancelled_at timestamptz);
create table public.activity_log (id uuid primary key default gen_random_uuid(), at timestamptz not null default now(), actor_id uuid references public.profiles(id) on delete set null, actor_name text, action text not null, entity text not null, entity_id text, subject text, summary text not null, details jsonb);
create or replace function public.current_user_role() returns text language sql stable security definer set search_path to 'public' as $$ select p.role from public.profiles p where p.id = auth.uid() and p.deleted_at is null $$;
create or replace function public.prevent_role_escalation() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.role is distinct from old.role and public.current_user_role() is distinct from 'owner' and coalesce(current_setting('app.coach_code_grant', true), '') is distinct from 'on' then new.role := old.role; end if;
  return new; end; $$;
create trigger trg_prevent_role_escalation before update on public.profiles for each row execute function public.prevent_role_escalation();
create or replace function public.ensure_client_row() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin if new.role = 'client' then insert into public.clients (profile_id) values (new.id) on conflict (profile_id) do nothing; end if; return new; end; $$;
create trigger trg_ensure_client_row after insert or update of role on public.profiles for each row execute function public.ensure_client_row();
create or replace function public.trainers_guard_role_and_pay() returns trigger language plpgsql security definer set search_path to 'public' as $$
declare their_role text;
begin
  if auth.role() is distinct from 'service_role' and public.current_user_role() is distinct from 'owner' then
    select role into their_role from public.profiles where id = new.profile_id;
    if their_role is distinct from 'coach' then raise exception 'Only a coach account can have a coach profile.'; end if;
  end if; return new; end; $$;
create trigger trainers_guard_role_and_pay before insert or update on public.trainers for each row execute function public.trainers_guard_role_and_pay();
grant usage on schema public, auth to authenticated, anon, service_role;

\set ON_ERROR_STOP 0
\set owner '00000000-0000-0000-0000-00000000000f'
\set coach '00000000-0000-0000-0000-00000000000c'
\set cl1 '00000000-0000-0000-0000-0000000000a1'
\set cl2 '00000000-0000-0000-0000-0000000000a2'
insert into profiles values (:'owner','owner','Olive Owner',null),(:'coach','coach','Cole Coach',null),(:'cl1','client','Cara Client',null),(:'cl2','client','Max Member',null);
insert into trainers(profile_id, reviewed_by_owner, signup_at, coach_name) values (:'coach', true, current_date, 'Coach Cole');
update clients set stripe_subscription_id='sub_x', membership_plan_id='gold', balance_cents=500 where profile_id=:'cl2';
insert into client_records(profile_id,data) values (:'cl2','{"logs":[1,2,3]}');
insert into bookings(client_id, trainer_id, date) values (:'cl1', :'coach', current_date+2),(:'cl1', :'coach', current_date+3),(:'cl1', :'coach', current_date-30);
insert into bookings(client_id, trainer_id, date, cancelled_at) values (:'cl1', :'coach', current_date+4, now());
grant select, insert, update, delete on all tables in schema public to authenticated;  -- like RLS-open for test; function is definer anyway
\i supabase/migrations/20261126120000_owner_set_user_role.sql
create or replace function t(label text, uid text, role text, target uuid, newrole text) returns void language plpgsql as $$
declare r jsonb; begin
  perform set_config('test.uid', coalesce(uid,''), false); perform set_config('test.role', role, false);
  if role='anon' then set local role anon; else set local role authenticated; end if;
  begin r := public.set_user_role(target, newrole); raise notice '% -> OK %', label, r;
  exception when others then raise notice '% -> ERR %', label, sqlerrm; end;
  reset role;
end $$;
select t('1 coach tries', :'coach', 'authenticated', :'cl1', 'coach');
select t('2 client tries on self', :'cl1', 'authenticated', :'cl1', 'coach');
select t('3 anon', null, 'anon', :'cl1', 'coach');
select t('4 service_role no uid', null, 'service_role', :'cl1', 'coach');
select t('5 owner targets self', :'owner', 'authenticated', :'owner', 'client');
select t('6 owner -> owner', :'owner', 'authenticated', :'cl1', 'owner');
select t('7 owner bad role', :'owner', 'authenticated', :'cl1', 'admin');
select t('8 missing user', :'owner', 'authenticated', '00000000-0000-0000-0000-0000000000ff', 'coach');
select 'before', (select role from profiles where id=:'cl1') cl1_role, (select count(*) from activity_log) logs;
select t('9 client with plan -> trainer alias', :'owner', 'authenticated', :'cl2', 'trainer');
select 'cl2 after', p.role, (select count(*) from trainers where profile_id=p.id) trainers_row, (select count(*) from clients where profile_id=p.id) clients_row, (select balance_cents from clients where profile_id=p.id) bal, (select stripe_subscription_id from clients where profile_id=p.id) sub, (select count(*) from client_records where profile_id=p.id) recs from profiles p where p.id=:'cl2';
select t('10 same role no-op', :'owner', 'authenticated', :'cl2', 'coach');
select 'logs after noop', count(*) from activity_log;
select t('11 coach with sessions -> client', :'owner', 'authenticated', :'coach', 'client');
select 'coach after', p.role, (select count(*) from trainers where profile_id=p.id) trainers_row, (select count(*) from clients where profile_id=p.id) clients_row, (select count(*) from client_records where profile_id=p.id) recs, (select count(*) from bookings where trainer_id=p.id) bookings_kept from profiles p where p.id=:'coach';
select t('12 promote cl1 -> coach', :'owner', 'authenticated', :'cl1', 'Coach');
select 'cl1 after', p.role, (select count(*) from trainers where profile_id=p.id and reviewed_by_owner) trainers_row, (select count(*) from clients where profile_id=p.id) clients_row from profiles p where p.id=:'cl1';
select t('13 re-promote former coach reuses row', :'owner', 'authenticated', :'coach', 'coach');
select 'coach re-promoted', (select count(*) from trainers where profile_id=:'coach') trainers_rows, (select coach_name from trainers where profile_id=:'coach') kept_name, (select count(*) from bookings where trainer_id=:'coach') bookings;
select action, entity, subject, summary, details->>'oldRole' o, details->>'newRole' n, details->>'upcomingSessionsAsCoach' up, details->>'hadMembership' mem, actor_name, (at is not null) has_time from activity_log order by at;
-- anon/public cannot even see the function
select has_function_privilege('anon','public.set_user_role(uuid,text)','execute') anon_exec, has_function_privilege('authenticated','public.set_user_role(uuid,text)','execute') auth_exec, has_function_privilege('public','public.set_user_role(uuid,text)','execute') public_exec;
-- running the migration twice is safe
\i supabase/migrations/20261126120000_owner_set_user_role.sql
