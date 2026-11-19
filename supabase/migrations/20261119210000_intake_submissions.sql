-- Re-submitting an intake archives the previous one instead of deleting it,
-- and tells the owner a new program is needed.
--
-- Not applied to the live database by this change. Run it in the SQL editor
-- when this update goes live, after 20261119140000_coach_public_name_only.sql.
--
-- Additive only. No existing grant is revoked, and client_records.data.intake
-- stays the current submission the App Store 1.1.0 build already reads.
-- Older builds ignore these tables.

create table if not exists public.intake_submissions (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles (id) on delete cascade,
  assessment_key text not null,
  answers jsonb not null default '{}'::jsonb,
  completed boolean not null default true,
  completed_at timestamptz,
  completed_by text,
  archived_at timestamptz,
  archived_by uuid,
  attachments jsonb not null default '[]'::jsonb,
  template_version integer,
  extra jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

comment on table public.intake_submissions is
  'One row per intake filing. archived_at null is the current submission for that client and form. Older filings stay so they can be read.';

create index if not exists intake_submissions_client_form_idx
  on public.intake_submissions (client_id, assessment_key, created_at desc);

create index if not exists intake_submissions_open_idx
  on public.intake_submissions (client_id, assessment_key)
  where archived_at is null;

alter table public.intake_submissions enable row level security;

revoke all on table public.intake_submissions from public, anon;

-- Same visibility as the client record: the client sees their own filings,
-- and a coach or the owner can see a client's filings. Nothing here is a
-- phone number or a billing address.
create policy intake_submissions_select on public.intake_submissions
  for select to authenticated
  using (
    client_id = auth.uid()
    or public.current_user_role() in ('coach', 'owner')
  );

create policy intake_submissions_insert on public.intake_submissions
  for insert to authenticated
  with check (
    client_id = auth.uid()
    or public.current_user_role() in ('coach', 'owner')
  );

create policy intake_submissions_update on public.intake_submissions
  for update to authenticated
  using (
    client_id = auth.uid()
    or public.current_user_role() in ('coach', 'owner')
  )
  with check (
    client_id = auth.uid()
    or public.current_user_role() in ('coach', 'owner')
  );

grant select, insert, update on table public.intake_submissions to authenticated;

create table if not exists public.program_refresh_flags (
  client_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null,
  flagged_at timestamptz not null default now(),
  primary key (client_id, kind),
  constraint program_refresh_flags_kind check (kind in ('training', 'nutrition'))
);

comment on table public.program_refresh_flags is
  'Set when a new intake is filed. Cleared when the owner saves the replacement program. training covers the training intake and the physical assessment; nutrition covers the nutrition intake.';

alter table public.program_refresh_flags enable row level security;

revoke all on table public.program_refresh_flags from public, anon;

create policy program_refresh_flags_select on public.program_refresh_flags
  for select to authenticated
  using (
    client_id = auth.uid()
    or public.current_user_role() in ('coach', 'owner')
  );

create policy program_refresh_flags_write on public.program_refresh_flags
  for all to authenticated
  using (
    client_id = auth.uid()
    or public.current_user_role() in ('coach', 'owner')
  )
  with check (
    client_id = auth.uid()
    or public.current_user_role() in ('coach', 'owner')
  );

grant select, insert, update, delete on table public.program_refresh_flags to authenticated;
