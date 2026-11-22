-- One invite text per client, and staff texts held until they reply YES.
--
-- A client who has never agreed, never opted out, and never turned texts
-- off gets a single invite instead of the message. The message stays in
-- the app and is marked pending. Replying YES records consent and the
-- text handler sends the held messages. STOP and an in-app decline get
-- no text at all. "Not now" is not stored, so it is not a decline.
--
-- This does not send a text, deploy a function, or change Twilio.
-- Apply it before deploying chat-auto-reply-sms, sms-inbound, and
-- twilio-inbound. Those three share this handler.

alter table public.clients
  add column if not exists sms_invite_sent_at timestamptz,
  add column if not exists sms_invite_text text,
  add column if not exists sms_declined_at timestamptz;

comment on column public.clients.sms_invite_sent_at is
  'When the one invite text was sent. A later staff message does not send another.';
comment on column public.clients.sms_invite_text is
  'The exact invite wording. A YES is stored against this text.';
comment on column public.clients.sms_declined_at is
  'When they turned Text messages off in the app. Not set by Not now. No SMS, including no invite.';

alter table public.messages
  add column if not exists sms_pending boolean not null default false;

comment on column public.messages.sms_pending is
  'A staff message that stayed in the app because the client had not agreed to texts. Cleared when it is texted after they reply YES.';

create index if not exists messages_sms_pending_client_idx
  on public.messages (client_id, created_at)
  where sms_pending;

-- The app may record its own decline. It cannot invent or erase an invite,
-- and it cannot flag a message as waiting on a text. The text handler does that.
create or replace function public.clients_guard_sms_invite()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if coalesce(auth.role(), '') = 'service_role' then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    new.sms_invite_sent_at := old.sms_invite_sent_at;
    new.sms_invite_text := old.sms_invite_text;
  else
    new.sms_invite_sent_at := null;
    new.sms_invite_text := null;
  end if;

  if tg_op = 'INSERT' then
    if auth.uid() is distinct from new.profile_id then
      new.sms_declined_at := null;
    end if;
  elsif new.sms_declined_at is distinct from old.sms_declined_at
    and auth.uid() is distinct from new.profile_id then
    new.sms_declined_at := old.sms_declined_at;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_clients_guard_sms_invite on public.clients;
create trigger trg_clients_guard_sms_invite
  before insert or update on public.clients
  for each row execute function public.clients_guard_sms_invite();

create or replace function public.messages_guard_sms_pending()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if coalesce(auth.role(), '') = 'service_role' then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    new.sms_pending := old.sms_pending;
  else
    new.sms_pending := false;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_messages_guard_sms_pending on public.messages;
create trigger trg_messages_guard_sms_pending
  before insert or update on public.messages
  for each row execute function public.messages_guard_sms_pending();

-- The trigger runs as the person saving the row, so that person needs execute.
-- The function only puts columns back. It does not expose a new read or write.
revoke all on function public.clients_guard_sms_invite() from public;
revoke all on function public.messages_guard_sms_pending() from public;
grant execute on function public.clients_guard_sms_invite() to anon, authenticated, service_role;
grant execute on function public.messages_guard_sms_pending() to anon, authenticated, service_role;
