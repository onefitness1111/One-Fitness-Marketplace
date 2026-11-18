-- One thread per pair, likes, and the 6-hour text window.
--
-- Safe to run on the live database. It adds tables and columns and fills
-- them from the messages that are already there. It does not delete a
-- message, rewrite a message body, or change Twilio.
--
-- Run this before deploying chat-auto-reply-sms. Deploying that function
-- replaces the live one, which today texts "your coach has received your
-- message". After this migration the function texts the real message instead.

-- ---------------------------------------------------------------------------
-- Consent and opt-out live on the profile so coaches are covered too.
-- clients.sms_opt_in stays; existing yeses are copied across. A client who
-- never opted in is not marked opted-out — that default is not a STOP.
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists sms_opted_out boolean not null default false,
  add column if not exists sms_consent_at timestamptz,
  add column if not exists sms_consent_text text,
  add column if not exists chat_intro_seen_at timestamptz;

comment on column public.profiles.sms_opted_out is
  'Set when they text STOP or UNSUBSCRIBE. App chat still works. No SMS until they opt in again.';
comment on column public.profiles.sms_consent_at is
  'When they agreed to texts. No SMS is sent before this is set.';
comment on column public.profiles.chat_intro_seen_at is
  'When they tapped OK on the @CoachName and 6-hour explanation.';

update public.profiles p
set sms_consent_at = c.sms_opt_in_at,
    sms_consent_text = c.sms_consent_text
from public.clients c
where c.profile_id = p.id
  and c.sms_opt_in = true
  and c.sms_opt_in_at is not null
  and p.sms_consent_at is null;

-- ---------------------------------------------------------------------------
-- Coach names are unique ignoring case and spaces.
-- The column is created here as well so this file is safe if the earlier
-- coach-name migration has not been applied yet.
-- ---------------------------------------------------------------------------

alter table public.trainers
  add column if not exists coach_name text,
  add column if not exists secondary_coach_name text;

create or replace function public.coach_name_key(p text)
returns text
language sql
immutable
as $$
  select nullif(regexp_replace(lower(btrim(coalesce(p, ''))), '\s+', '', 'g'), '');
$$;

revoke all on function public.coach_name_key(text) from public, anon;

create or replace function public.trainers_coach_name_unique()
returns trigger
language plpgsql
as $$
begin
  if public.coach_name_key(new.coach_name) is null then
    return new;
  end if;
  if exists (
    select 1 from public.trainers t
    where t.profile_id is distinct from new.profile_id
      and public.coach_name_key(t.coach_name) = public.coach_name_key(new.coach_name)
  ) then
    raise exception 'coach_name_taken: another coach already uses that coach name'
      using errcode = 'unique_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_trainers_coach_name_unique on public.trainers;
create trigger trg_trainers_coach_name_unique
  before insert or update of coach_name on public.trainers
  for each row execute function public.trainers_coach_name_unique();

do $$
begin
  create unique index trainers_coach_name_key_uidx
    on public.trainers (public.coach_name_key(coach_name))
    where public.coach_name_key(coach_name) is not null;
exception
  when duplicate_table then null;
  when unique_violation then
    raise warning 'existing coach names are not unique yet; new duplicates are still blocked';
end $$;

-- ---------------------------------------------------------------------------
-- One conversation per pair. participant_a is the smaller id so the pair
-- cannot be stored twice.
-- ---------------------------------------------------------------------------

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  participant_a uuid not null references public.profiles (id),
  participant_b uuid not null references public.profiles (id),
  last_activity_at timestamptz,
  created_at timestamptz not null default now(),
  constraint conversations_ordered check (participant_a < participant_b),
  constraint conversations_pair unique (participant_a, participant_b)
);

comment on table public.conversations is
  'One thread for two people. last_activity_at moves when a message is saved, never when someone likes a message.';

alter table public.messages
  add column if not exists conversation_id uuid references public.conversations (id),
  add column if not exists origin_channel text,
  add column if not exists direction text,
  add column if not exists routed_to text;

alter table public.messages drop constraint if exists messages_origin_channel_chk;
alter table public.messages
  add constraint messages_origin_channel_chk
  check (origin_channel is null or origin_channel in ('app', 'sms'));

alter table public.messages drop constraint if exists messages_direction_chk;
alter table public.messages
  add constraint messages_direction_chk
  check (direction is null or direction in ('inbound', 'outbound'));

alter table public.messages drop constraint if exists messages_routed_to_chk;
alter table public.messages
  add constraint messages_routed_to_chk
  check (routed_to is null or routed_to in ('conversation', 'business'));

create index if not exists messages_conversation_id_idx on public.messages (conversation_id);

-- ---------------------------------------------------------------------------
-- Likes. They do not move last_activity_at and they do not send an SMS.
-- ---------------------------------------------------------------------------

