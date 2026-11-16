-- Chat automatic replies, part 2: messages sent BOTH in the app and by SMS.
--
-- Rules (Coach Chris, Nov 16):
--   * Sent in the app AND by SMS to a coach -> the SMS auto-reply. The coach
--     sentence is texted to the client's phone, and the same sentence is
--     posted once in the app thread as the automatic note. One reply only.
--   * Sent only in the app            -> the in-app automatic note (as before).
--   * Sent only by email              -> no automatic reply.
--   * A text that arrived at the gym number (written by the twilio-inbound
--     webhook, channel 'sms', no signed-in user) -> unchanged: the webhook
--     answers it by SMS and this trigger stays out of it.
--   * The 6-hour quiet window after the coach's (or, for a business thread,
--     an owner's) last real message still applies to everything.
--
-- The text itself is sent by the chat-auto-reply-sms edge function, which
-- this trigger calls through pg_net. pg_net only sends after the client's
-- message has committed. The function re-checks everything from the
-- database (fresh client message, SMS chosen, the coach note exists), skips
-- missing numbers and landlines, and records each message it answers in
-- chat_auto_reply_sms so a message is never texted twice.
--
-- Additive: one new table, and the trigger function is replaced in place.
-- Undo: re-run the function from 20261116230000_chat_auto_reply.sql.

create table if not exists public.chat_auto_reply_sms (
  message_id uuid primary key references public.messages(id) on delete cascade,
  created_at timestamptz not null default now(),
  outcome text
);
alter table public.chat_auto_reply_sms enable row level security;
revoke all on table public.chat_auto_reply_sms from anon, authenticated;

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
  sms_function_url constant text :=
    'https://rivhgutksyddeckieknc.supabase.co/functions/v1/chat-auto-reply-sms';
  tokens text[];
  has_sms boolean;
  has_inapp boolean;
  recipient_role text;
  reply_body text;
  last_reply timestamptz;
  text_back boolean := false;
begin
  -- The note we are about to insert, and anything a coach wrote, stops here.
  if new.who is distinct from 'client' then
    return new;
  end if;
  -- Only the person the thread belongs to can prompt a reply.
  if new.sender_id is distinct from new.client_id then
    return new;
  end if;
  -- A text that arrived at the gym number: written by the webhook with the
  -- service key (no signed-in user). The webhook texts the reply itself.
  if new.channel = 'sms' and auth.uid() is null then
    return new;
  end if;

  -- Channels as the app writes them ("inapp", "inapp,sms", "inapp,sms,email",
  -- "email", ...) plus the old spellings still in the table.
  tokens := array(
    select btrim(t)
    from unnest(string_to_array(lower(coalesce(new.channel, '')), ',')) as t
    where btrim(t) <> ''
  );
  if 'inappsms' = any(tokens) then
    tokens := tokens || array['inapp', 'sms'];
  end if;
  if 'both' = any(tokens) then
    tokens := tokens || array['inapp', 'sms', 'email'];
  end if;
  -- Rows from before the column was filled in were app messages.
  if cardinality(tokens) = 0 then
    tokens := array['inapp'];
  end if;
  has_sms := 'sms' = any(tokens);
  has_inapp := 'inapp' = any(tokens);

  -- Email only (or nothing we recognise): no automatic reply.
  if not has_sms and not has_inapp then
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
      -- SMS was chosen for a message to a coach: the reply goes by text too.
      text_back := has_sms;
      select max(m.created_at) into last_reply
      from public.messages m
      where m.client_id = new.client_id
        and m.who = 'trainer'
        and m.sender_id = new.trainer_id;
    else
      -- The business has no text line, so this is always the in-app note.
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
    -- This is the single automatic reply for the message, in both cases.
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

    if text_back then
      -- Its own block: if the text can't be queued, the note above stays.
      begin
        perform net.http_post(
          url := sms_function_url,
          body := jsonb_build_object('message_id', new.id),
          headers := jsonb_build_object('Content-Type', 'application/json'),
          timeout_milliseconds := 10000
        );
      exception when others then
        raise warning 'chat auto-reply text not queued: %', sqlerrm;
      end;
    end if;
  exception when others then
    -- A failed note must not block the client's real message.
    raise warning 'chat auto-reply skipped: %', sqlerrm;
  end;

  return new;
end;
$function$;

revoke all on function public.messages_auto_reply() from PUBLIC, anon, authenticated;
