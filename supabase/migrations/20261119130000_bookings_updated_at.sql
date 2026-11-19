-- A booking remembers when it last changed, so a subscribed calendar can
-- tell a reschedule from the same event. Run after
-- 20261119120000_grants_and_intake_templates.sql.
--
-- Existing rows get the time this column is added. The next edit moves it.

alter table public.bookings
  add column if not exists updated_at timestamptz not null default now();

create or replace function public.bookings_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_bookings_set_updated_at on public.bookings;
create trigger trg_bookings_set_updated_at
  before update on public.bookings
  for each row
  execute function public.bookings_set_updated_at();

grant execute on function public.bookings_set_updated_at() to authenticated, service_role;
