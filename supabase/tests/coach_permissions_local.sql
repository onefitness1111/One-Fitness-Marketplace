-- Local test for 20261126140000_coach_permissions.sql.
-- Not for the live database: it makes throwaway tables and roles. Run it only
-- against an empty scratch Postgres, from the repository root:
--
--   createdb cp && psql -d cp -v ON_ERROR_STOP=1 -f supabase/tests/coach_permissions_local.sql
--
-- Part 1 stubs the live tables the migration touches. Part 2 loads the
-- migration. Part 3 acts as the owner, coaches and a client and prints one
-- line per check: "PASS name" or "FAIL name". The last line is
-- "RESULT n passed, m failed"; m must be 0.

create schema if not exists auth;
create or replace function auth.role() returns text language sql stable as $$ select coalesce(current_setting('test.role', true), 'authenticated') $$;
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
do $$ declare r text; begin
  foreach r in array array['authenticated','anon','service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I', r); end if;
  end loop;
end $$;
grant usage on schema public, auth to authenticated, anon, service_role;

create table public.profiles (id uuid primary key, role text check (role in ('owner','coach','client')), name text, deleted_at timestamptz);
create table public.trainers (profile_id uuid primary key references public.profiles(id), commission_rate numeric default 0.5, payout_mode text, payout_rate_cents int, referral_commission_percent numeric);
create table public.clients (profile_id uuid primary key references public.profiles(id), membership_plan_id text, plans jsonb, session_count_override int, session_count_override_month text, membership_cancels_at date, city text, state text, billing_address jsonb);
create table public.bookings (id uuid primary key default gen_random_uuid(), client_id uuid, trainer_id uuid references public.trainers(profile_id), date date);
create table public.charges (id uuid primary key default gen_random_uuid(), client_id uuid, trainer_id uuid, amount_cents int);
create table public.orders (id uuid primary key default gen_random_uuid(), client_id uuid, total_cents int, status text);
create table public.messages (id uuid primary key default gen_random_uuid(), who text, sender_id uuid, channel text, body text);
create table public.activity_log (id uuid primary key default gen_random_uuid(), at timestamptz not null default now(), actor_id uuid references public.profiles(id) on delete set null, actor_name text, action text not null, entity text not null, entity_id text, subject text, summary text not null, details jsonb);
create or replace function public.current_user_role() returns text language sql stable security definer set search_path to 'public' as $$ select p.role from public.profiles p where p.id = auth.uid() and p.deleted_at is null $$;
create or replace function public.is_owner() returns boolean language sql stable security definer set search_path to 'public' as $$ select coalesce(public.current_user_role() = 'owner', false) $$;
alter table public.bookings enable row level security;
alter table public.charges enable row level security;
alter table public.orders enable row level security;
create policy bookings_select_all on public.bookings for select to authenticated using (true);
grant select, insert, update, delete on public.bookings, public.charges, public.orders, public.messages, public.clients, public.trainers, public.profiles to authenticated;
grant select on public.activity_log to authenticated;
grant all on public.messages to service_role;

-- people: owner, one coach that exists before the migration, a client
insert into public.profiles values
  ('00000000-0000-0000-0000-0000000000a1', 'owner', 'Owner', null),
  ('00000000-0000-0000-0000-0000000000c1', 'coach', 'Coach One', null),
  ('00000000-0000-0000-0000-0000000000d1', 'client', 'Client One', null),
  ('00000000-0000-0000-0000-0000000000d2', 'client', 'Client Two', null);
insert into public.trainers (profile_id) values ('00000000-0000-0000-0000-0000000000c1');
insert into public.clients (profile_id, plans, billing_address) values
  ('00000000-0000-0000-0000-0000000000d1', '[]'::jsonb, null),
  ('00000000-0000-0000-0000-0000000000d2', '[]'::jsonb, '{"line1":"1 Main","city":"Reno","state":"NV"}'::jsonb);

\i supabase/migrations/20261126140000_coach_permissions.sql
-- applying it twice must be safe
\i supabase/migrations/20261126140000_coach_permissions.sql

-- a coach added after the migration
insert into public.profiles values ('00000000-0000-0000-0000-0000000000c2', 'coach', 'Coach Two', null);
insert into public.trainers (profile_id) values ('00000000-0000-0000-0000-0000000000c2');

