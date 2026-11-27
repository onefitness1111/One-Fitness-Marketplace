-- Text routing decisions from Coach Chris (Nov 27, 2026).
--
-- 1. Late replies keep the current order: the client's own @CoachName tag,
--    else the thread active in the last 6 hours, else Business Chat.
--    NEW: when the owner tags @CoachName in a client's thread, that client's
--    untagged text replies go to the tagged coach for 6 hours. The window is
--    stored in sms_reply_routes (one row per client, the latest tag wins).
--    chat-auto-reply-sms writes it; the inbound text handler reads it.
-- 2. messages.copied_from marks the in-app copy of a tagged message placed
--    in the coach's thread, so the copy never texts the client again and
--    never re-runs the tag.
-- 3. messages_auto_reply now also calls chat-auto-reply-sms for an owner
--    message containing "@" (an in-app-only tag used to do nothing).
-- 4. app_config.play_store_url for the signup text to unknown numbers.
--    Empty until the Android app is on Google Play.
--
-- Same as live otherwise. No coach-assignment field is used.
-- Not applied to the live database by this change.

alter table public.messages
  add column if not exists copied_from uuid references public.messages (id) on delete set null;

comment on column public.messages.copied_from is
  'Set on the in-app copy of an owner @CoachName tag placed in that coach''s thread.';

alter table public.app_config
  add column if not exists play_store_url text;

create table if not exists public.sms_reply_routes (
  client_id uuid primary key references public.profiles (id) on delete cascade,
  coach_id uuid not null references public.profiles (id) on delete cascade,
  message_id uuid references public.messages (id) on delete set null,
  opened_at timestamptz not null default now(),
  expires_at timestamptz not null
);

alter table public.sms_reply_routes enable row level security;
drop policy if exists sms_reply_routes_owner_select on public.sms_reply_routes;
create policy sms_reply_routes_owner_select on public.sms_reply_routes
  for select to authenticated
  using ((select public.is_owner()));
revoke all on public.sms_reply_routes from anon;
grant select on public.sms_reply_routes to authenticated;

create or replace function public.messages_auto_reply()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  sms_function_url constant text :=
    'https://rivhgutksyddeckieknc.supabase.co/functions/v1/chat-auto-reply-sms';
  tokens text[];
  has_sms boolean;
  sender_role text;
  recipient_id uuid;
  recipient_role text;
  client_to_staff boolean := false;
  owner_tag boolean := false;
begin
  if new.who = 'auto' then
    return new;
  end if;

  if new.conversation_id is not null then
    update public.conversations
    set last_activity_at = coalesce(new.created_at, now())
    where id = new.conversation_id;
  end if;

  tokens := array(
    select btrim(t)
    from unnest(string_to_array(lower(coalesce(new.channel, '')), ',')) as t
    where btrim(t) <> ''
  );
  if 'inappsms' = any (tokens) then
    tokens := tokens || array['inapp', 'sms'];
  end if;
  if 'both' = any (tokens) then
    tokens := tokens || array['inapp', 'sms', 'email'];
  end if;
  has_sms := 'sms' = any (tokens);

  -- Sender role and the other person on the thread. Not the assigned coach.
  if new.sender_id is not null then
    select p.role into sender_role
    from public.profiles p
    where p.id = new.sender_id;
  end if;
  if sender_role = 'client' and new.client_id is not null then
    recipient_id := public.message_other_party(new.client_id, new.trainer_id);
    if recipient_id is not null and recipient_id is distinct from new.sender_id then
      select p.role into recipient_role
      from public.profiles p
      where p.id = recipient_id;
      client_to_staff := recipient_role in ('coach', 'owner');
    end if;
  end if;

  -- The owner tagging @CoachName, even in-app only. A copy is not a new tag.
  owner_tag := sender_role = 'owner'
    and new.copied_from is null
    and position('@' in coalesce(new.body, '')) > 0;

  if not has_sms and not client_to_staff and not owner_tag then
    return new;
  end if;

  begin
    perform net.http_post(
      url := sms_function_url,
      body := jsonb_build_object('message_id', new.id),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 10000
    );
  exception when others then
    raise warning 'chat text not queued: %', sqlerrm;
  end;

  return new;
end;
$$;
