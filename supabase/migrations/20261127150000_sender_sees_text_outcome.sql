-- The sender sees when a text was skipped and why (Coach Chris, Nov 27,
-- 2026). chat-auto-reply-sms writes the outcome for each message ("sent 1",
-- "skipped: replied STOP", "held: invites off", ...). The person who sent
-- the message can read its outcome; the owner can read all of them.
-- The outcome names a reason only: no phone number or other contact detail.

drop policy if exists chat_auto_reply_sms_sender_select on public.chat_auto_reply_sms;
create policy chat_auto_reply_sms_sender_select on public.chat_auto_reply_sms
  for select to authenticated
  using (
    (select public.is_owner())
    or exists (
      select 1 from public.messages m
      where m.id = chat_auto_reply_sms.message_id
        and m.sender_id = (select auth.uid())
    )
  );

grant select on public.chat_auto_reply_sms to authenticated;

notify pgrst, 'reload schema';
