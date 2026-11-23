-- Ends the temporary whole-table read on profiles, clients, and trainers that
-- was put back live for app 1.1.0 (restore_profiles_select_for_1_1_0 and
-- restore_clients_trainers_select_for_1_1_0). Signed-in users get back to
-- reading only the columns the app (1.1.2 through main) actually selects.
--
--   profiles: no name, first/last name, email, phone, calendar token, or SMS
--             consent fields. Names, emails, and phones come from the
--             SECURITY DEFINER directory/contact functions, which already
--             apply the role rules (clients see coach names only; coaches
--             never see a client's phone; the owner sees everything).
--   clients:  no billing address, Stripe ids, outstanding-invoice fields,
--             emergency contact phone, or SMS invite fields. Coaches get
--             billing city/state only through client_billing_locality.
--             No balance fields either: the bookings/waitlist
--             negative-balance insert policies used to read
--             clients.balance_cents / grace_booking_used with the caller's
--             rights, so they now call two small SECURITY DEFINER checks
--             (same logic, same result) instead.
--   trainers: no pay fields (commission, payout, referral %) and no
--             secondary_coach_name. Pay comes from trainer_pay_for.
--
-- Other row policies are unchanged. Writes (insert/update/upsert) are
-- unchanged.
-- The app never selects a column outside these lists (checked against the
-- 1.1.2 and 1.1.5 release binaries and main).

-- 1. Balance checks the booking/waitlist policies need, without giving
--    signed-in users the balance columns. Answers only for the caller's own
--    row or for staff; anyone else gets the permissive answer (true), which
--    the policies never rely on.
create or replace function public.client_balance_ok(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select c.balance_cents from public.clients c
     where c.profile_id = p_client
       and (p_client = auth.uid() or public.current_user_role() in ('coach', 'owner'))
  ), 0) >= 0
$$;

create or replace function public.client_grace_unused(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not coalesce((
    select c.grace_booking_used from public.clients c
     where c.profile_id = p_client
       and (p_client = auth.uid() or public.current_user_role() in ('coach', 'owner'))
  ), false)
$$;

revoke all on function public.client_balance_ok(uuid) from public, anon;
revoke all on function public.client_grace_unused(uuid) from public, anon;
grant execute on function public.client_balance_ok(uuid) to authenticated;
grant execute on function public.client_grace_unused(uuid) to authenticated;

-- Same rules as the live policies, with the balance reads moved into the
-- functions above.
drop policy if exists bookings_block_negative_balance on public.bookings;
create policy bookings_block_negative_balance
  on public.bookings
  as restrictive
  for insert
  to authenticated
  with check (
    (
      (select public.current_user_role()) = 'owner'
      and client_id is distinct from (select auth.uid())
    )
    or (
      (select public.current_user_role()) = 'coach'
      and client_id is distinct from (select auth.uid())
      and (public.client_balance_ok(client_id) or public.client_grace_unused(client_id))
    )
    or (
      client_id = (select auth.uid())
      and public.client_balance_ok(client_id)
    )
  );

drop policy if exists waitlist_block_negative_balance on public.waitlist;
create policy waitlist_block_negative_balance
  on public.waitlist
  as restrictive
  for insert
  to authenticated
  with check (
    client_id is distinct from (select auth.uid())
    or public.client_balance_ok(client_id)
  );

-- 2. End the whole-table read.
revoke select on table public.profiles, public.clients, public.trainers from public, anon, authenticated;

-- Clear any column-level reads left from earlier migrations, then grant
-- exactly the allowed list.
revoke select (
  accepted_terms_at, accepted_terms_version, ban_reason, banned_at,
  calendar_token, chat_intro_seen_at, created_at, deleted_at, email,
  first_name, id, last_name, name, over_18_confirmed_at, phone, photo_url,
  push_opt_in, role, sms_consent_at, sms_consent_text, sms_opted_out
) on public.profiles from public, anon, authenticated;

revoke select (
  balance_cents, billing_address, billing_anchor_day, birthday,
  booking_restricted, booking_restricted_at, booking_restricted_reason, city,
  coach_code_alert_seen, custom_fields, emergency_contact_name,
  emergency_contact_phone, grace_booking_used, has_outstanding_balance,
  home_lat, home_lng, marketing_opt_out, membership_cancels_at,
  membership_freeze_ends_at, membership_paused, membership_paused_at,
  membership_paused_days, membership_plan_id, outstanding_balance_cents,
  outstanding_invoice_id, outstanding_invoice_url, outstanding_since,
  pending_plan_effective_at, pending_plan_id, pending_plan_price_id, plans,
  primary_trainer_id, profile_id, redeem_points_next_renewal,
  referred_by_trainer_id, session_count_override,
  session_count_override_month, sms_consent_text, sms_declined_at,
  sms_invite_sent_at, sms_invite_text, sms_opt_in, sms_opt_in_at, state,
  stripe_customer_id, stripe_schedule_id, stripe_subscription_id, tour_seen,
  updated_at
) on public.clients from public, anon, authenticated;

revoke select (
  avail_lock_until, availability, before_afters, bio, coach_code, coach_name,
  commission_rate, disciplines, locations, payout_mode, payout_rate_cents,
  profile_id, programmer_availability, referral_commission_percent,
  reviewed_by_owner, secondary_coach_name, session_types, signup_at,
  slot_interval, title, unavailability, updated_at
) on public.trainers from public, anon, authenticated;

grant select (
  id, role, photo_url, created_at, push_opt_in, accepted_terms_at,
  accepted_terms_version, over_18_confirmed_at, banned_at, ban_reason,
  deleted_at
) on public.profiles to authenticated;

grant select (
  profile_id, birthday, city, state, home_lat, home_lng, membership_plan_id,
  primary_trainer_id, plans, tour_seen, membership_paused,
  membership_paused_at, membership_paused_days, updated_at, custom_fields,
  membership_freeze_ends_at, session_count_override, pending_plan_id,
  pending_plan_effective_at, session_count_override_month,
  membership_cancels_at, referred_by_trainer_id, coach_code_alert_seen,
  sms_opt_in, redeem_points_next_renewal, marketing_opt_out, sms_opt_in_at,
  sms_consent_text, emergency_contact_name, booking_restricted,
  booking_restricted_reason
) on public.clients to authenticated;

grant select (
  profile_id, disciplines, session_types, slot_interval, availability,
  programmer_availability, locations, bio, before_afters, avail_lock_until,
  signup_at, reviewed_by_owner, updated_at, coach_code, unavailability,
  title, coach_name
) on public.trainers to authenticated;

-- Not used by the app or PostgREST, and never needed by a signed-in user.
revoke truncate, references, trigger on table public.profiles, public.clients, public.trainers from public, anon, authenticated;

notify pgrst, 'reload schema';