create table public.t_results (name text, ok boolean);
grant all on public.t_results to public;
create or replace function public.t_check(p_name text, p_ok boolean) returns void language plpgsql as $$
begin insert into public.t_results values (p_name, coalesce(p_ok, false)); end $$;
create or replace function public.t_fails(p_name text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; insert into public.t_results values (p_name, false);
  exception when others then insert into public.t_results values (p_name, true); end;
end $$;
create or replace function public.t_works(p_name text, p_sql text) returns void language plpgsql as $$
begin
  begin execute p_sql; insert into public.t_results values (p_name, true);
  exception when others then insert into public.t_results values (p_name, false); end;
end $$;
create or replace function public.t_rowcount(p_sql text) returns int language plpgsql as $$
declare n int; begin execute p_sql; get diagnostics n = row_count; return n; end $$;
grant execute on function public.t_check(text, boolean), public.t_fails(text, text), public.t_works(text, text), public.t_rowcount(text) to public;
\o /dev/null

-- data to read as each person (written as the table owner, before any role switch)
insert into public.bookings (client_id, trainer_id, date) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c1', '2026-11-10'),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000c2', '2026-11-11'),
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c2', '2026-12-30');
insert into public.charges (client_id, trainer_id, amount_cents) values
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c1', 1000),
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000c2', 2000);
insert into public.orders (client_id, total_cents, status) values ('00000000-0000-0000-0000-0000000000d1', 500, 'paid');

-- ===== defaults and backfill (as the table owner)
select public.t_check('backfill: existing coach has all six on',
  (select billing_access and charge_fees and edit_plans and send_texts and manage_other_schedules and see_own_revenue
   from public.coach_permissions where profile_id = '00000000-0000-0000-0000-0000000000c1'));
select public.t_check('default: new coach has all six off',
  (select not (billing_access or charge_fees or edit_plans or send_texts or manage_other_schedules or see_own_revenue)
   from public.coach_permissions where profile_id = '00000000-0000-0000-0000-0000000000c2'));