create table if not exists public.message_reactions (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages (id) on delete cascade,
  user_id uuid not null references public.profiles (id),
  client_id uuid,
  reaction text not null check (reaction in ('heart', 'thumb')),
  source text not null check (source in ('app', 'sms_tapback')),
  channel text not null check (channel in ('app', 'sms')),
  direction text not null check (direction in ('inbound', 'outbound')),
  routed_to text not null check (routed_to in ('conversation', 'business')),
  created_at timestamptz not null default now(),
  unique (message_id, user_id)
);

create index if not exists message_reactions_message_idx on public.message_reactions (message_id);

comment on table public.message_reactions is
  'A heart or thumbs-up on a message. source is app or sms_tapback. Not an SMS and not a new message.';

-- Texts from a number that is not on an account, plus STOP / HELP, so they
-- are not thrown away.
create table if not exists public.lead_sms (
  id uuid primary key default gen_random_uuid(),
  phone text,
  sender_id uuid,
  body text not null,
  kind text not null default 'lead',
  channel text not null default 'sms',
  direction text not null default 'inbound',
  routed_to text not null default 'business',
  created_at timestamptz not null default now()
);

comment on table public.lead_sms is
  'Texts that are not a member thread: unknown numbers, and STOP / HELP. Owner-readable.';

-- Already live. Created here so a fresh database has the same lock the
-- texter uses to send each message once.
create table if not exists public.chat_auto_reply_sms (
  message_id uuid primary key,
  created_at timestamptz not null default now(),
  outcome text
);

alter table public.chat_auto_reply_sms enable row level security;
revoke all on public.chat_auto_reply_sms from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Who the other person is. A missing trainer, or the owner, means Business Chat.
-- ---------------------------------------------------------------------------

create or replace function public.message_other_party(p_client uuid, p_trainer uuid)
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when p_trainer is null or exists (
      select 1 from public.profiles p where p.id = p_trainer and p.role = 'owner'
    )
    then (
      select o.id from public.profiles o
      where o.role = 'owner' and o.deleted_at is null
      order by o.created_at
      limit 1
    )
    else p_trainer
  end;
$$;

