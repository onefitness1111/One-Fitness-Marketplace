-- 1. "Change Location" on the client booking screen saves the client's
--    chosen gym location to clients.booking_location, but that column was
--    never created, so every save failed and the choice was forgotten.
--    Values: null = never chosen, '*' = "Any location", else a location
--    name from platform settings.
--
--    Writes: the table-level UPDATE already in place plus the existing row
--    policy clients_update_self_or_staff (a client may update only their
--    own row; staff may update any client row). Reads: added to the
--    least-privilege column list from 20261123020000, so a client reads
--    only their own row (clients_select_self_or_staff).
alter table public.clients add column if not exists booking_location text;

alter table public.clients drop constraint if exists clients_booking_location_len;
alter table public.clients add constraint clients_booking_location_len
  check (booking_location is null or char_length(booking_location) between 1 and 120);

grant select (booking_location) on public.clients to authenticated;

-- 2. When a client saves a workout that has exercise swaps, stamp which log
--    and when, so send-push can check an "Exercise swap" alert is real.
--    Re-saving the same swaps doesn't restamp.
alter table public.client_records add column if not exists swaps_at timestamptz;
alter table public.client_records add column if not exists swap_log_id text;

create or replace function public.client_records_stamp_swap()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  new_logs jsonb := '[]'::jsonb;
  old_logs jsonb := '[]'::jsonb;
  e jsonb;
  prev jsonb;
begin
  if tg_op = 'UPDATE' then
    new.swaps_at := old.swaps_at;
    new.swap_log_id := old.swap_log_id;
    if (new.data -> 'workoutLogs') is not distinct from (old.data -> 'workoutLogs') then
      return new;
    end if;
    if jsonb_typeof(old.data -> 'workoutLogs') = 'array' then
      old_logs := old.data -> 'workoutLogs';
    end if;
  else
    new.swaps_at := null;
    new.swap_log_id := null;
  end if;
  if jsonb_typeof(new.data -> 'workoutLogs') = 'array' then
    new_logs := new.data -> 'workoutLogs';
  end if;

  for e in select value from jsonb_array_elements(new_logs) loop
    if jsonb_typeof(e -> 'swaps') = 'array' and jsonb_array_length(e -> 'swaps') > 0 then
      prev := null;
      select value into prev from jsonb_array_elements(old_logs)
       where value ->> 'id' = e ->> 'id' limit 1;
      if prev is null or (prev -> 'swaps') is distinct from (e -> 'swaps') then
        new.swaps_at := now();
        new.swap_log_id := e ->> 'id';
      end if;
    end if;
  end loop;
  return new;
end;
$$;

revoke all on function public.client_records_stamp_swap() from public, anon, authenticated;

drop trigger if exists trg_client_records_stamp_swap on public.client_records;
create trigger trg_client_records_stamp_swap
  before insert or update on public.client_records
  for each row execute function public.client_records_stamp_swap();

notify pgrst, 'reload schema';
