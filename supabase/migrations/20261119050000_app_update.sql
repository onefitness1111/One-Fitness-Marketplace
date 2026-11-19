-- Which app version is current, and the store link for the update sheet.
-- Not applied to the live database by this change.
-- Run it after 20261119040000_broadcast_messages.sql.
--
-- Anyone can read the row, including someone who is signed out, so the
-- update sheet can show before login. Only the owner can change it.
-- The store link stays the placeholder until a real one is saved.

create table if not exists public.app_config (
  id text primary key,
  min_supported_version text not null,
  latest_version text not null,
  update_message text not null,
  force_update boolean not null default false,
  app_store_url text not null
);

insert into public.app_config (
  id, min_supported_version, latest_version, update_message, force_update, app_store_url
) values (
  'mobile',
  '1.0.0',
  '1.0.8',
  'The ONE Fitness app has been updated with lots of new features. Update now.',
  false,
  'APP_STORE_LINK'
)
on conflict (id) do nothing;

alter table public.app_config enable row level security;

revoke all on table public.app_config from public;
grant select on table public.app_config to anon, authenticated;

drop policy if exists app_config_select on public.app_config;
create policy app_config_select on public.app_config
  for select
  to anon, authenticated
  using (true);

drop policy if exists app_config_update on public.app_config;
create policy app_config_update on public.app_config
  for update
  to authenticated
  using (public.current_user_role() = 'owner')
  with check (public.current_user_role() = 'owner');

notify pgrst, 'reload schema';
