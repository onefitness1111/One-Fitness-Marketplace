-- Last-read per person per thread.
-- Not applied to the live database by this change. Run it after
-- 20261119080000_outstanding_balances.sql.
--
-- read_by_coach stays for older coach receipts. This table is the unread
-- dot: one row per user per thread, and each person can read only their own.
-- Existing threads are marked read now so history does not light up every
-- dot the moment this ships. A message after that does.

create table if not exists public.thread_reads (
  user_id uuid not null references public.profiles (id) on delete cascade,
  thread_key text not null,
  last_read_at timestamptz not null default now(),
  primary key (user_id, thread_key)
);

comment on table public.thread_reads is
  'When this person last opened a thread. They can see and write only their own rows.';

alter table public.thread_reads enable row level security;

revoke all on table public.thread_reads from public, anon;
grant select, insert, update on table public.thread_reads to authenticated;

drop policy if exists thread_reads_own on public.thread_reads;
create policy thread_reads_own
  on public.thread_reads
  for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- List keys the chat screens already use: a coach id, a client id,
-- "business", or "staff:…" . A message this person sent does not count.
create or replace function public.my_unread_chat_keys()
returns setof text
language sql
stable
security invoker
set search_path to 'public'
as $$
  with me as (
    select auth.uid() as id
  )
  select case
    when m.trainer_id is null or exists (
      select 1 from public.profiles p where p.id = m.trainer_id and p.role = 'owner'
    ) then 'business'
    else m.trainer_id::text
  end
  from public.messages m, me
  where me.id is not null
    and m.client_id = me.id
    and m.who is distinct from 'auto'
    and m.sender_id is distinct from me.id
    and not (
      m.sender_id is null
      and m.who = 'client'
    )
    and m.created_at > coalesce((
      select r.last_read_at
      from public.thread_reads r
      where r.user_id = me.id
        and r.thread_key = case
          when m.trainer_id is null or exists (
            select 1 from public.profiles p where p.id = m.trainer_id and p.role = 'owner'
          ) then 'business:' || m.client_id::text
          else 'pair:' || m.client_id::text || ':' || m.trainer_id::text
        end
    ), '-infinity'::timestamptz)

  union

  select m.client_id::text
  from public.messages m
  join public.profiles tp on tp.id = m.trainer_id and tp.role = 'coach'
  where m.trainer_id = auth.uid()
    and m.who is distinct from 'auto'
    and m.sender_id is distinct from auth.uid()
    and not (m.sender_id is null and m.who <> 'client')
    and m.created_at > coalesce((
      select r.last_read_at
      from public.thread_reads r
      where r.user_id = auth.uid()
        and r.thread_key = 'pair:' || m.client_id::text || ':' || m.trainer_id::text
    ), '-infinity'::timestamptz)

  union

  select m.client_id::text
  from public.messages m
  where public.is_owner()
    and m.client_id is distinct from auth.uid()
    and m.who is distinct from 'auto'
    and m.sender_id is distinct from auth.uid()
    and (
      m.trainer_id is null
      or m.trainer_id = auth.uid()
      or exists (select 1 from public.profiles p where p.id = m.trainer_id and p.role = 'owner')
    )
    and m.created_at > coalesce((
      select r.last_read_at
      from public.thread_reads r
      where r.user_id = auth.uid()
        and r.thread_key = 'business:' || m.client_id::text
    ), '-infinity'::timestamptz)

  union

  select 'staff:' || case
    when s.sender_id = auth.uid() then s.recipient_id
    else s.sender_id
  end::text
  from public.staff_messages s
  where s.recipient_id is not null
    and (s.sender_id = auth.uid() or s.recipient_id = auth.uid())
    and s.sender_id is distinct from auth.uid()
    and s.created_at > coalesce((
      select r.last_read_at
      from public.thread_reads r
      where r.user_id = auth.uid()
        and r.thread_key = 'staff:' || least(s.sender_id, s.recipient_id)::text
          || ':' || greatest(s.sender_id, s.recipient_id)::text
    ), '-infinity'::timestamptz)

  union

  select 'staff:market'
  from public.staff_messages s
  where s.recipient_id is null
    and public.is_owner()
    and s.sender_id is distinct from auth.uid()
    and s.created_at > coalesce((
      select r.last_read_at
      from public.thread_reads r
      where r.user_id = auth.uid()
        and r.thread_key = 'staff:market'
    ), '-infinity'::timestamptz);
