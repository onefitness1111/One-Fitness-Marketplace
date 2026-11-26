-- L8: Enforce reward point redemption bounds (min 40, max 100 per single
-- redemption) while allowing point balances to accumulate past 100 with no
-- balance cap.
-- Not applied to the live database by this change.

create or replace function public.enforce_points_redemption_bounds()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.type = 'redeem' then
    if new.amount is null or new.amount > -40 or new.amount < -100 then
      raise exception 'POINTS_REDEMPTION_OUT_OF_RANGE: A single reward redemption must be between 40 and 100 points (got %).',
        coalesce(abs(new.amount), 0);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_points_redemption_bounds on public.points_ledger;
create trigger trg_enforce_points_redemption_bounds
  before insert or update of type, amount on public.points_ledger
  for each row
  execute function public.enforce_points_redemption_bounds();

comment on function public.enforce_points_redemption_bounds() is
  'L8: Single reward redemption must be between 40 and 100 points (-40 to -100 ledger amount). No cap on accumulated balances.';
