-- Grants the fresh-project hole, and the intake form table the app loads
-- at startup. Run after 20261119110000_session_refund_notice.sql.
--
-- Newer Supabase projects do not grant new tables and functions to
-- anon, authenticated, or service_role. A policy is not a grant. This
-- file states the privilege each object created in this repo actually
-- needs. It does not hand authenticated the service-only functions
-- (the cron password, unpaid-fee writes, SMS routing).
--
-- Column audit against the app's selects, after phase0's column list:
--   clients.booking_restricted and booking_restricted_reason are selected
--   on the home roster and were never granted.
--   clients.grace_booking_used is read through client_booking_hold.
--   clients.emergency_contact_phone stays revoked; the app uses
--   client_emergency_phone.
--   profiles.phone stays revoked; the app uses profile_contact_for.
--   profiles.chat_intro_seen_at, sms_consent_at, and sms_opted_out are
--   not granted on the table. my_messaging_prefs returns them for the
--   signed-in person only. Names stay behind profile_directory.
--   trainers.coach_name is already granted. secondary_coach_name stays
--   behind profile_directory.

grant select (booking_restricted, booking_restricted_reason)
  on table public.clients to authenticated;

create or replace function public.my_messaging_prefs()
returns table (
  chat_intro_seen_at timestamptz,
  sms_consent_at timestamptz,
  sms_opted_out boolean
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select p.chat_intro_seen_at, p.sms_consent_at, p.sms_opted_out
  from public.profiles p
  where p.id = (select auth.uid());
$$;

revoke all on function public.my_messaging_prefs() from public, anon;
grant execute on function public.my_messaging_prefs() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Gym-defined intake forms. A new version is a new row. Nothing is deleted.
-- ---------------------------------------------------------------------------

create table if not exists public.intake_form_templates (
  key text not null,
  version integer not null,
  title text not null,
  schema jsonb not null default '{"sections":[]}'::jsonb,
  allows_attachments boolean not null default true,
  client_can_fill boolean not null default true,
  archived boolean not null default false,
  created_by text not null default '',
  created_at timestamptz not null default now(),
  primary key (key, version),
  constraint intake_form_templates_version check (version >= 1),
  constraint intake_form_templates_key_shape check (key ~ '^[a-z][a-z0-9_]{0,39}$')
);

comment on table public.intake_form_templates is
  'Every version of a gym-defined intake form. A submission names the version it was filled against.';

alter table public.intake_form_templates enable row level security;

revoke all on table public.intake_form_templates from public, anon;
grant select, insert, update on table public.intake_form_templates to authenticated;
grant all on table public.intake_form_templates to service_role;

drop policy if exists intake_form_templates_select on public.intake_form_templates;
create policy intake_form_templates_select
  on public.intake_form_templates
  for select
  to authenticated
  using (true);

drop policy if exists intake_form_templates_insert on public.intake_form_templates;
create policy intake_form_templates_insert
  on public.intake_form_templates
  for insert
  to authenticated
  with check (public.current_user_role() = 'owner');

drop policy if exists intake_form_templates_update on public.intake_form_templates;
create policy intake_form_templates_update
  on public.intake_form_templates
  for update
  to authenticated
  using (public.current_user_role() = 'owner')
  with check (public.current_user_role() = 'owner');

-- ---------------------------------------------------------------------------
-- Tables created in this repo. service_role is what the edge functions use.
-- authenticated keeps only the access the earlier files already described.
-- ---------------------------------------------------------------------------

grant all on table public.coach_code_attempts to service_role;
grant all on table public.outbound_message_log to service_role;

grant select on table public.coach_requests to authenticated;
grant all on table public.coach_requests to service_role;

grant select on table public.coach_applications to authenticated;
grant all on table public.coach_applications to service_role;

grant select, insert, update on table public.live_day_runs to authenticated;
grant all on table public.live_day_runs to service_role;

grant all on table public.client_balance_ledger to service_role;

grant select, insert, update on table public.thread_reads to authenticated;
grant all on table public.thread_reads to service_role;

grant select on table public.app_config to anon, authenticated;
grant all on table public.app_config to service_role;

grant select on table public.client_notices to authenticated;
grant all on table public.client_notices to service_role;

grant all on table public.package_renewal_charges to service_role;
grant all on table public.monthly_progress_sends to service_role;

grant select on table public.quiet_nudges to authenticated;
grant all on table public.quiet_nudges to service_role;

grant select on table public.conversations to authenticated;
grant all on table public.conversations to service_role;

grant select, insert, update on table public.message_reactions to authenticated;
grant all on table public.message_reactions to service_role;

grant select on table public.lead_sms to authenticated;
grant all on table public.lead_sms to service_role;

grant all on table public.chat_auto_reply_sms to service_role;

-- ---------------------------------------------------------------------------
-- Functions the app or an edge function calls.
-- ---------------------------------------------------------------------------

grant execute on function public.coach_code_status(text) to anon, authenticated, service_role;
grant execute on function public.grant_coach_with_code(text) to authenticated, service_role;
grant execute on function public.owner_promote_coach(uuid) to authenticated, service_role;
grant execute on function public.profile_contact_for(uuid[]) to authenticated, service_role;
grant execute on function public.set_client_balance(uuid, integer) to authenticated, service_role;
grant execute on function public.client_billing_for(uuid[]) to authenticated, service_role;
grant execute on function public.trainer_pay_for(uuid[]) to authenticated, service_role;
grant execute on function public.coach_free_adds_used() to authenticated, service_role;
grant execute on function public.submit_coach_request(text, uuid, text, jsonb) to authenticated, service_role;
grant execute on function public.decide_coach_request(uuid, boolean, text) to authenticated, service_role;
grant execute on function public.mark_request_applied(uuid, uuid) to authenticated, service_role;
grant execute on function public.due_freeze_requests() to authenticated, service_role;
grant execute on function public.owner_set_client_restriction(uuid, boolean, text) to authenticated, service_role;
grant execute on function public.book_single_session(uuid, uuid, date, integer, text, text, text) to service_role;
grant execute on function public.coach_public_name(uuid) to authenticated, service_role;
grant execute on function public.profile_directory() to authenticated, service_role;
grant execute on function public.message_sender_label(uuid, text) to authenticated, service_role;
grant execute on function public.client_plan_allowance(uuid, text) to authenticated, service_role;
grant execute on function public.sessions_toward_booking_limit(uuid, text, uuid) to authenticated, service_role;
grant execute on function public.coach_works_with_client(uuid) to authenticated, service_role;
grant execute on function public.start_live_day(uuid, date, text, text, text, uuid) to authenticated, service_role;
grant execute on function public.end_live_logs(uuid, date, text) to authenticated, service_role;
grant execute on function public.append_workout_log(uuid, jsonb) to authenticated, service_role;
grant execute on function public.close_recent_expired_session_runs() to authenticated, service_role;
grant execute on function public.current_user_role() to authenticated, service_role;
grant execute on function public.is_owner() to authenticated, service_role;
grant execute on function public.patch_client_record(uuid, jsonb) to authenticated, service_role;
grant execute on function public.patch_client_intake(uuid, text, jsonb) to authenticated, service_role;
grant execute on function public.can_read_client_file(text, text) to authenticated, service_role;
grant execute on function public.cancel_fee_for(uuid) to service_role;
grant execute on function public.attendance_fee_for(uuid) to service_role;
grant execute on function public.cron_vault_secret() to service_role;
grant execute on function public.client_ledger_for(uuid) to authenticated, service_role;
grant execute on function public.client_balances_for(uuid[]) to authenticated, service_role;
grant execute on function public.record_unpaid_fee(uuid, text, integer, uuid, uuid, text, text) to service_role;
grant execute on function public.settle_ledger_paid(uuid, text, text) to service_role;
grant execute on function public.apply_balance_payment(uuid, integer, text, text) to service_role;
grant execute on function public.waive_client_balance(uuid) to authenticated, service_role;
grant execute on function public.client_booking_hold(uuid) to authenticated, service_role;
grant execute on function public.my_unread_chat_keys() to authenticated, service_role;
grant execute on function public.mark_chat_read(text) to authenticated, service_role;
grant execute on function public.client_billing_address(uuid) to authenticated, service_role;
grant execute on function public.client_file_flags(uuid) to authenticated, service_role;
grant execute on function public.set_client_phone(uuid, text) to authenticated, service_role;
grant execute on function public.set_client_billing_address(uuid, jsonb) to authenticated, service_role;
grant execute on function public.client_emergency_phone(uuid) to authenticated, service_role;
grant execute on function public.broadcast_allowed_clients(uuid) to service_role;
grant execute on function public.dismiss_package_renewal(text, date, text) to authenticated, service_role;
grant execute on function public.mark_merit_badges_seen(uuid[]) to authenticated, service_role;
grant execute on function public.profile_id_for_sms(text) to service_role;
grant execute on function public.client_last_log_on(jsonb, timestamptz) to service_role;
grant execute on function public.quiet_nudge_roster(date) to service_role;
grant execute on function public.claim_quiet_nudge(uuid, date, text, date, uuid) to service_role;
grant execute on function public.clear_quiet_nudge(uuid, date) to service_role;

-- Triggers fire as the person writing the row, so that person needs execute.
-- These do not expose a new way to change data: the table privileges and
-- the function bodies still decide what the write may do.
grant execute on function public.handle_new_user() to service_role;
grant execute on function public.prevent_role_escalation() to authenticated, service_role;
grant execute on function public.trainers_guard_role_and_pay() to authenticated, service_role;
grant execute on function public.profiles_guard_private() to authenticated, service_role;
grant execute on function public.guard_client_balance() to authenticated, service_role;
grant execute on function public.clients_guard_billing() to authenticated, service_role;
grant execute on function public.guard_coach_gated_client_fields() to authenticated, service_role;
grant execute on function public.block_restricted_client_booking() to authenticated, service_role;
grant execute on function public.coach_name_key(text) to authenticated, service_role;
grant execute on function public.trainers_coach_name_unique() to authenticated, service_role;
grant execute on function public.messages_before_insert() to authenticated, service_role;
grant execute on function public.messages_auto_reply() to authenticated, service_role;
grant execute on function public.messages_stamp_route() to authenticated, service_role;
grant execute on function public.enforce_client_session_allowance() to authenticated, service_role;
grant execute on function public.release_single_session_credit() to authenticated, service_role;
grant execute on function public.sync_single_session_credit_attendance() to authenticated, service_role;
grant execute on function public.phone_digits(text) to authenticated, service_role;
grant execute on function public.enforce_profile_phone() to authenticated, service_role;
grant execute on function public.reset_grace_when_balance_clear() to authenticated, service_role;
grant execute on function public.block_unpaid_balance_booking() to authenticated, service_role;
grant execute on function public.mark_grace_booking() to authenticated, service_role;
grant execute on function public.protect_challenge_badges() to authenticated, service_role;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.handle_new_user() to supabase_auth_admin;
  end if;
end $$;

notify pgrst, 'reload schema';
