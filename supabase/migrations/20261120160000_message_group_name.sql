-- A broadcast can name the group. One-on-one messages leave this empty,
-- and those rows keep the coach-name prefix they already get.
-- Not applied from the app. Run it before deploying broadcast-message
-- and chat-auto-reply-sms.

alter table public.messages
  add column if not exists group_name text;

comment on column public.messages.group_name is
  'Broadcast label. Null on a one-on-one message. Texts use it instead of the coach name.';

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
  if nullif(btrim(new.group_name), '') is null then
    label := public.message_sender_label(new.sender_id, new.who);
    if label is not null and position(label || ':' in coalesce(new.body, '')) is distinct from 1 then
      new.body := label || ': ' || coalesce(new.body, '');
    end if;
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
