-- One invite text per client, and staff texts held until they reply YES.
--
-- A client who has never agreed, never opted out, and never turned texts
-- off can get a single invite instead of the message, but only after
-- app_config.sms_invite_enabled is turned on. That flag is inserted false.
-- Until then the message stays in the app and no invite is sent. Replying
-- YES records consent and the text handler sends the held messages. STOP
-- and an in-app decline get no text at all. "Not now" is not stored, so
-- it is not a decline.
--
-- App 1.1.3 turned texts off by setting sms_opt_in false and did not write
-- sms_declined_at. This file does not guess which of those rows were a no.
-- The owner reviews them with supabase/sms_invite_review.sql before
-- flipping the flag. From here on, sms_opt_in going from true to false,
-- or profiles.sms_opted_out being set true, records sms_declined_at when
-- it is still null.
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

  -- The profiles opt-out trigger sets this for its one clients update.
  -- It does not let the app invent or clear an invite.
  if current_setting('app.sms_decline_stamp', true) is distinct from 'on' then
    if tg_op = 'INSERT' then
      if auth.uid() is distinct from new.profile_id then
        new.sms_declined_at := null;
      end if;
    elsif new.sms_declined_at is distinct from old.sms_declined_at
      and auth.uid() is distinct from new.profile_id then
      new.sms_declined_at := old.sms_declined_at;
    end if;
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

-- Turning texts off is a no from this migration forward. App 1.1.3 did
-- not write sms_declined_at; rows already false are left alone.
-- This runs after clients_guard_sms_invite (name order) so the stamp is
-- not put back.
create or replace function public.clients_record_sms_decline()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if tg_op = 'UPDATE'
     and old.sms_opt_in is true
     and new.sms_opt_in is distinct from true
     and new.sms_declined_at is null then
    new.sms_declined_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_clients_record_sms_decline on public.clients;
create trigger trg_clients_record_sms_decline
  before update of sms_opt_in on public.clients
  for each row execute function public.clients_record_sms_decline();

-- STOP sets profiles.sms_opted_out. Record the same decline on the client
-- when it is not already there. The stamp flag lets this one update
-- through the clients guard when the caller is not the service role.
create or replace function public.profiles_record_sms_decline()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if tg_op = 'UPDATE'
     and old.sms_opted_out is distinct from true
     and new.sms_opted_out is true then
    perform set_config('app.sms_decline_stamp', 'on', true);
    update public.clients
       set sms_declined_at = now()
     where profile_id = new.id
       and sms_declined_at is null;
    perform set_config('app.sms_decline_stamp', 'off', true);
  end if;
  return new;
exception when others then
  perform set_config('app.sms_decline_stamp', 'off', true);
  raise;
end;
$$;

drop trigger if exists trg_profiles_record_sms_decline on public.profiles;
create trigger trg_profiles_record_sms_decline
  before update of sms_opted_out on public.profiles
  for each row execute function public.profiles_record_sms_decline();

-- No invite goes out until this is true. Default false. The owner flips
-- it only after reviewing supabase/sms_invite_review.sql.
alter table public.app_config
  add column if not exists sms_invite_enabled boolean not null default false;

comment on column public.app_config.sms_invite_enabled is
  'When false, chat-auto-reply-sms holds staff texts and does not send the invite. Defaults to false.';

-- The trigger runs as the person saving the row, so that person needs execute.
-- The function only puts columns back. It does not expose a new read or write.
revoke all on function public.clients_guard_sms_invite() from public;
revoke all on function public.messages_guard_sms_pending() from public;
revoke all on function public.clients_record_sms_decline() from public;
revoke all on function public.profiles_record_sms_decline() from public;
grant execute on function public.clients_guard_sms_invite() to anon, authenticated, service_role;
grant execute on function public.messages_guard_sms_pending() to anon, authenticated, service_role;
grant execute on function public.clients_record_sms_decline() to anon, authenticated, service_role;
grant execute on function public.profiles_record_sms_decline() to anon, authenticated, service_role;