create or replace function public.message_routed_to(p_trainer uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when p_trainer is null then 'business'
    when exists (
      select 1 from public.profiles p where p.id = p_trainer and p.role = 'owner'
    ) then 'business'
    else 'conversation'
  end;
$$;

revoke all on function public.message_other_party(uuid, uuid) from public, anon, authenticated;
revoke all on function public.message_routed_to(uuid) from public, anon, authenticated;

-- The text handler runs as the service role and must be able to ask for a
-- coach's public name. It must not read the legal name.
do $$
begin
  grant execute on function public.coach_public_name(uuid) to service_role;
exception
  when undefined_function then
    raise warning 'coach_public_name is not installed yet';
end $$;

-- Backfill. Re-running updates the link and leaves the body alone.
insert into public.conversations (participant_a, participant_b, last_activity_at, created_at)
select
  least(m.client_id, m.other_id),
  greatest(m.client_id, m.other_id),
  coalesce(max(m.created_at) filter (where m.who is distinct from 'auto'), max(m.created_at)),
  min(m.created_at)
from (
  select
    msg.client_id,
    msg.who,
    msg.created_at,
    public.message_other_party(msg.client_id, msg.trainer_id) as other_id
  from public.messages msg
) m
where m.client_id is not null
  and m.other_id is not null
  and m.client_id <> m.other_id
group by least(m.client_id, m.other_id), greatest(m.client_id, m.other_id)
on conflict (participant_a, participant_b) do update
  set last_activity_at = greatest(
    coalesce(public.conversations.last_activity_at, excluded.last_activity_at),
    coalesce(excluded.last_activity_at, public.conversations.last_activity_at)
  );

update public.messages msg
set
  conversation_id = c.id,
  origin_channel = coalesce(msg.origin_channel, case when msg.channel = 'sms' then 'sms' else 'app' end),
  direction = coalesce(msg.direction, case when msg.channel = 'sms' then 'inbound' else 'outbound' end),
  routed_to = coalesce(msg.routed_to, public.message_routed_to(msg.trainer_id))
from public.conversations c
where msg.client_id is not null
  and public.message_other_party(msg.client_id, msg.trainer_id) is not null
  and public.message_other_party(msg.client_id, msg.trainer_id) <> msg.client_id
  and c.participant_a = least(msg.client_id, public.message_other_party(msg.client_id, msg.trainer_id))
  and c.participant_b = greatest(msg.client_id, public.message_other_party(msg.client_id, msg.trainer_id))
  and (
    msg.conversation_id is null
    or msg.origin_channel is null
    or msg.direction is null
    or msg.routed_to is null
  );

-- ---------------------------------------------------------------------------
-- Phone match for an inbound text. Finds coaches as well as clients.
-- One match is used. Several matches with exactly one client: that client.
-- Otherwise null — we do not guess.
-- ---------------------------------------------------------------------------

create or replace function public.profile_id_for_sms(raw_phone text)
returns uuid
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  digits text := regexp_replace(coalesce(raw_phone, ''), '[^0-9]', '', 'g');
  tail text;
  ids uuid[];
  client_ids uuid[];
begin
  if length(digits) < 7 then
    return null;
  end if;
  tail := right(digits, least(10, length(digits)));
  select
    array_agg(p.id),
    array_agg(p.id) filter (where p.role = 'client')
  into ids, client_ids
  from public.profiles p
  where p.deleted_at is null
    and right(regexp_replace(coalesce(p.phone, ''), '[^0-9]', '', 'g'), length(tail)) = tail;
  if ids is null or cardinality(ids) = 0 then
    return null;
  end if;
  if cardinality(ids) = 1 then
    return ids[1];
  end if;
  if client_ids is not null and cardinality(client_ids) = 1 then
    return client_ids[1];
  end if;
  return null;
end;
$$;

revoke all on function public.profile_id_for_sms(text) from public, anon, authenticated;
grant execute on function public.profile_id_for_sms(text) to service_role;

-- ---------------------------------------------------------------------------
-- Stamp the new columns and make sure the pair exists. Does not change the
-- body. The existing before-insert trigger still adds the name prefix.
-- ---------------------------------------------------------------------------

create or replace function public.messages_stamp_route()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  other uuid;
  a uuid;
  b uuid;
begin
  if new.client_id is null then
    return new;
  end if;

  if new.routed_to is null then
    new.routed_to := public.message_routed_to(new.trainer_id);
  end if;

  if new.origin_channel is null then
    new.origin_channel := case when new.channel = 'sms' then 'sms' else 'app' end;
  end if;

  if new.direction is null then
    new.direction := case when new.origin_channel = 'sms' then 'inbound' else 'outbound' end;
  end if;

  other := public.message_other_party(new.client_id, new.trainer_id);
  if other is null or other = new.client_id then
    return new;
  end if;

  a := least(new.client_id, other);
  b := greatest(new.client_id, other);
  insert into public.conversations (participant_a, participant_b, last_activity_at, created_at)
  values (a, b, new.created_at, coalesce(new.created_at, now()))
  on conflict (participant_a, participant_b) do nothing;

  select id into new.conversation_id
  from public.conversations
  where participant_a = a and participant_b = b;

  return new;
end;
$$;

drop trigger if exists trg_messages_stamp_route on public.messages;
create trigger trg_messages_stamp_route
  before insert on public.messages
  for each row execute function public.messages_stamp_route();

-- ---------------------------------------------------------------------------
-- Replaces the "your coach has received your message" note.
-- A real message moves the 6-hour window and, when SMS was one of the
-- channels, asks chat-auto-reply-sms to text the other person.
-- Likes are not messages, so they never reach this function.
-- ---------------------------------------------------------------------------

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
  if not has_sms then
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

drop trigger if exists trg_messages_auto_reply on public.messages;
create trigger trg_messages_auto_reply
  after insert on public.messages
  for each row execute function public.messages_auto_reply();

-- ---------------------------------------------------------------------------
-- Who can read what. Same idea as messages: a client sees their own thread,
-- a coach or the owner sees the threads staff already see.
-- ---------------------------------------------------------------------------

alter table public.conversations enable row level security;
alter table public.message_reactions enable row level security;
alter table public.lead_sms enable row level security;

revoke all on public.conversations from anon;
revoke all on public.message_reactions from anon;
revoke all on public.lead_sms from anon;

grant select on public.conversations to authenticated;
grant select, insert, update on public.message_reactions to authenticated;
grant select on public.lead_sms to authenticated;

drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations
  for select to authenticated
  using (
    participant_a = auth.uid()
    or participant_b = auth.uid()
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role in ('coach', 'owner')
    )
  );

drop policy if exists reactions_select on public.message_reactions;
create policy reactions_select on public.message_reactions
  for select to authenticated
  using (
    exists (
      select 1 from public.messages m
      where m.id = message_id
        and (
          m.client_id = auth.uid()
          or m.sender_id = auth.uid()
          or exists (
            select 1 from public.profiles p
            where p.id = auth.uid() and p.role in ('coach', 'owner')
          )
        )
    )
  );

drop policy if exists reactions_insert on public.message_reactions;
create policy reactions_insert on public.message_reactions
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.messages m
      where m.id = message_id
        and (
          m.client_id = auth.uid()
          or m.sender_id = auth.uid()
          or exists (
            select 1 from public.profiles p
            where p.id = auth.uid() and p.role in ('coach', 'owner')
          )
        )
    )
  );

drop policy if exists reactions_update on public.message_reactions;
create policy reactions_update on public.message_reactions
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists lead_sms_owner on public.lead_sms;
create policy lead_sms_owner on public.lead_sms
  for select to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'owner'
    )
  );

-- New profile columns. A person may set their own consent and the intro flag.
grant update (
  sms_opted_out,
  sms_consent_at,
  sms_consent_text,
  chat_intro_seen_at
) on public.profiles to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.message_reactions;
exception
  when duplicate_object then null;
  when undefined_object then null;
end $$;
