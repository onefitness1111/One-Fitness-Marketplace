-- Coaches see only their own chats (Coach Chris, Nov 27, 2026).
--
-- A coach's chats are the threads they are a participant in: messages
-- whose trainer_id is the coach (their thread with a client, including the
-- owner's replies and @tag hand-offs placed in it), or where the coach is
-- the client_id side. Not the Business Chat (trainer_id null or the owner)
-- and not another coach's threads. The owner still sees everything.
-- Nothing here looks at clients.primary_trainer_id.
--
-- staff_messages already works this way (sender, recipient, or owner).

-- public.is_owner() already exists (20261118190000_remaining_fixes.sql).

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages
  for select to authenticated
  using (
    (
      client_id = (select auth.uid())
      or trainer_id = (select auth.uid())
      or (select public.is_owner())
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

-- A coach writes as the trainer only into their own thread. The owner can
-- write into any thread (Business Chat or a coach's thread).
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages
  for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and (
      (who = 'client' and client_id = (select auth.uid()))
      or (who = 'trainer' and (select public.is_owner()))
      or (
        who = 'trainer'
        and trainer_id = (select auth.uid())
        and (select public.current_user_role()) = 'coach'
      )
    )
  );

drop policy if exists messages_update_staff on public.messages;
create policy messages_update_staff on public.messages
  for update to authenticated
  using (
    (select public.is_owner())
    or ((select public.current_user_role()) = 'coach' and trainer_id = (select auth.uid()))
  )
  with check (
    (select public.is_owner())
    or ((select public.current_user_role()) = 'coach' and trainer_id = (select auth.uid()))
  );

drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations
  for select to authenticated
  using (
    participant_a = (select auth.uid())
    or participant_b = (select auth.uid())
    or (select public.is_owner())
  );

drop policy if exists reactions_select on public.message_reactions;
create policy reactions_select on public.message_reactions
  for select to authenticated
  using (
    exists (
      select 1 from public.messages m
      where m.id = message_reactions.message_id
        and (
          m.client_id = (select auth.uid())
          or m.trainer_id = (select auth.uid())
          or m.sender_id = (select auth.uid())
          or (select public.is_owner())
        )
    )
  );

drop policy if exists reactions_insert on public.message_reactions;
create policy reactions_insert on public.message_reactions
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.messages m
      where m.id = message_reactions.message_id
        and (
          m.client_id = (select auth.uid())
          or m.trainer_id = (select auth.uid())
          or m.sender_id = (select auth.uid())
          or (select public.is_owner())
        )
    )
  );

notify pgrst, 'reload schema';