$$;

revoke all on function public.my_unread_chat_keys() from public, anon;
grant execute on function public.my_unread_chat_keys() to authenticated;

create or replace function public.mark_chat_read(p_list_key text)
returns void
language plpgsql
security invoker
set search_path to 'public'
as $$
declare
  me uuid := auth.uid();
  key text;
  other uuid;
begin
  if me is null or p_list_key is null or btrim(p_list_key) = '' then
    return;
  end if;

  if p_list_key = 'business' then
    key := 'business:' || me::text;
  elsif p_list_key = 'staff:market' then
    if public.current_user_role() not in ('coach', 'owner') then
      return;
    end if;
    key := 'staff:market';
  elsif p_list_key like 'staff:%' then
    begin
      other := substr(p_list_key, 7)::uuid;
    exception when invalid_text_representation then
      return;
    end;
    key := 'staff:' || least(me, other)::text || ':' || greatest(me, other)::text;
  elsif p_list_key ~ '^[0-9a-fA-F-]{36}$' then
    other := p_list_key::uuid;
    if public.current_user_role() = 'client' then
      if exists (select 1 from public.profiles p where p.id = other and p.role = 'owner') then
        key := 'business:' || me::text;
      else
        key := 'pair:' || me::text || ':' || other::text;
      end if;
    elsif public.is_owner() then
      key := 'business:' || other::text;
    else
      key := 'pair:' || other::text || ':' || me::text;
    end if;
  else
    return;
  end if;

  insert into public.thread_reads (user_id, thread_key, last_read_at)
  values (me, key, now())
  on conflict (user_id, thread_key) do update
    set last_read_at = excluded.last_read_at;
end;
$$;

revoke all on function public.mark_chat_read(text) from public, anon;
grant execute on function public.mark_chat_read(text) to authenticated;

-- Catch everyone up. Messages already in the app are not unread.
insert into public.thread_reads (user_id, thread_key, last_read_at)
select distinct p.user_id, p.thread_key, now()
from (
  select m.client_id as user_id,
    case
      when m.trainer_id is null or exists (
        select 1 from public.profiles pr where pr.id = m.trainer_id and pr.role = 'owner'
      ) then 'business:' || m.client_id::text
      else 'pair:' || m.client_id::text || ':' || m.trainer_id::text
    end as thread_key
  from public.messages m
  where m.client_id is not null
  union
  select m.trainer_id,
    'pair:' || m.client_id::text || ':' || m.trainer_id::text
  from public.messages m
  join public.profiles pr on pr.id = m.trainer_id and pr.role = 'coach'
  where m.client_id is not null
  union
  select o.id, 'business:' || m.client_id::text
  from public.messages m
  join public.profiles o on o.role = 'owner' and o.deleted_at is null
  where m.client_id is not null
    and (
      m.trainer_id is null
      or m.trainer_id = o.id
      or exists (select 1 from public.profiles pr where pr.id = m.trainer_id and pr.role = 'owner')
    )
  union
  select s.sender_id,
    'staff:' || least(s.sender_id, s.recipient_id)::text || ':' || greatest(s.sender_id, s.recipient_id)::text
  from public.staff_messages s
  where s.recipient_id is not null
  union
  select s.recipient_id,
    'staff:' || least(s.sender_id, s.recipient_id)::text || ':' || greatest(s.sender_id, s.recipient_id)::text
  from public.staff_messages s
  where s.recipient_id is not null
  union
  select o.id, 'staff:market'
  from public.profiles o
  where o.role = 'owner' and o.deleted_at is null
) p
where p.user_id is not null
  and p.thread_key is not null
on conflict (user_id, thread_key) do nothing;

-- Realtime so the dot moves while the app is open. App resume re-reads too.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'thread_reads'
  ) then
    alter publication supabase_realtime add table public.thread_reads;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
  if to_regclass('public.staff_messages') is not null and not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'staff_messages'
  ) then
    alter publication supabase_realtime add table public.staff_messages;
  end if;
end $$;
