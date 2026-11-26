# Edge functions copied from the live project

These functions were running on the live Supabase project but had no source in
this repo. They were downloaded read-only on 2026-11-25 (nothing was deployed
or changed live) so the repo holds every function that serves traffic.

`index.ts` in each folder is the live source as downloaded. Later commits on
this branch change some of them; see the commit log. Shared helpers resolve
to this repo's `_shared/` folder, which in a few places is newer than the copy
bundled into the live deployment (noted in the commit messages).

| Function | Live version | verify_jwt |
|---|---|---|
| admin-cancel-membership | 5 | true |
| admin-reset-mfa | 12 | true |
| cancel-membership | 16 | true |
| cancel-session | 12 | true |
| challenge-leaderboard | 4 | true |
| change-billing-anchor | 12 | true |
| check-gym-citizen-expiry | 12 | true |
| create-balance-payment | 3 | true |
| create-client-account | 15 | true |
| create-product-payment | 13 | true |
| deduct-points | 12 | true |
| delete-account | 6 | true |
| delete-coach-account | 13 | true |
| grant-points | 12 | true |
| notify-waitlist-joined | 5 | true |
| offer-waitlist-slot | 16 | true |
| owner-subscription-terms | 3 | true |
| photo-pilot-upload | 4 | true |
| preview-billing-anchor-change | 12 | true |
| redeem-points | 13 | true |
| refund-charge | 13 | true |
| register-device-token | 12 | true |
| respond-waitlist-offer | 15 | true |
| revoke-merit-badge | 12 | true |
| send-booking-confirmation | 5 | true |
| send-scheduled-reminders | 15 | false |
| send-welcome-email | 3 | true |
| sign-waiver | 17 | true |
| sweep-expired-points | 12 | true |
| void-points | 12 | true |
| waitlist-sweep | 12 | false |
| waive-charge | 12 | true |

`photo-pilot-upload` is retired on live (always answers 410) and is kept only
so the repo matches what is deployed.
