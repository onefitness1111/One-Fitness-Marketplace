-- Lock down the freeze lookups added in 20261125120000.
--
-- client_frozen_until and client_plan_hold take any client id, so any
-- signed-in account could read another client's freeze dates and held
-- session count through /rest/v1/rpc. Nothing in the app or the edge
-- functions calls them directly. They are only called from inside other
-- SECURITY DEFINER functions owned by postgres (block_frozen_client_booking,
-- client_plan_allowance, sessions_toward_booking_limit), which run with the
-- owner's rights and do not need these grants.
--
-- So direct calls are closed to everyone except service_role. A client
-- still sees their own freeze on their clients row, and the owner and
-- coaches still see it on the client's profile, the same as before.
-- No caller check inside the functions: they cannot be reached directly
-- any more, and a check there would also run on the internal calls made
-- while someone else's booking is saved. No coach-client assignment is
-- involved anywhere.
--
-- block_frozen_client_booking only runs as a trigger. Postgres does not
-- check EXECUTE when a trigger fires, so revoking it changes nothing for
-- bookings and only closes the direct /rpc path.
--
-- Safe to run more than once. Does not change any rows.

revoke all on function public.client_frozen_until(uuid, date) from public, anon, authenticated;
grant execute on function public.client_frozen_until(uuid, date) to service_role;

revoke all on function public.client_plan_hold(uuid, text) from public, anon, authenticated;
grant execute on function public.client_plan_hold(uuid, text) to service_role;

revoke all on function public.block_frozen_client_booking() from public, anon, authenticated;

notify pgrst, 'reload schema';
