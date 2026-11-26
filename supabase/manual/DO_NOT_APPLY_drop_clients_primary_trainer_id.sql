-- =====================================================================
-- DO NOT APPLY WITHOUT THE OWNER'S OKAY AND A FRESH DATABASE BACKUP.
-- =====================================================================
--
-- O5 (part 2 of 2): drop clients.primary_trainer_id for good.
--
-- This file is kept OUT of supabase/migrations on purpose so that
-- `supabase db push` and any automatic deploy never run it. Dropping a
-- column cannot be undone without restoring from a backup.
--
-- Apply only when ALL of these are true:
--   1. The owner (Coach Chris) has said yes to dropping the column.
--   2. A fresh backup of the live database has been taken and checked.
--   3. 20261125130000_dashboard_bootstrap_no_primary_trainer.sql is live.
--   4. The app build that no longer reads primary_trainer_id is live, and
--      every edge function has been redeployed from this branch
--      (badge eligibility no longer selects the column).
--   5. The check below finds no database function, view, or policy that
--      still mentions the column. The live database has functions that are
--      not in this repo, so check the live copy, not only the repo.
--
-- To run it, the person applying it has to opt in for that session:
--   set ofm.allow_drop_primary_trainer_id = 'yes';
--   \i supabase/manual/DO_NOT_APPLY_drop_clients_primary_trainer_id.sql
-- Without that setting the script stops before it changes anything.

begin;

do $$
declare
  hits text;
begin
  if coalesce(current_setting('ofm.allow_drop_primary_trainer_id', true), '') <> 'yes' then
    raise exception 'Refusing to drop clients.primary_trainer_id: owner okay and backup not confirmed (set ofm.allow_drop_primary_trainer_id = ''yes'' first).';
  end if;

  -- Anything left in the database that still names the column.
  select string_agg(x, ', ')
    into hits
  from (
    select 'function ' || p.proname as x
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind in ('f', 'p')
      and pg_get_functiondef(p.oid) ilike '%primary_trainer_id%'
    union all
    select 'policy ' || pol.polname
    from pg_policy pol
    where pg_get_expr(pol.polqual, pol.polrelid) ilike '%primary_trainer_id%'
       or pg_get_expr(pol.polwithcheck, pol.polrelid) ilike '%primary_trainer_id%'
    union all
    select 'view ' || v.viewname
    from pg_views v
    where v.schemaname = 'public'
      and v.definition ilike '%primary_trainer_id%'
  ) refs;

  if hits is not null then
    raise exception 'Still referenced by: %. Update these first.', hits;
  end if;
end;
$$;

alter table public.clients drop column if exists primary_trainer_id;

commit;
