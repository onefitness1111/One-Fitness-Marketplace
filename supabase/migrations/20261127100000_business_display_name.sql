-- One business name for the owner everywhere: "ONE Fitness Marketplace".
-- Coach Chris picked it on Nov 27, 2026. The app copy is kMarketplaceName
-- (lib/core/utils/chat_channels.dart) and the Edge Function copy is
-- supabase/functions/_shared/businessName.mjs. Change all three together.
-- Not applied to the live database by this change.

create or replace function public.business_display_name()
returns text
language sql
immutable
set search_path to 'public'
as $$
  select 'ONE Fitness Marketplace'::text;
$$;

grant execute on function public.business_display_name() to authenticated, service_role;

-- Same as live, with the literal replaced by business_display_name().
create or replace function public.message_sender_label(p_sender uuid, p_who text)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  r text;
  n text;
begin
  if p_who = 'auto' or p_sender is null then
    return null;
  end if;
  select role, name into r, n from public.profiles where id = p_sender;
  if r = 'owner' or p_who = 'business' then
    return public.business_display_name();
  end if;
  if r = 'coach' or p_who = 'trainer' then
    return public.coach_public_name(p_sender);
  end if;
  return coalesce(nullif(btrim(n), ''), 'Client');
end;
$$;
