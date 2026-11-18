-- Lets a filled single-session refund be saved as an in-app notice.
-- Not applied to the live database by this change. Run it after
-- 20261119100000_balance_grace_booking.sql.
-- The person who paid, and the client whose card was charged, can each
-- read their own row. No phone number and no address is stored here.

alter table public.client_notices drop constraint if exists client_notices_kind;
alter table public.client_notices
  add constraint client_notices_kind
  check (kind in (
    'package_discount',
    'package_full',
    'package_confirmed',
    'balance_due',
    'session_refund'
  ));
