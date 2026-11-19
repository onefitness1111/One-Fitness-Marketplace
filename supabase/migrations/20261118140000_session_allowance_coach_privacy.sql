-- Session allowance, and coach legal-name privacy.
--
-- Not applied to the live database by this change. Deploy it when the
-- matching app build goes out.
--
-- Booking rule:
--   * A client may book up to the sessions on their plan (the booking limit).
--   * A booking does not use a session. Check-in and no-show do.
--   * Early cancel and late cancel do not use a session. The spot is free
--     again as soon as the booking is cancelled. Any late-cancel fee is
--     separate and is not touched here.
--   * Two bookings at once cannot both slip past the limit: the check locks
--     the client's plan for the transaction before it counts.

-- ---------------------------------------------------------------------------
-- Coach names
-- ---------------------------------------------------------------------------

alter table public.trainers
  add column if not exists coach_name text,
  add column if not exists secondary_coach_name text;

comment on column public.trainers.coach_name is
  'The only name clients and other coaches see, e.g. Coach Chris.';
comment on column public.trainers.secondary_coach_name is
  'Owner-only. Never returned to a client or another coach.';

-- Clients and other coaches may read the public coach name. They may not
-- read the secondary name. The owner and the coach themselves receive it
-- from profile_directory(), which runs with definer rights.
grant select (coach_name) on table public.trainers to authenticated;
grant insert (coach_name, secondary_coach_name) on table public.trainers to authenticated;
grant update (coach_name, secondary_coach_name) on table public.trainers to authenticated;

-- The legal name columns are no longer readable through the table API.
-- profile_directory() is what the app loads, and it blanks them unless the
-- caller is the owner or is reading their own row.
revoke select (name, first_name, last_name) on table public.profiles from anon, authenticated;

create or replace function public.coach_public_name(p_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    nullif(btrim(t.coach_name), ''),
    nullif(
      'Coach ' || nullif(btrim(split_part(coalesce(nullif(btrim(p.first_name), ''), p.name, ''), ' ', 1)), ''),
      'Coach '
    ),
    'Coach'
  )
  from public.profiles p
  left join public.trainers t on t.profile_id = p.id
  where p.id = p_id;
$$;

revoke all on function public.coach_public_name(uuid) from public, anon;
grant execute on function public.coach_public_name(uuid) to authenticated;

-- One row per profile, already safe to put on a phone.
-- A coach's legal name, first name, last name and secondary coach name are
-- present only for the owner and for that coach. Everyone else gets the
-- public coach name in `name` and nulls in the private columns.
-- A client's own name is unchanged: coaches need it, and this rule is about
-- coaches' legal names.
create or replace function public.profile_directory()
returns table (
  id uuid,
  role text,
  name text,
  first_name text,
  last_name text,
  photo_url text,
  created_at timestamptz,
  push_opt_in boolean,
  accepted_terms_at timestamptz,
  accepted_terms_version text,
  over_18_confirmed_at timestamptz,
  banned_at timestamptz,
  ban_reason text,
  deleted_at timestamptz,
  coach_name text,
  secondary_coach_name text
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    p.id,
    p.role,
    case
      when p.role = 'coach' and not (public.is_owner() or p.id = auth.uid())
        then public.coach_public_name(p.id)
      else p.name
    end,
    case
      when p.role = 'coach' and not (public.is_owner() or p.id = auth.uid())
        then null
      else p.first_name
    end,
    case
      when p.role = 'coach' and not (public.is_owner() or p.id = auth.uid())
        then null
      else p.last_name
    end,
    p.photo_url,
    p.created_at,
    p.push_opt_in,
    p.accepted_terms_at,
    p.accepted_terms_version,
    p.over_18_confirmed_at,
    p.banned_at,
    p.ban_reason,
    p.deleted_at,
    case when p.role = 'coach' then public.coach_public_name(p.id) else null end,
    case
      when p.role = 'coach' and (public.is_owner() or p.id = auth.uid())
        then t.secondary_coach_name
      else null
    end
  from public.profiles p
  left join public.trainers t on t.profile_id = p.id
  where p.deleted_at is null;
$$;

revoke all on function public.profile_directory() from public, anon;
grant execute on function public.profile_directory() to authenticated;

-- ---------------------------------------------------------------------------
-- Chat and SMS-visible message prefix
-- ---------------------------------------------------------------------------
-- Every stored message starts with the sender's public name, a colon, and
-- the text. Coaches use their coach name. Clients use their client name.
-- The owner, writing as the business, uses ONE Fitness Marketplace.
-- The legal name is never written into a message a client can read.

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
    return 'ONE Fitness Marketplace';
  end if;
  if r = 'coach' or p_who = 'trainer' then
    return public.coach_public_name(p_sender);
  end if;
  return coalesce(nullif(btrim(n), ''), 'Client');
end;
$$;

revoke all on function public.message_sender_label(uuid, text) from public, anon;
grant execute on function public.message_sender_label(uuid, text) to authenticated;

create or replace function public.messages_before_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  hits text[];
  label text;
begin
  label := public.message_sender_label(new.sender_id, new.who);
  if label is not null and position(label || ':' in coalesce(new.body, '')) is distinct from 1 then
    new.body := label || ': ' || coalesce(new.body, '');
  end if;

  hits := public.objectionable_words(new.body);
  if array_length(hits, 1) is not null then
    raise exception 'objectionable_content: %', array_to_string(hits, ', ')
      using errcode = 'check_violation';
  end if;

  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = new.sender_id and b.blocked_id =
            case when new.who = 'client' then new.trainer_id else new.client_id end)
       or (b.blocked_id = new.sender_id and b.blocker_id =
            case when new.who = 'client' then new.trainer_id else new.client_id end)
  ) then
    raise exception 'blocked: this conversation is unavailable'
      using errcode = 'check_violation';
  end if;

  if exists (select 1 from public.profiles p where p.id = new.sender_id and p.banned_at is not null) then
    raise exception 'account_suspended: this account can no longer post'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- Auto-replies use the same prefix. A coach's note starts with the coach
