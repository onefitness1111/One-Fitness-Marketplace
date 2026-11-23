-- One row per staff alert a client's own action sent through send-push
-- (new booking, cancel, sign-up, measurement, intake). The primary key makes
-- each alert send once, and the per-client count caps how many a client can
-- cause in an hour. Only the service role (send-push) reads or writes it.
create table if not exists public.client_event_alerts (
  kind          text        not null,
  ref           text        not null,
  recipient_id  uuid        not null references public.profiles(id) on delete cascade,
  caller_id     uuid        not null references public.profiles(id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (kind, ref, recipient_id)
);

create index if not exists client_event_alerts_caller_recent
  on public.client_event_alerts (caller_id, created_at desc);

alter table public.client_event_alerts enable row level security;
revoke all on table public.client_event_alerts from public, anon, authenticated;

-- When a client adds a measurement, stamp it, so send-push can check a
-- "Measurement logged" alert is real. client_records.updated_at is not kept
-- current, so it can't be used. Only an added entry counts (the app alerts
-- only on add), not an edit or delete.
alter table public.client_records add column if not exists measurements_at timestamptz;

create or replace function public.client_records_stamp_measurement()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  before_n int := 0;
  after_n  int := 0;
begin
  if jsonb_typeof(new.data -> 'measurements') = 'array' then
    after_n := jsonb_array_length(new.data -> 'measurements');
  end if;
  if tg_op = 'UPDATE' and jsonb_typeof(old.data -> 'measurements') = 'array' then
    before_n := jsonb_array_length(old.data -> 'measurements');
  end if;
  if after_n > before_n then
    new.measurements_at := now();
  elsif tg_op = 'UPDATE' then
    new.measurements_at := old.measurements_at;
  else
    new.measurements_at := null;
  end if;
  return new;
end;
$$;

revoke all on function public.client_records_stamp_measurement() from public, anon, authenticated;

drop trigger if exists trg_client_records_stamp_measurement on public.client_records;
create trigger trg_client_records_stamp_measurement
  before insert or update on public.client_records
  for each row execute function public.client_records_stamp_measurement();
