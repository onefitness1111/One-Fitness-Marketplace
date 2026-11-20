-- Package renewal discount, set by the owner in Customize Platform → Coupons.
-- Not applied to the live database by this change. Apply this file when
-- the update goes live. It does not change the existing platform_settings
-- row. Until the owner saves an offer, the app and the payment functions
-- keep today's offer: on, 5% off, starting at 8 sessions left.
--
-- The offer is stored on the existing platform_settings row (id = 'global')
-- at data.packageRenewal:
--   enabled       boolean, default true
--   percent       whole number 1–50, default 5
--   sessionsLeft  whole number 3–99, default 8
-- Writes to platform_settings are already owner-only
-- (current_user_role() = 'owner', the same check as is_owner()).
-- Signed-in clients can already read that row, which is what the offer
-- card needs. This file does not widen that.
--
-- The full-price reminder at 2 sessions left is unchanged.
-- Skipping or dismissing the discount still forfeits it for that package.
-- The note stored when they do that uses the saved percent instead of a
-- fixed 5%.

create or replace function public.enforce_package_renewal_offer()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare
  offer jsonb := new.data -> 'packageRenewal';
  pct numeric;
  sessions numeric;
begin
  if offer is null or jsonb_typeof(offer) = 'null' then
    return new;
  end if;
  if jsonb_typeof(offer) <> 'object' then
    raise exception 'Package renewal offer is not valid.';
  end if;
  if offer ? 'enabled' and jsonb_typeof(offer -> 'enabled') is distinct from 'boolean' then
    raise exception 'Package renewal offer on/off must be true or false.';
  end if;
  if offer ? 'percent' then
    if jsonb_typeof(offer -> 'percent') is distinct from 'number' then
      raise exception 'Renewal discount percent must be a whole number from 1 to 50.';
    end if;
    pct := (offer ->> 'percent')::numeric;
    if pct <> trunc(pct) or pct < 1 or pct > 50 then
      raise exception 'Renewal discount percent must be a whole number from 1 to 50.';
    end if;
  end if;
  if offer ? 'sessionsLeft' then
    if jsonb_typeof(offer -> 'sessionsLeft') is distinct from 'number' then
      raise exception 'Sessions left for the renewal discount must be a whole number from 3 to 99.';
    end if;
    sessions := (offer ->> 'sessionsLeft')::numeric;
    if sessions <> trunc(sessions) or sessions < 3 or sessions > 99 then
      raise exception 'Sessions left for the renewal discount must be a whole number from 3 to 99.';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_package_renewal_offer() from public, anon, authenticated;

drop trigger if exists platform_settings_renewal_offer on public.platform_settings;
create trigger platform_settings_renewal_offer
  before insert or update on public.platform_settings
  for each row
  execute function public.enforce_package_renewal_offer();

-- Closing a reminder. The discount, once skipped or dismissed, stays
-- forfeited. The client cannot turn it back on. The words use the percent
-- the owner saved. A missing or unusable percent stays at 5.
create or replace function public.dismiss_package_renewal(
  p_plan text,
  p_start date,
  p_kind text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  me uuid := auth.uid();
  lose boolean;
  offer jsonb;
  pct int := 5;
begin
  if me is null then
    raise exception 'Not signed in.';
  end if;
  if p_kind not in ('package_discount', 'package_full') then
    raise exception 'Unknown reminder.';
  end if;
  if p_plan is null or btrim(p_plan) = '' or p_start is null then
    raise exception 'That package was not found.';
  end if;
  lose := p_kind = 'package_discount';

  select data -> 'packageRenewal' into offer
    from public.platform_settings
    where id = 'global';
  if offer is not null
     and jsonb_typeof(offer) = 'object'
     and jsonb_typeof(offer -> 'percent') = 'number' then
    pct := trunc((offer ->> 'percent')::numeric)::int;
    if pct < 1 or pct > 50 then
      pct := 5;
    end if;
  end if;

  insert into public.client_notices (
    client_id, kind, plan_id, enrollment_start, title, body, forfeited, dismissed_at
  ) values (
    me,
    p_kind,
    p_plan,
    p_start,
    case when lose then 'Renew now at ' || pct::text || '% off' else 'Renew now' end,
    case when lose
      then 'The ' || pct::text || '% renewal discount on this package has been given up.'
      else 'Renewal reminder closed.'
    end,
    lose,
    now()
  )
  on conflict (client_id, kind, plan_id, enrollment_start) do update set
    dismissed_at = now(),
    forfeited = client_notices.forfeited or excluded.forfeited;
end;
$$;

revoke all on function public.dismiss_package_renewal(text, date, text) from public, anon;
grant execute on function public.dismiss_package_renewal(text, date, text) to authenticated;

comment on function public.dismiss_package_renewal(text, date, text) is
  'Closes a package renewal reminder. Skipping or dismissing the discount forfeits it for that package. The percent in the note is the one saved on platform settings.';
