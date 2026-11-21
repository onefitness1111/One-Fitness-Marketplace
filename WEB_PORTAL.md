# ONE Fitness website (client and coach portal)

This is the same app as the iPhone and Android app. People sign in with the same email and password. Clients, coaches, and the owner each land on their own dashboard. The phone app is unchanged.

The site is meant to live at **https://portal.onefitnessworkout.com**, opened from a **Log in** button on the marketing site (onefitnessworkout.com).

Nothing in this change publishes the site, changes the live database, or updates the live password-reset email sender. Those steps are below, and they are yours to do when you are ready.

## What you need before go-live

- The Supabase **publishable** key (also called the anon key). It is already built into the app. Do **not** put the service-role key, the Stripe secret, or the database password in the website. Those stay on the server.
- A free Cloudflare account (the host recommended below).
- Access to GoDaddy DNS for onefitnessworkout.com.
- Access to the Supabase dashboard for project `rivhgutksyddeckieknc`.
- Access to the Webflow site, to point the Log in button at the portal.

## 1. Build the site on your computer

From the project folder:

```bash
flutter build web --release
```

The finished files are in `build/web`. That folder is the whole website. You upload that folder. You do not upload the rest of the project.

Optional, if you ever point the app at a different Supabase project:

```bash
flutter build web --release \
  --dart-define=SUPABASE_URL=https://rivhgutksyddeckieknc.supabase.co \
  --dart-define=SUPABASE_KEY=YOUR_PUBLISHABLE_KEY
```

`YOUR_PUBLISHABLE_KEY` is the publishable/anon key only.

## 2. Host it on Cloudflare Pages

Cloudflare Pages is the right fit: the portal is a folder of static files, Pages gives you free HTTPS, and a subdomain can point at it while the main site stays on Webflow and GoDaddy. Vercel, Netlify, or Firebase Hosting would also work. You do not need more than one.

1. In Cloudflare, create a Pages project and upload the contents of `build/web` (or connect the Git repo and set the build command to `flutter build web --release` and the output directory to `build/web`, if the builder has Flutter installed).
2. The file `_redirects` is already inside `build/web`. It tells the host that `/login`, `/profile`, and `/reset-password` should open the app instead of a "page not found" error. Do not delete it.
3. Add the custom domain `portal.onefitnessworkout.com` in the Pages project. Cloudflare will show you a CNAME target, usually something like `your-project.pages.dev`.

## 3. Point the subdomain in GoDaddy

Do **not** change the nameservers for onefitnessworkout.com. The marketing site on Webflow uses the root domain. Only add a record for the subdomain.

1. GoDaddy → the domain onefitnessworkout.com → DNS.
2. Add a record:
   - Type: **CNAME**
   - Name: **portal**
   - Value: the target Cloudflare shows (for example `your-project.pages.dev`)
   - TTL: default
3. Save. It can take a few minutes, sometimes a couple of hours.
4. In Cloudflare Pages, finish the custom-domain step so the certificate (the padlock) is issued. Wait until it says the domain is active.

Then set the Webflow **Log in** button to:

`https://portal.onefitnessworkout.com/login`

## 4. Supabase settings (required or password reset will be rejected)

Supabase → Authentication → URL Configuration.

**Redirect URLs.** Add these. Leave `onefitness://reset-password` in the list so the phone app's reset emails still open the phone app.

- `https://portal.onefitnessworkout.com/reset-password`
- `https://portal.onefitnessworkout.com/login`
- `https://portal.onefitnessworkout.com/`

The reset address has to match exactly, including `https` and with no slash at the end of `reset-password`.

**Site URL.** Set this to `https://portal.onefitnessworkout.com` if it is still a placeholder such as localhost. If it is already a live address you know the phone app depends on, leave Site URL as it is and only add the redirect URLs above. Password reset from the app and the website sends its own redirect, so it does not rely on Site URL.

For a practice run on your own computer, also add the exact address Flutter prints, for example `http://localhost:5000/reset-password`. The port changes. That entry is not needed for the live site.

## 5. How sign-in behaves

- Same email and password as the phone app.
- A client opens the client dashboard. A coach opens the coach dashboard. The owner opens the owner dashboard (the staff side).
- The browser remembers the session. Closing the tab or refreshing does not sign them out. The session is refreshed in the background before it expires. **Sign out** clears it.
- `/login` is the sign-in page. `/profile` opens Profile Settings for a client, or My Profile for a coach or the owner. Refreshing those addresses stays on the same page.
- On a desktop or tablet browser the pages use the full window, with a menu down the left side. A phone browser keeps the same bottom tabs as the app.
- Forgot password on the website emails a link that returns to `https://portal.onefitnessworkout.com/reset-password`. Open that link in the **same browser** you used to request it. Then choose a new password. The phone app's own Forgot password still opens the phone app.
- A reset sent by a coach or the owner from inside the app still opens the **phone** until you choose to deploy the updated `send-password-reset` function (see below). This project does not deploy that function.

Coach legal names, phone numbers, and email addresses are still left off anything a client is allowed to see. That did not change.

## 6. Optional later: resets sent by staff from the website

The file `supabase/functions/send-password-reset/index.ts` can send the website link when the request comes from the website, and it still sends the phone link otherwise. It is **not** deployed by this work. The live function is untouched.

When you want a reset that a coach sends while using the website to open the website, deploy that one function yourself:

```bash
supabase functions deploy send-password-reset --project-ref rivhgutksyddeckieknc
```

Until then, Forgot password on the sign-in page already uses the website link.

## What stays on the phone

These show the words **Available in the mobile app** (or the control is simply not offered) because the phone operating system provides them and a browser does not:

- Apple Health, Health Connect, Apple Watch, and other wearables
- Push alerts (the website does not pop up notifications; the preference saved in the phone app is left as it is)
- Card payments, adding a card, and Apple Pay (Stripe's in-app payment sheet)
- Taking a photo with the camera (choosing an existing photo from the computer still works)
- The optional spoken clip on a coach application
- A file that only exists as a path on the phone

CSV and PDF downloads, and sharing a progress card, download in the browser instead of opening the phone share sheet.

Calendar subscribe, chat, booking, profiles, and the dashboards use the same Supabase account and the same privacy rules as the phone.
