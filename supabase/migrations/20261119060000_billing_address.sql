-- Billing address the client can edit, and the references a card charge stores.
-- Not applied to the live database by this change.
-- Run it after 20261119050000_app_update.sql.
--
-- The address itself may be kept here so the profile and the charge screen
-- can show it. Card numbers are not stored. A charge keeps only the Stripe
-- payment-method id and the PaymentIntent id.
--
-- Who can read the address: that client and the owner. A coach cannot.

create or replace function public.client_billing_address(p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  addr jsonb;
begin
  if p_client is null then
    return null;
  end if;
  select c.billing_address into addr
  from public.clients c
  where c.profile_id = p_client;

  if auth.role() is distinct from 'service_role'
     and p_client is distinct from auth.uid()
     and public.current_user_role() is distinct from 'owner' then
    raise exception 'Not allowed to read that billing address.';
  end if;
  return addr;
end;
$$;

revoke all on function public.client_billing_address(uuid) from public, anon;
grant execute on function public.client_billing_address(uuid) to authenticated, service_role;

-- Older profiles only had a city and a state. Copy those into the address
-- once, and leave a row that already has an address alone.
update public.clients
set billing_address = jsonb_build_object(
  'name', '',
  'line1', '',
  'line2', '',
  'city', coalesce(city, ''),
  'state', coalesce(state, ''),
  'postal_code', '',
  'country', 'US'
)
where billing_address is null
  and (coalesce(city, '') <> '' or coalesce(state, '') <> '');

do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'charges'
  ) then
    alter table public.charges add column if not exists payment_method_id text;
    alter table public.charges add column if not exists stripe_payment_intent_id text;
    comment on column public.charges.payment_method_id is
      'Stripe payment method id. Never a card number.';
    comment on column public.charges.stripe_payment_intent_id is
      'Stripe PaymentIntent id for this charge.';
  end if;
end $$;
