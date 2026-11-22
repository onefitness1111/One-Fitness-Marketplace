-- The owner reads every message and every thread.
-- A coach still reads every message, the same as before. The coach app
-- keeps its own list. Nothing here looks at clients.primary_trainer_id
-- or at who is assigned to a client.
-- Not applied to the live database by this change.

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages
  for select to authenticated
  using (
    (
      client_id = (select auth.uid())
      or (select public.current_user_role()) in ('coach', 'owner')
    )
    and not exists (
      select 1 from public.blocks b
      where (
        b.blocker_id = (select auth.uid()) and b.blocked_id = messages.sender_id
      ) or (
        b.blocked_id = (select auth.uid()) and b.blocker_id = messages.sender_id
      )
    )
  );

drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations
  for select to authenticated
  using (
    participant_a = (select auth.uid())
    or participant_b = (select auth.uid())
    or (select public.current_user_role()) in ('coach', 'owner')
  );

-- One unread key per client thread the owner has not opened.
-- Business texts, including SMS routed to the business, use "business".
-- A coach's own keys are unchanged.
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

  select 'owner:' || m.client_id::text || ':' ||
    case
      when m.routed_to = 'business'
        or m.trainer_id is null
        or exists (
          select 1 from public.profiles p where p.id = m.trainer_id and p.role = 'owner'
        )
      then 'business'
      else m.trainer_id::text
    end
  from public.messages m
  where public.is_owner()
    and m.client_id is distinct from auth.uid()
    and m.who is distinct from 'auto'
    and m.sender_id is distinct from auth.uid()
    and not (m.sender_id is null and m.who = 'client')
    and m.created_at > coalesce((
      select r.last_read_at
      from public.thread_reads r
      where r.user_id = auth.uid()
        and r.thread_key = 'owner:' || m.client_id::text || ':' ||
          case
            when m.routed_to = 'business'
              or m.trainer_id is null
              or exists (
                select 1 from public.profiles p where p.id = m.trainer_id and p.role = 'owner'
              )
            then 'business'
            else m.trainer_id::text
          end
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
  elsif p_list_key ~ '^owner:[0-9a-fA-F-]{36}:(business|[0-9a-fA-F-]{36})$' then
    if not public.is_owner() then
      return;
    end if;
    key := p_list_key;
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

notify pgrst, 'reload schema';