-- name. A note from the business starts with ONE Fitness Marketplace.
create or replace function public.messages_auto_reply()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
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
  reply_sender uuid;
  last_reply timestamptz;
  text_back boolean := false;
  label text;
begin
  if new.who is distinct from 'client' then
    return new;
  end if;
  if new.sender_id is distinct from new.client_id then
    return new;
  end if;
  if new.channel = 'sms' and auth.uid() is null then
    return new;
  end if;

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
  if cardinality(tokens) = 0 then
    tokens := array['inapp'];
  end if;
  has_sms := 'sms' = any(tokens);
  has_inapp := 'inapp' = any(tokens);

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
      label := public.coach_public_name(new.trainer_id);
      reply_body := label || ': ' || coach_auto_reply;
      reply_sender := new.trainer_id;
      text_back := has_sms;
      select max(m.created_at) into last_reply
      from public.messages m
      where m.client_id = new.client_id
        and m.who = 'trainer'
        and m.sender_id = new.trainer_id;
    else
      reply_body := 'ONE Fitness Marketplace: ' || business_auto_reply;
      reply_sender := new.client_id;
      select max(m.created_at) into last_reply
      from public.messages m
      join public.profiles p on p.id = m.sender_id
      where m.client_id = new.client_id
        and m.who = 'trainer'
        and p.role = 'owner';
    end if;

    if last_reply is not null
       and last_reply > now() - make_interval(hours => auto_reply_quiet_hours) then
      return new;
    end if;

    insert into public.messages (
      client_id, trainer_id, sender_id, who, body, channel, read_by_coach, created_at
    ) values (
      new.client_id,
      new.trainer_id,
      reply_sender,
      'auto',
      reply_body,
      'auto',
      true,
      new.created_at + interval '1 millisecond'
    );

    if text_back then
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
    raise warning 'chat auto-reply skipped: %', sqlerrm;
  end;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Session allowance
-- ---------------------------------------------------------------------------

create or replace function public.client_plan_allowance(p_client uuid, p_plan text)
returns integer
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  plan jsonb;
  kind text;
  base integer;
  override integer;
  override_month text;
  month text := to_char(current_date, 'YYYY-MM');
  rollover integer := 0;
begin
  if p_plan is null or p_plan like 'single:%' then
    return null;
  end if;
  select data into plan from public.membership_plans where id = p_plan;
  if plan is null then
    return null;
  end if;
  kind := coalesce(plan->>'kind', '');
  if kind in ('program', 'nutritionProgram') then
    return null;
  end if;
  base := coalesce((plan->>'maxSessions')::int, 0);
  if base <= 0 then
    return null;
  end if;

  select c.session_count_override, c.session_count_override_month
    into override, override_month
  from public.clients c
  where c.profile_id = p_client;

  if override is not null then
    if not (kind = 'membership' and override_month is not null and override_month <> month) then
      base := override;
    end if;
  end if;

  if kind = 'membership' then
    select coalesce((e->>'rolloverSessions')::int, 0)
      into rollover
    from public.clients c
    cross join lateral jsonb_array_elements(coalesce(c.plans, '[]'::jsonb)) e
    where c.profile_id = p_client
      and e->>'planId' = p_plan
      and coalesce(e->>'status', '') = 'active'
      and e->>'rolloverMonth' = month
    limit 1;
    base := base + coalesce(rollover, 0);
  end if;
  return base;