select public.t_check('no row for owner or client',
  (select count(*) = 0 from public.coach_permissions where profile_id in ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000d1')));

-- ===== helper has_coach_permission
set test.role = 'authenticated';
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.t_check('helper: owner has everything', public.has_coach_permission('00000000-0000-0000-0000-0000000000a1', 'charge_fees'));
select public.t_check('helper: owner may look up a coach', public.has_coach_permission('00000000-0000-0000-0000-0000000000c1', 'charge_fees'));
select public.t_check('helper: unknown permission is false', not public.has_coach_permission('00000000-0000-0000-0000-0000000000a1', 'nope'));
select public.t_check('helper: unknown coach row is false', not public.has_coach_permission('00000000-0000-0000-0000-0000000000c2', 'charge_fees'));
set test.uid = '00000000-0000-0000-0000-0000000000c2';
select public.t_check('helper: coach asks about someone else -> false', not public.has_coach_permission('00000000-0000-0000-0000-0000000000c1', 'charge_fees'));
select public.t_check('helper: new coach asks about self -> false', not public.has_coach_permission('00000000-0000-0000-0000-0000000000c2', 'send_texts'));
set test.uid = '00000000-0000-0000-0000-0000000000d1';
select public.t_check('helper: client has nothing', not public.has_coach_permission('00000000-0000-0000-0000-0000000000d1', 'send_texts'));

-- ===== setter and RLS on the table
set test.uid = '00000000-0000-0000-0000-0000000000c1';
select public.t_fails('setter: a coach cannot use it (even on self)', $q$select public.set_coach_permission('00000000-0000-0000-0000-0000000000c1', 'charge_fees', true)$q$);
select public.t_check('table: a coach cannot update their own row (0 rows)', public.t_rowcount($q$update public.coach_permissions set charge_fees = true where profile_id = '00000000-0000-0000-0000-0000000000c1'$q$) = 0);
select public.t_fails('table: a coach cannot insert a row', $q$insert into public.coach_permissions (profile_id, charge_fees) values ('00000000-0000-0000-0000-0000000000d1', true)$q$);
select public.t_check('table: a coach cannot delete their row (0 rows)', public.t_rowcount($q$delete from public.coach_permissions where profile_id = '00000000-0000-0000-0000-0000000000c1'$q$) = 0);
select public.t_check('table: a coach reads only their own row', (select count(*) = 1 from public.coach_permissions));
set test.uid = '00000000-0000-0000-0000-0000000000d1';
select public.t_check('table: a client reads no rows', (select count(*) = 0 from public.coach_permissions));
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.t_check('table: owner reads every row', (select count(*) = 2 from public.coach_permissions));
select public.t_fails('setter: unknown permission', $q$select public.set_coach_permission('00000000-0000-0000-0000-0000000000c1', 'primary_trainer_id', true)$q$);
select public.t_fails('setter: not a coach (client)', $q$select public.set_coach_permission('00000000-0000-0000-0000-0000000000d1', 'send_texts', true)$q$);
select public.t_fails('setter: not a coach (owner)', $q$select public.set_coach_permission('00000000-0000-0000-0000-0000000000a1', 'send_texts', true)$q$);
select public.t_fails('setter: missing person', $q$select public.set_coach_permission('00000000-0000-0000-0000-0000000000ff', 'send_texts', true)$q$);
select public.t_fails('setter: null value', $q$select public.set_coach_permission('00000000-0000-0000-0000-0000000000c1', 'send_texts', null)$q$);
select public.t_works('setter: owner turns billing_access off for coach one', $q$select public.set_coach_permission('00000000-0000-0000-0000-0000000000c1', 'billing_access', false)$q$);
select public.t_check('setter: only that switch changed',
  (select not billing_access and charge_fees and edit_plans and send_texts and manage_other_schedules and see_own_revenue and updated_by = '00000000-0000-0000-0000-0000000000a1'
   from public.coach_permissions where profile_id = '00000000-0000-0000-0000-0000000000c1'));
select public.t_check('setter: wrote one activity row', (select count(*) = 1 from public.activity_log where entity = 'permissions' and details->>'permission' = 'billing_access' and (details->>'allowed')::boolean = false));
select public.t_check('setter: other coach untouched',
  (select not (billing_access or charge_fees) from public.coach_permissions where profile_id = '00000000-0000-0000-0000-0000000000c2'));
select public.t_works('table: owner can also write the row directly', $q$update public.coach_permissions set send_texts = false where profile_id = '00000000-0000-0000-0000-0000000000c1'$q$);
select public.t_works('setter: owner restores send_texts', $q$select public.set_coach_permission('00000000-0000-0000-0000-0000000000c1', 'send_texts', true)$q$);
set role anon;
select public.t_fails('setter: anon has no execute', $q$select public.set_coach_permission('00000000-0000-0000-0000-0000000000c1', 'send_texts', true)$q$);
reset role;
set role authenticated;

-- ===== see_own_revenue: charges, orders, pay rates
set test.uid = '00000000-0000-0000-0000-0000000000c1';
select public.t_check('revenue on: coach one sees only own charges', (select count(*) = 1 and bool_and(trainer_id = '00000000-0000-0000-0000-0000000000c1') from public.charges));
select public.t_check('revenue on: coach reads own pay row', (select count(*) = 1 from public.trainer_pay_for(array['00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000c2'::uuid])));
select public.t_check('orders: a coach sees no orders', (select count(*) = 0 from public.orders));
select public.t_check('orders: a coach changes no orders', public.t_rowcount($q$update public.orders set status = 'x'$q$) = 0);
set test.uid = '00000000-0000-0000-0000-0000000000c2';
select public.t_check('revenue off: new coach sees no charges', (select count(*) = 0 from public.charges));
select public.t_check('revenue off: new coach gets no pay row', (select count(*) = 0 from public.trainer_pay_for(array['00000000-0000-0000-0000-0000000000c2'::uuid])));
set test.uid = '00000000-0000-0000-0000-0000000000d1';
select public.t_check('client sees own charge and order', (select count(*) = 1 from public.charges) and (select count(*) = 1 from public.orders));
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.t_check('owner sees all charges and orders', (select count(*) = 2 from public.charges) and (select count(*) = 1 from public.orders));
select public.t_check('owner reads every pay row', (select count(*) = 2 from public.trainer_pay_for(array['00000000-0000-0000-0000-0000000000c1'::uuid, '00000000-0000-0000-0000-0000000000c2'::uuid])));
select public.t_works('setter: owner turns see_own_revenue on for coach two', $q$select public.set_coach_permission('00000000-0000-0000-0000-0000000000c2', 'see_own_revenue', true)$q$);
set test.uid = '00000000-0000-0000-0000-0000000000c2';
select public.t_check('revenue on: coach two now sees only their own charge', (select count(*) = 1 and bool_and(trainer_id = '00000000-0000-0000-0000-0000000000c2') from public.charges));

-- ===== report scoping (no switch)
set test.uid = '00000000-0000-0000-0000-0000000000c1';
select public.t_check('reports: coach one gets only own sessions', (select count(*) = 1 and bool_and(trainer_id = '00000000-0000-0000-0000-0000000000c1') from public.coach_report_bookings('2026-01-01', '2026-12-31')));
select public.t_check('reports: coach one clients = client one only', (select count(*) = 1 and bool_and(client_id = '00000000-0000-0000-0000-0000000000d1') from public.coach_report_client_ids()));
set test.uid = '00000000-0000-0000-0000-0000000000c2';
select public.t_check('reports: coach two gets two sessions in range', (select count(*) = 2 from public.coach_report_bookings('2026-01-01', '2026-12-31')));
select public.t_check('reports: date range respected', (select count(*) = 1 from public.coach_report_bookings('2026-12-01', '2026-12-31')));
select public.t_check('reports: coach two clients = both', (select count(*) = 2 from public.coach_report_client_ids()));
set test.uid = '00000000-0000-0000-0000-0000000000d1';
select public.t_check('reports: a client gets nothing', (select count(*) = 0 from public.coach_report_bookings('2026-01-01', '2026-12-31')) and (select count(*) = 0 from public.coach_report_client_ids()));
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.t_check('reports: owner gets every session and client', (select count(*) = 3 from public.coach_report_bookings('2026-01-01', '2026-12-31')) and (select count(*) = 2 from public.coach_report_client_ids()));

-- ===== billing_access
set test.uid = '00000000-0000-0000-0000-0000000000c1'; -- billing_access now OFF
select public.t_check('billing off: locality is empty', (select city is null and state is null from public.client_billing_locality('00000000-0000-0000-0000-0000000000d2')));
select public.t_fails('billing off: cannot set an address', $q$select public.set_client_billing_address('00000000-0000-0000-0000-0000000000d1', '{"line1":"2 Oak","city":"Reno","state":"NV"}'::jsonb)$q$);
set test.uid = '00000000-0000-0000-0000-0000000000c2'; -- billing_access OFF too
select public.t_fails('billing off (new coach): cannot set an address', $q$select public.set_client_billing_address('00000000-0000-0000-0000-0000000000d1', '{"line1":"2 Oak","city":"Reno","state":"NV"}'::jsonb)$q$);
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.t_works('setter: owner turns billing_access on for coach two', $q$select public.set_coach_permission('00000000-0000-0000-0000-0000000000c2', 'billing_access', true)$q$);
set test.uid = '00000000-0000-0000-0000-0000000000c2';
select public.t_check('billing on: locality visible', (select city = 'Reno' and state = 'NV' from public.client_billing_locality('00000000-0000-0000-0000-0000000000d2')));
select public.t_works('billing on: can fill an empty address', $q$select public.set_client_billing_address('00000000-0000-0000-0000-0000000000d1', '{"line1":"2 Oak","city":"Reno","state":"NV"}'::jsonb)$q$);
select public.t_fails('billing on: still cannot replace an address on file', $q$select public.set_client_billing_address('00000000-0000-0000-0000-0000000000d2', '{"line1":"9 Elm","city":"Sparks","state":"NV"}'::jsonb)$q$);
set test.uid = '00000000-0000-0000-0000-0000000000d1';
select public.t_works('billing: a client can still set their own address', $q$select public.set_client_billing_address('00000000-0000-0000-0000-0000000000d1', '{"line1":"3 Pine","city":"Reno","state":"NV"}'::jsonb)$q$);

-- ===== edit_plans (direct writes by a coach)
set test.uid = '00000000-0000-0000-0000-0000000000c2'; -- edit_plans OFF
select public.t_fails('plans off: coach cannot change plans', $q$update public.clients set plans = '[{"id":"x"}]'::jsonb where profile_id = '00000000-0000-0000-0000-0000000000d1'$q$);
select public.t_fails('plans off: coach cannot change the plan id', $q$update public.clients set membership_plan_id = 'p1' where profile_id = '00000000-0000-0000-0000-0000000000d1'$q$);
select public.t_fails('plans off: coach cannot change sessions left', $q$update public.clients set session_count_override = 5 where profile_id = '00000000-0000-0000-0000-0000000000d1'$q$);
select public.t_works('plans off: coach can still change other client fields', $q$update public.clients set city = 'Reno' where profile_id = '00000000-0000-0000-0000-0000000000d1'$q$);
set test.uid = '00000000-0000-0000-0000-0000000000c1'; -- edit_plans ON (backfill)
select public.t_works('plans on: coach can change plans', $q$update public.clients set plans = '[{"id":"x"}]'::jsonb where profile_id = '00000000-0000-0000-0000-0000000000d1'$q$);
set test.uid = '00000000-0000-0000-0000-0000000000d1';
select public.t_works('plans: a client changes their own', $q$update public.clients set membership_plan_id = 'p2' where profile_id = '00000000-0000-0000-0000-0000000000d1'$q$);
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.t_works('plans: owner changes any', $q$update public.clients set membership_plan_id = 'p3' where profile_id = '00000000-0000-0000-0000-0000000000d1'$q$);
reset role;
select public.t_works('plans: server code (table owner) is not blocked', $q$update public.clients set plans = '[]'::jsonb where profile_id = '00000000-0000-0000-0000-0000000000d1'$q$);
set role authenticated;

-- ===== send_texts (the saved channel)
set test.uid = '00000000-0000-0000-0000-0000000000c2'; -- send_texts OFF
insert into public.messages (who, sender_id, channel, body) values
  ('trainer', '00000000-0000-0000-0000-0000000000c2', 'inapp,sms', 'a'),
  ('trainer', '00000000-0000-0000-0000-0000000000c2', 'sms', 'b'),
  ('trainer', '00000000-0000-0000-0000-0000000000c2', 'both', 'c'),
  ('trainer', '00000000-0000-0000-0000-0000000000c2', 'inapp', 'd'),
  ('trainer', '00000000-0000-0000-0000-0000000000c2', 'inapp,email', 'e');
set test.uid = '00000000-0000-0000-0000-0000000000c1'; -- send_texts ON
insert into public.messages (who, sender_id, channel, body) values ('trainer', '00000000-0000-0000-0000-0000000000c1', 'inapp,sms', 'f');
set test.uid = '00000000-0000-0000-0000-0000000000a1';
insert into public.messages (who, sender_id, channel, body) values ('trainer', '00000000-0000-0000-0000-0000000000a1', 'inapp,sms', 'g');
set test.uid = '00000000-0000-0000-0000-0000000000d1';
insert into public.messages (who, sender_id, channel, body) values ('client', '00000000-0000-0000-0000-0000000000d1', 'inapp', 'h');
reset role;
select public.t_check('sms off: inapp,sms -> inapp', (select channel = 'inapp' from public.messages where body = 'a'));
select public.t_check('sms off: sms only -> inapp', (select channel = 'inapp' from public.messages where body = 'b'));
select public.t_check('sms off: both -> inapp,email', (select channel in ('inapp,email','email,inapp') from public.messages where body = 'c'));
select public.t_check('sms off: inapp untouched', (select channel = 'inapp' from public.messages where body = 'd'));
select public.t_check('sms off: inapp,email untouched', (select channel = 'inapp,email' from public.messages where body = 'e'));
select public.t_check('sms on: coach one keeps sms', (select channel = 'inapp,sms' from public.messages where body = 'f'));
select public.t_check('sms: owner keeps sms', (select channel = 'inapp,sms' from public.messages where body = 'g'));
-- the server (service role) is never rewritten
set test.role = 'service_role';
insert into public.messages (who, sender_id, channel, body) values ('trainer', '00000000-0000-0000-0000-0000000000c2', 'inapp,sms', 'i');
set test.role = 'authenticated';
select public.t_check('sms: service role untouched', (select channel = 'inapp,sms' from public.messages where body = 'i'));

-- ===== manage_other_schedules (bookings insert)
set role authenticated;
set test.uid = '00000000-0000-0000-0000-0000000000c1'; -- manage_other_schedules ON
select public.t_works('schedules on: coach one books onto coach two', $q$insert into public.bookings (client_id, trainer_id, date) values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c2', '2026-12-01')$q$);
select public.t_works('schedules: coach books onto own calendar', $q$insert into public.bookings (client_id, trainer_id, date) values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c1', '2026-12-02')$q$);
set test.uid = '00000000-0000-0000-0000-0000000000c2'; -- OFF
select public.t_fails('schedules off: coach two cannot book onto coach one', $q$insert into public.bookings (client_id, trainer_id, date) values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c1', '2026-12-03')$q$);
select public.t_works('schedules off: coach two can still book onto own calendar', $q$insert into public.bookings (client_id, trainer_id, date) values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c2', '2026-12-04')$q$);
set test.uid = '00000000-0000-0000-0000-0000000000d1';
select public.t_works('schedules: a client books themselves with any coach', $q$insert into public.bookings (client_id, trainer_id, date) values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000c1', '2026-12-05')$q$);
select public.t_fails('schedules: a client cannot book for someone else', $q$insert into public.bookings (client_id, trainer_id, date) values ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000c1', '2026-12-06')$q$);
set test.uid = '00000000-0000-0000-0000-0000000000a1';
select public.t_works('schedules: owner books anywhere', $q$insert into public.bookings (client_id, trainer_id, date) values ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-0000000000c1', '2026-12-07')$q$);
reset role;

\o
select case when ok then 'PASS ' else 'FAIL ' end || name as line from public.t_results order by ok, name;
select 'RESULT ' || count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' as line from public.t_results;
