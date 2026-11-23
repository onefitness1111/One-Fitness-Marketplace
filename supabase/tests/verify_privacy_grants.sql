-- Verifies the least-privilege reads on profiles, clients, and trainers
-- (migration 20261123020000) as anon, a client, a coach, and the owner.
--
-- One DO block. It always ends by raising an error that carries the report,
-- so nothing it does (including the no-op updates it tries) is ever kept.
-- To dry-run the migration first, paste its statements at the
-- "-- @@MIGRATION@@" marker (the dry-run runner does this).
--
-- Test members are picked automatically (oldest active owner, coach,
-- and two clients with a phone on file; client 5ac0e6b7 is never used).
-- The report prints only check names and PASS/FAIL, never member data.
-- Function checks filter on the result ("where a is null or a is not null")
-- so the planner can't skip calling the function.
do $verify$
declare
  v_c uuid; v_x uuid; v_k uuid; v_o uuid;
  chk record;
  cur text := '';
  got text;
  ok boolean;
  pass int := 0;
  fail int := 0;
  report text := '';
  stmt text;
begin
  -- @@MIGRATION@@

  select id into v_o from public.profiles where role = 'owner' and deleted_at is null order by created_at limit 1;
  select p.id into v_k from public.profiles p join public.trainers t on t.profile_id = p.id
   where p.role = 'coach' and p.deleted_at is null and p.banned_at is null order by p.created_at limit 1;
  select p.id into v_c from public.profiles p join public.clients c on c.profile_id = p.id
   where p.role = 'client' and p.deleted_at is null and coalesce(p.phone, '') <> ''
     and p.id::text not like '5ac0e6b7%' order by p.created_at limit 1;
  select p.id into v_x from public.profiles p join public.clients c on c.profile_id = p.id
   where p.role = 'client' and p.deleted_at is null and p.id <> v_c
     and p.id::text not like '5ac0e6b7%' order by p.created_at limit 1;
  if v_o is null or v_k is null or v_c is null or v_x is null then
    raise exception 'verify: could not pick test members';
  end if;

  for chk in
    select * from (values
      (1, 'anon', $q$anon cannot read profiles$q$, $q$select count(id) from public.profiles$q$, 'denied'),
      (2, 'anon', $q$anon cannot read clients$q$, $q$select count(profile_id) from public.clients$q$, 'denied'),
      (3, 'anon', $q$anon cannot read trainers$q$, $q$select count(profile_id) from public.trainers$q$, 'denied'),
      (4, 'client', $q$client reads own terms fields (sign-in)$q$, $q$select count(*) from (select accepted_terms_at, accepted_terms_version from public.profiles where id = '{C}') s$q$, '1'),
      (5, 'client', $q$client reads own client row, app columns$q$, $q$select count(*) from (select profile_id, birthday, city, state, home_lat, home_lng, membership_plan_id, primary_trainer_id, plans, tour_seen, membership_paused, membership_paused_at, membership_paused_days, updated_at, custom_fields, membership_freeze_ends_at, session_count_override, pending_plan_id, pending_plan_effective_at, session_count_override_month, membership_cancels_at, referred_by_trainer_id, coach_code_alert_seen, sms_opt_in, redeem_points_next_renewal, marketing_opt_out, sms_opt_in_at, sms_consent_text, emergency_contact_name, booking_restricted, booking_restricted_reason from public.clients where profile_id = '{C}') s$q$, '1'),
      (6, 'client', $q$client reads own sms_opt_in$q$, $q$select count(*) from (select sms_opt_in from public.clients where profile_id = '{C}') s$q$, '1'),
      (7, 'client', $q$client cannot see another client's row$q$, $q$select count(*) from (select profile_id, birthday, city, state, home_lat, home_lng, membership_plan_id, primary_trainer_id, plans, tour_seen, membership_paused, membership_paused_at, membership_paused_days, updated_at, custom_fields, membership_freeze_ends_at, session_count_override, pending_plan_id, pending_plan_effective_at, session_count_override_month, membership_cancels_at, referred_by_trainer_id, coach_code_alert_seen, sms_opt_in, redeem_points_next_renewal, marketing_opt_out, sms_opt_in_at, sms_consent_text, emergency_contact_name, booking_restricted, booking_restricted_reason from public.clients where profile_id = '{X}') s$q$, '0'),
      (8, 'client', $q$client reads coach list, app columns$q$, $q$select count(*) from (select profile_id, disciplines, session_types, slot_interval, availability, programmer_availability, locations, bio, before_afters, avail_lock_until, signup_at, reviewed_by_owner, updated_at, coach_code, unavailability, title, coach_name from public.trainers) s$q$, '>0'),
      (9, 'client', $q$client reads coach list, dashboard columns$q$, $q$select count(*) from (select profile_id, disciplines, session_types, slot_interval, availability, locations, avail_lock_until, signup_at, reviewed_by_owner, updated_at, coach_code, unavailability, title, coach_name from public.trainers) s$q$, '>0'),
      (10, 'client', $q$coach-code lookup at sign-up works$q$, $q$select count(*) from (select profile_id from public.trainers where coach_code ilike 'no-such-code-xyz') s$q$, '0'),
      (11, 'client', $q$client sees coach public names$q$, $q$select count(*) from public.profile_directory() where role = 'coach' and coalesce(name, '') <> ''$q$, '>0'),
      (12, 'client', $q$client sees no coach legal first/last names$q$, $q$select count(*) from public.profile_directory() where role = 'coach' and (first_name is not null or last_name is not null)$q$, '0'),
      (13, 'client', $q$client cannot read member emails$q$, $q$select count(email) from public.profiles$q$, 'denied'),
      (14, 'client', $q$client cannot read member phones$q$, $q$select count(phone) from public.profiles$q$, 'denied'),
      (15, 'client', $q$client cannot read profile names directly$q$, $q$select count(name) from public.profiles$q$, 'denied'),
      (16, 'client', $q$client cannot select * from profiles$q$, $q$select count(*) from (select * from public.profiles) s$q$, 'denied'),
      (17, 'client', $q$client gets no contact info for others$q$, $q$select count(*) from public.profile_contact_for(array['{X}', '{K}', '{O}']::uuid[])$q$, '0'),
      (18, 'client', $q$client gets no other client's emergency phone$q$, $q$select count(*) from (select public.client_emergency_phone('{X}') p) s where p is not null$q$, '0'),
      (19, 'client', $q$client cannot read billing_address column$q$, $q$select count(billing_address) from public.clients$q$, 'denied'),
      (20, 'client', $q$client reads own billing via client_billing_for$q$, $q$select count(*) from public.client_billing_for(array['{C}']::uuid[])$q$, '1'),
      (21, 'client', $q$client cannot read coach pay columns$q$, $q$select count(commission_rate) from public.trainers$q$, 'denied'),
      (22, 'client', $q$client booking balance policy evaluates$q$, $q$select (((select public.current_user_role()) = 'owner' and '{C}'::uuid is distinct from (select auth.uid())) or ((select public.current_user_role()) = 'coach' and '{C}'::uuid is distinct from (select auth.uid()) and (public.client_balance_ok('{C}'::uuid) or public.client_grace_unused('{C}'::uuid))) or ('{C}'::uuid = (select auth.uid()) and public.client_balance_ok('{C}'::uuid)))::text$q$, 'ok'),
      (23, 'client', $q$client no-op profile update$q$, $q$with u as (update public.profiles set push_opt_in = push_opt_in where id = '{C}' returning 1) select count(*) from u$q$, '1'),
      (24, 'client', $q$client no-op client row update$q$, $q$with u as (update public.clients set tour_seen = tour_seen where profile_id = '{C}' returning 1) select count(*) from u$q$, '1'),
      (25, 'client', $q$client sign-up upsert (no-op values)$q$, $q$with u as (insert into public.clients (profile_id, city, state) select profile_id, city, state from public.clients where profile_id = '{C}' on conflict (profile_id) do update set city = excluded.city, state = excluded.state returning 1) select count(*) from u$q$, '1'),
      (26, 'coach', $q$coach reads roster client rows, app columns$q$, $q$select count(*) from (select profile_id, birthday, city, state, home_lat, home_lng, membership_plan_id, primary_trainer_id, plans, tour_seen, membership_paused, membership_paused_at, membership_paused_days, updated_at, custom_fields, membership_freeze_ends_at, session_count_override, pending_plan_id, pending_plan_effective_at, session_count_override_month, membership_cancels_at, referred_by_trainer_id, coach_code_alert_seen, sms_opt_in, redeem_points_next_renewal, marketing_opt_out, sms_opt_in_at, sms_consent_text, emergency_contact_name, booking_restricted, booking_restricted_reason from public.clients) s$q$, '>0'),
      (27, 'coach', $q$coach cannot read client phones$q$, $q$select count(phone) from public.profiles$q$, 'denied'),
      (28, 'coach', $q$coach cannot read client emails directly$q$, $q$select count(email) from public.profiles$q$, 'denied'),
      (29, 'coach', $q$coach gets no client contact via profile_contact_for$q$, $q$select count(*) from public.profile_contact_for(array['{C}']::uuid[])$q$, '0'),
      (30, 'coach', $q$coach cannot read billing_address column$q$, $q$select count(billing_address) from public.clients$q$, 'denied'),
      (31, 'coach', $q$coach cannot read emergency_contact_phone column$q$, $q$select count(emergency_contact_phone) from public.clients$q$, 'denied'),
      (32, 'coach', $q$coach gets no emergency phone via function$q$, $q$select count(*) from (select public.client_emergency_phone('{C}') p) s where p is not null$q$, '0'),
      (33, 'coach', $q$coach gets billing city/state only$q$, $q$select count(*) from public.client_billing_locality('{C}')$q$, '1'),
      (34, 'coach', $q$coach cannot read full billing address$q$, $q$select count(*) from (select public.client_billing_address('{C}') a) s where a is null or a is not null$q$, 'error'),
      (35, 'coach', $q$coach gets no client_billing_for rows$q$, $q$select count(*) from public.client_billing_for(array['{C}']::uuid[])$q$, '0'),
      (36, 'coach', $q$coach reads own trainer row$q$, $q$select count(*) from (select profile_id, disciplines, session_types, slot_interval, availability, programmer_availability, locations, bio, before_afters, avail_lock_until, signup_at, reviewed_by_owner, updated_at, coach_code, unavailability, title, coach_name from public.trainers where profile_id = '{K}') s$q$, '1'),
      (37, 'coach', $q$coach cannot read pay columns directly$q$, $q$select count(payout_rate_cents) from public.trainers$q$, 'denied'),
      (38, 'coach', $q$coach no-op own trainer update$q$, $q$with u as (update public.trainers set bio = bio where profile_id = '{K}' returning 1) select count(*) from u$q$, '1'),
      (39, 'coach', $q$coach no-op own profile update$q$, $q$with u as (update public.profiles set push_opt_in = push_opt_in where id = '{K}' returning 1) select count(*) from u$q$, '1'),
      (40, 'coach', $q$coach no-op client row update$q$, $q$with u as (update public.clients set tour_seen = tour_seen where profile_id = '{C}' returning 1) select count(*) from u$q$, '1'),
      (41, 'coach', $q$coach booking-for-client balance policy evaluates$q$, $q$select (((select public.current_user_role()) = 'owner' and '{C}'::uuid is distinct from (select auth.uid())) or ((select public.current_user_role()) = 'coach' and '{C}'::uuid is distinct from (select auth.uid()) and (public.client_balance_ok('{C}'::uuid) or public.client_grace_unused('{C}'::uuid))) or ('{C}'::uuid = (select auth.uid()) and public.client_balance_ok('{C}'::uuid)))::text$q$, 'ok'),
      (42, 'owner', $q$owner reads client email/phone via profile_contact_for$q$, $q$select count(*) from public.profile_contact_for(array['{C}']::uuid[]) where coalesce(phone, '') <> ''$q$, '1'),
      (43, 'owner', $q$owner reads full billing address$q$, $q$select count(*) from (select public.client_billing_address('{C}') a) s where a is null or a is not null$q$, '1'),
      (44, 'owner', $q$owner reads client_billing_for$q$, $q$select count(*) from public.client_billing_for(array['{C}']::uuid[])$q$, '1'),
      (45, 'owner', $q$owner reads emergency phone function$q$, $q$select count(*) from (select public.client_emergency_phone('{C}') a) s where a is null or a is not null$q$, '1'),
      (46, 'owner', $q$owner reads roster client rows$q$, $q$select count(*) from (select profile_id, birthday, city, state, home_lat, home_lng, membership_plan_id, primary_trainer_id, plans, tour_seen, membership_paused, membership_paused_at, membership_paused_days, updated_at, custom_fields, membership_freeze_ends_at, session_count_override, pending_plan_id, pending_plan_effective_at, session_count_override_month, membership_cancels_at, referred_by_trainer_id, coach_code_alert_seen, sms_opt_in, redeem_points_next_renewal, marketing_opt_out, sms_opt_in_at, sms_consent_text, emergency_contact_name, booking_restricted, booking_restricted_reason from public.clients) s$q$, '>0'),
      (47, 'owner', $q$owner reads coach list$q$, $q$select count(*) from (select profile_id, disciplines, session_types, slot_interval, availability, programmer_availability, locations, bio, before_afters, avail_lock_until, signup_at, reviewed_by_owner, updated_at, coach_code, unavailability, title, coach_name from public.trainers) s$q$, '>0'),
      (48, 'owner', $q$owner no-op client profile update$q$, $q$with u as (update public.profiles set push_opt_in = push_opt_in where id = '{C}' returning 1) select count(*) from u$q$, '1'),
      (49, 'owner', $q$owner booking-for-client balance policy evaluates$q$, $q$select (((select public.current_user_role()) = 'owner' and '{C}'::uuid is distinct from (select auth.uid())) or ((select public.current_user_role()) = 'coach' and '{C}'::uuid is distinct from (select auth.uid()) and (public.client_balance_ok('{C}'::uuid) or public.client_grace_unused('{C}'::uuid))) or ('{C}'::uuid = (select auth.uid()) and public.client_balance_ok('{C}'::uuid)))::text$q$, 'ok'),
      (50, 'owner', $q$owner direct email column (by design: functions only)$q$, $q$select count(email) from public.profiles$q$, 'denied')
    ) v(n, who, label, sql, expect) order by n
  loop
    if chk.who <> cur then
      perform set_config('role', 'none', true);
      perform set_config('request.jwt.claims',
        case chk.who
          when 'anon' then json_build_object('role', 'anon')
          else json_build_object('role', 'authenticated', 'sub',
            case chk.who when 'client' then v_c when 'coach' then v_k else v_o end)
        end::text, true);
      perform set_config('role', case chk.who when 'anon' then 'anon' else 'authenticated' end, true);
      cur := chk.who;
    end if;

    stmt := replace(replace(replace(replace(chk.sql,
      '{C}', v_c::text), '{X}', v_x::text), '{K}', v_k::text), '{O}', v_o::text);
    begin
      execute stmt into got;
    exception
      when insufficient_privilege then got := 'denied';
      when others then got := 'error';
    end;

    ok := case chk.expect
      when 'ok' then got not in ('denied', 'error')
      when '>0' then got ~ '^[0-9]+$' and got::int > 0
      else got = chk.expect
    end;
    if ok then pass := pass + 1; else fail := fail + 1; end if;
    -- Only counts/denied/error are printed; 'ok' checks print just ok.
    report := report || format(E'%s  %-6s %-58s expect %-6s got %s\n',
      case when ok then 'PASS' else 'FAIL' end, chk.who, chk.label, chk.expect,
      case when chk.expect = 'ok' and ok then 'ok' else got end);
  end loop;

  perform set_config('role', 'none', true);
  raise exception E'VERIFY (rolled back): % passed, % failed\n%', pass, fail, report;
end
$verify$;