end;
$$;

revoke all on function public.client_plan_allowance(uuid, text) from public, anon;
grant execute on function public.client_plan_allowance(uuid, text) to authenticated;

-- How many of this plan's sessions are on the books. Each booking counts
-- once. Cancels do not count. Checked-in and no-show count (they are used).
-- Future bookings count (they hold a spot) but they are not "used up".
create or replace function public.sessions_toward_booking_limit(
  p_client uuid,
  p_plan text,
  p_except uuid
)
returns integer
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  kind text;
  month text := to_char(current_date, 'YYYY-MM');
  n integer;
begin
  select coalesce(data->>'kind', '') into kind
  from public.membership_plans where id = p_plan;

  select count(*) into n
  from public.bookings b
  where b.client_id = p_client
    and (p_except is null or b.id is distinct from p_except)
    and b.cancelled_at is null
    and coalesce(b.is_physical_assessment, false) = false
    and coalesce(b.attendance_status, '') not in ('early-cancel', 'late-cancel')
    and coalesce(b.plan_id, '') not like 'single:%'
    and b.plan_id = p_plan
    and (kind is distinct from 'membership' or to_char(b.date, 'YYYY-MM') = month);
  return coalesce(n, 0);
end;
$$;

revoke all on function public.sessions_toward_booking_limit(uuid, text, uuid) from public, anon;
grant execute on function public.sessions_toward_booking_limit(uuid, text, uuid) to authenticated;

create or replace function public.enforce_client_session_allowance()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  allowance integer;
  used integer;
begin
  if new.cancelled_at is not null then
    return new;
  end if;
  if coalesce(new.is_physical_assessment, false) then
    return new;
  end if;
  if coalesce(new.attendance_status, '') in ('early-cancel', 'late-cancel') then
    return new;
  end if;
  if new.plan_id is null or new.plan_id like 'single:%' then
    return new;
  end if;
  -- Staff can still book someone past the limit, the same way the app
  -- already lets them. A client booking themselves cannot.
  if auth.role() = 'service_role' or public.current_user_role() in ('coach', 'owner') then
    return new;
  end if;
  if new.overridden_by is not null then
    return new;
  end if;

  -- One lock per client and plan, so two bookings at the same moment are
  -- counted one after the other. The second sees the first.
  perform pg_advisory_xact_lock(hashtextextended('allowance:' || new.client_id::text || ':' || new.plan_id, 0));
  perform 1 from public.clients where profile_id = new.client_id for update;

  allowance := public.client_plan_allowance(new.client_id, new.plan_id);
  if allowance is null then
    return new;
  end if;
  used := public.sessions_toward_booking_limit(new.client_id, new.plan_id, new.id);
  if used >= allowance then
    raise exception 'booking-limit: You''ve booked all % sessions on this plan. Cancelling one frees the spot right away.', allowance;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_client_session_allowance on public.bookings;
create trigger trg_enforce_client_session_allowance
  before insert or update of attendance_status, plan_id, cancelled_at, date
  on public.bookings
  for each row
  execute function public.enforce_client_session_allowance();

-- A single-session credit is reserved when it is booked, and used up only
-- on check-in or no-show. Deleting a booking that was not used gives the
-- credit back immediately. Deleting a checked-in or no-show booking does not.
create or replace function public.release_single_session_credit()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if old.plan_id is not null
     and old.plan_id like 'single:%'
     and coalesce(old.attendance_status, '') not in ('checked-in', 'no-show') then
    update public.single_session_credits
       set booking_id = null
     where id = substr(old.plan_id, 8)::uuid
       and booking_id = old.id;
  end if;
  return old;
end;
$$;

-- Early and late cancel release the credit at once. Check-in and no-show
-- keep it. An upcoming booking keeps the link so the same credit cannot be
-- booked twice, but that link is a reservation, not a used session.
create or replace function public.sync_single_session_credit_attendance()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  was_back boolean := coalesce(old.attendance_status, '') in ('early-cancel', 'late-cancel');
  is_back  boolean := coalesce(new.attendance_status, '') in ('early-cancel', 'late-cancel');
  cid uuid;
begin
  if new.plan_id is null or new.plan_id not like 'single:%' or was_back = is_back then
    return new;
  end if;
  cid := substr(new.plan_id, 8)::uuid;
  if is_back then
    update public.single_session_credits set booking_id = null where id = cid and booking_id = new.id;
  else
    update public.single_session_credits set booking_id = new.id where id = cid and booking_id is null;
  end if;
  return new;
end;
$$;
