-- Owner-only "Change role": switch a person between Client and Coach.
--
-- Until now a role was set once, when the account was made: a sign-up is a
-- client, and a coach is made by an approval code (grant_coach_with_code) or
-- by the owner's "+ Trainer" (owner_promote_coach). Neither can undo it or
-- move a client with history over to coach. This adds one function for
-- that, set_user_role(p_user, p_role), that only the owner can call.
--
-- Roles in this database are 'owner', 'coach' and 'client'
-- (profiles_role_check). 'trainer' is accepted as another spelling of
-- 'coach' because the app calls the table `trainers`.
--
-- What it does
--   * Refuses anyone who is not the signed-in owner (also anon and the
--     service role: it needs a real signed-in owner).
--   * Only Client or Coach can be the new role. Owner is never offered,
--     the owner's own account cannot be changed, and no other owner
--     account can be changed either.
--   * Updates profiles.role. The existing triggers still run:
--     prevent_role_escalation lets the owner through, and
--     enforce_profile_phone still refuses a phone number that would clash
--     with the same rules sign-up uses.
--   * To Coach: makes sure a trainers row exists (reviewed_by_owner = true,
--     like the owner's "+ Trainer"). An old trainers row from an earlier
--     time as a coach is reused as it is.
--   * To Client: makes sure a clients row and client_records row exist
--     (ensure_client_row already does the clients row).
--   * Never deletes anything. The old clients row (plan, membership,
--     balance, history) and the old trainers row (sessions, availability,
--     badges) stay. This differs on purpose from owner_promote_coach and
--     grant_coach_with_code, which delete the clients row because those
--     accounts are brand new; deleting it here would cascade and remove
--     client_records, waitlist rows and squads. Nobody is cancelled and no
--     Stripe subscription is touched, so a client with a membership who
--     becomes a coach keeps being billed until the owner cancels it.
--   * The app lists clients only where profiles.role = 'client' and coaches
--     only where profiles.role = 'coach', so the person moves between the
--     Staff page and the client roster without any row being removed.
--   * Writes one row to the owner's activity feed (activity_log: who, the
--     person, old role, new role, time). That table is owner-read-only
--     (activity_log_select uses is_owner()), so no new table or policy.
--   * No coach-client assignment is used: primary_trainer_id is not read
--     or written.
--
-- The person's app reads profiles.role at sign-in and on refresh, so they
-- get the other app the next time they sign in.
--
-- Not applied to live yet. Safe to run more than once. Changes no rows by
-- itself; only the function does, when the owner calls it.

create or replace function public.set_user_role(p_user uuid, p_role text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_caller uuid := auth.uid();
  v_new text := lower(btrim(coalesce(p_role, '')));
  v_old text;
  v_name text;
  v_deleted timestamptz;
  v_upcoming integer := 0;
  v_membership boolean := false;
begin
  if v_caller is null or public.current_user_role() is distinct from 'owner' then
    raise exception 'Only the owner can change someone''s role.';
  end if;

  if v_new = 'trainer' then
    v_new := 'coach';
  end if;
  if v_new not in ('client', 'coach') then
    raise exception 'Pick Client or Coach.';
  end if;

  if p_user is null then
    raise exception 'Missing account.';
  end if;
  if p_user = v_caller then
    raise exception 'The owner''s own role can''t be changed.';
  end if;

  select p.role, p.name, p.deleted_at
    into v_old, v_name, v_deleted
  from public.profiles p
  where p.id = p_user
  for update;

  if not found or v_deleted is not null then
    raise exception 'That account was not found.';
  end if;
  if v_old = 'owner' then
    raise exception 'The owner account can''t be changed.';
  end if;

  if v_old = v_new then
    return jsonb_build_object(
      'changed', false,
      'userId', p_user,
      'oldRole', v_old,
      'newRole', v_new
    );
  end if;

  -- Heads-up numbers for the audit row and the reply. Nothing is cancelled.
  select count(*)::integer
    into v_upcoming
  from public.bookings b
  where b.trainer_id = p_user
    and b.date >= current_date
    and b.cancelled_at is null;

  select exists (
    select 1 from public.clients c
    where c.profile_id = p_user
      and (c.membership_plan_id is not null or c.stripe_subscription_id is not null)
  ) into v_membership;

  update public.profiles set role = v_new where id = p_user;

  if v_new = 'coach' then
    insert into public.trainers (profile_id, reviewed_by_owner, signup_at)
    values (p_user, true, current_date)
    on conflict (profile_id) do nothing;
  else
    insert into public.clients (profile_id)
    values (p_user)
    on conflict (profile_id) do nothing;
    insert into public.client_records (profile_id, data)
    values (p_user, '{"program": [], "logs": [], "comms": []}'::jsonb)
    on conflict (profile_id) do nothing;
  end if;

  insert into public.activity_log (actor_id, actor_name, action, entity, entity_id, subject, summary, details)
  values (
    v_caller,
    coalesce((select p.name from public.profiles p where p.id = v_caller), 'Owner'),
    'edited',
    'role',
    p_user::text,
    nullif(btrim(coalesce(v_name, '')), ''),
    'Changed role from ' || v_old || ' to ' || v_new,
    jsonb_build_object(
      'kind', 'role_change',
      'targetId', p_user,
      'oldRole', v_old,
      'newRole', v_new,
      'upcomingSessionsAsCoach', v_upcoming,
      'hadMembership', v_membership
    )
  );

  return jsonb_build_object(
    'changed', true,
    'userId', p_user,
    'oldRole', v_old,
    'newRole', v_new,
    'upcomingSessionsAsCoach', v_upcoming,
    'hadMembership', v_membership
  );
end;
$function$;

revoke all on function public.set_user_role(uuid, text) from public, anon;
grant execute on function public.set_user_role(uuid, text) to authenticated;

notify pgrst, 'reload schema';
