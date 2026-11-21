-- Coach billing address: city and state only, and a one-time write.
-- Not applied to the live database by this change.
-- Run it after 20261121140000_dashboard_bootstrap_fix_role.sql.
--
-- Read today: authenticated cannot select clients.billing_address. The
-- column was left out of the grant in 20261116120000_phase0_security.sql,
-- and no later migration grants it. client_billing_address and
-- client_billing_for already return the full value only to that client,
-- the owner, and the service role. This revokes the column again so a
-- later grant cannot quietly reopen it.
--
-- Write today: set_client_billing_address lets the client's coach replace
-- an address that is already saved. The app reaches that function through
-- save-billing-address, which calls it as the service role. This migration
-- stops a coach calling the function directly, and stops a coach's own
-- update of the column, once a street is on file. The service-role call
-- stays open so the client can still edit their address from Profile
-- Settings. The save-billing-address function in this repo now refuses a
-- coach overwrite before that call; deploy that function with this
-- migration or the already-deployed copy can still replace an address.
--
-- "On file" matches client_file_flags: a street (line1) is saved. A null
-- value, or the city/state-only object copied by
-- 20261119060000_billing_address.sql, is not on file, so the coach can
-- enter the first real address.

revoke select (billing_address) on table public.clients from public, anon, authenticated;

create or replace function public.client_billing_locality(p_client uuid)
returns table (city text, state text)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  coach uuid;
  addr jsonb;
begin
  select c.primary_trainer_id, c.billing_address
    into coach, addr
  from public.clients c
  where c.profile_id = p_client;

  if auth.role() is distinct from 'service_role'
     and p_client is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner'
     and not (public.current_user_role() = 'coach' and coach = auth.uid()) then
    raise exception 'Not allowed.';
  end if;

  city := nullif(btrim(addr->>'city'), '');
  state := nullif(btrim(addr->>'state'), '');
  return next;
end;
$$;

revoke all on function public.client_billing_locality(uuid) from public, anon;
grant execute on function public.client_billing_locality(uuid) to authenticated, service_role;

create or replace function public.set_client_billing_address(p_client uuid, p_address jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  coach uuid;
  existing jsonb;
  actor_is_coach boolean;
begin
  select c.primary_trainer_id, c.billing_address
    into coach, existing
  from public.clients c
  where c.profile_id = p_client;

  if auth.role() is distinct from 'service_role'
     and p_client is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner'
     and not (public.current_user_role() = 'coach' and coach = auth.uid()) then
    raise exception 'Not allowed to update that billing address.';
  end if;

  -- A coach may fill an empty address and may not replace one. The client
  -- and the owner may replace it. service_role is the path Profile Settings
  -- already uses; save-billing-address applies this same lock for a coach.
  actor_is_coach := public.current_user_role() = 'coach'
    and p_client is distinct from auth.uid()
    and auth.role() is distinct from 'service_role';
  if actor_is_coach and coalesce(btrim(existing->>'line1'), '') <> '' then
    raise exception 'A billing address is already on file.';
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

-- A direct update follows the same rule. The client's coach may set
-- billing_address while no street is stored. After that, the previous
-- value is put back. The client, the owner, and the service role are
-- unchanged. Stripe and balance columns stay locked for a coach.
create or replace function public.clients_guard_billing()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  caller uuid := auth.uid();
  allowed boolean := auth.role() = 'service_role'
    or public.current_user_role() = 'owner'
    or caller = old.profile_id;
  coach_first_address boolean := public.current_user_role() = 'coach'
    and old.primary_trainer_id = caller
    and (
      old.billing_address is null
      or coalesce(btrim(old.billing_address->>'line1'), '') = ''
    );
begin
  if current_setting('app.allow_grace', true) = '1' then
    new.stripe_customer_id := old.stripe_customer_id;
    new.stripe_subscription_id := old.stripe_subscription_id;
    new.stripe_schedule_id := old.stripe_schedule_id;
    new.pending_plan_price_id := old.pending_plan_price_id;
    new.billing_address := old.billing_address;
    new.billing_anchor_day := old.billing_anchor_day;
    new.balance_cents := old.balance_cents;
    new.has_outstanding_balance := old.has_outstanding_balance;
    new.outstanding_balance_cents := old.outstanding_balance_cents;
    new.outstanding_invoice_id := old.outstanding_invoice_id;
    new.outstanding_invoice_url := old.outstanding_invoice_url;
    new.outstanding_since := old.outstanding_since;
    return new;
  end if;
  if allowed then
    return new;
  end if;
  new.stripe_customer_id := old.stripe_customer_id;
  new.stripe_subscription_id := old.stripe_subscription_id;
  new.stripe_schedule_id := old.stripe_schedule_id;
  new.pending_plan_price_id := old.pending_plan_price_id;
  new.billing_anchor_day := old.billing_anchor_day;
  new.balance_cents := old.balance_cents;
  new.has_outstanding_balance := old.has_outstanding_balance;
  new.outstanding_balance_cents := old.outstanding_balance_cents;
  new.outstanding_invoice_id := old.outstanding_invoice_id;
  new.outstanding_invoice_url := old.outstanding_invoice_url;
  new.outstanding_since := old.outstanding_since;
  new.grace_booking_used := old.grace_booking_used;
  if not coach_first_address then
    new.billing_address := old.billing_address;
  end if;
  return new;
end;
$function$;
