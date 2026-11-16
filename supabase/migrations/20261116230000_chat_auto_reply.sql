-- Chat automatic replies. Not applied to the live database by this pull
-- request. Run this file in the Supabase SQL editor when you deploy.
--
-- When a client sends a message in the app, this posts one short note in
-- that same thread. It is marked as an automatic reply (who = 'auto'), not
-- as the coach typing. Texts that arrived at the gym number are channel
-- 'sms'; those are answered by text from the twilio-inbound function, so
-- this trigger leaves them alone and the client is not answered twice.
--
-- A message to a coach gets the coach sentence. Anything else (the
-- business, the owner) gets the business sentence. There is no business
-- text-back.
--
-- The client gets that note on every message, except during the 6 hours
-- after the coach — or an owner, for a business thread — last wrote a real
-- message in that conversation. App messages and texts count. Automatic
-- notes do not. The three values below must match
-- supabase/functions/_shared/autoReply.ts.

alter table public.messages drop constraint if exists messages_who_check;
alter table public.messages add constraint messages_who_check
  check (who = any (array['client'::text, 'trainer'::text, 'auto'::text]));

create index if not exists messages_trainer_replies_idx
  on public.messages (client_id, sender_id, created_at desc)
  where who = 'trainer';

create or replace function public.messages_auto_reply()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  -- Keep these three identical to autoReply.ts.
  auto_reply_quiet_hours constant integer := 6;
  coach_auto_reply constant text :=
    'Hey, your coach has received your message and will get back to you ASAP.';
  business_auto_reply constant text :=
    'Hey, your message was received and we''ll get back to you as soon as possible.';
  recipient_role text;
  reply_body text;
  last_reply timestamptz;
begin
  -- The note we are about to insert, and anything a coach wrote, stops here.
  if new.who is distinct from 'client' then
    return new;
  end if;
  -- Only the person the thread belongs to can prompt a reply.
  if new.sender_id is distinct from new.client_id then
    return new;
  end if;
  -- Arrived by text (and is also saved in the thread). The webhook texts
  -- the coach sentence back. Do not also post it here.
  if new.channel = 'sms' then
    return new;
  end if;

  begin
    if new.trainer_id is not null then
      select role into recipient_role
      from public.profiles
      where id = new.trainer_id;
    end if;

    if recipient_role = 'coach' then
      reply_body := coach_auto_reply;
      select max(m.created_at) into last_reply
      from public.messages m
      where m.client_id = new.client_id
        and m.who = 'trainer'
        and m.sender_id = new.trainer_id;
    else
      reply_body := business_auto_reply;
      select max(m.created_at) into last_reply
      from public.messages m
      join public.profiles p on p.id = m.sender_id
      where m.client_id = new.client_id
        and m.who = 'trainer'
        and p.role = 'owner';
    end if;

    -- Strictly under the window. At exactly 6 hours, replies resume.
    if last_reply is not null
       and last_reply > now() - make_interval(hours => auto_reply_quiet_hours) then
      return new;
    end if;

    -- One millisecond later so the note sorts under the message it answers.
    -- now() is the same for every row in this transaction.
    insert into public.messages (
      client_id, trainer_id, sender_id, who, body, channel, read_by_coach, created_at
    ) values (
      new.client_id,
      new.trainer_id,
      new.client_id,
      'auto',
      reply_body,
      'auto',
      true,
      new.created_at + interval '1 millisecond'
    );
  exception when others then
    -- A failed note must not block the client's real message.
    raise warning 'chat auto-reply skipped: %', sqlerrm;
  end;

  return new;
end;
$function$;

drop trigger if exists trg_messages_auto_reply on public.messages;
create trigger trg_messages_auto_reply
  after insert on public.messages
  for each row
  execute function public.messages_auto_reply();

revoke all on function public.messages_auto_reply() from PUBLIC, anon, authenticated;
