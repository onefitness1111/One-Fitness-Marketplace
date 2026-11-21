-- A client's message to a coach or the owner is texted even when the
-- client picked In app. That picker only decides whether the client
-- receives staff replies by SMS. Staff-to-client messages stay as they
-- are: the function is called only when SMS was one of the channels.
--
-- This is the live messages_auto_reply, plus that exception. It does not
-- read clients.primary_trainer_id and it does not rewrite any message.
--
-- chat_staff_push is the lock that lets chat-auto-reply-sms and
-- client-notify send one staff push for the same message.

create table if not exists public.chat_staff_push (
  message_id uuid primary key,
  created_at timestamptz not null default now()
);

comment on table public.chat_staff_push is
  'One row per client message whose coach or owner was already pushed. A second caller skips.';

alter table public.chat_staff_push enable row level security;
revoke all on table public.chat_staff_push from public, anon, authenticated;
grant all on table public.chat_staff_push to service_role;

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

  if not has_sms and not client_to_staff then
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
