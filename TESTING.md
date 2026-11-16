# Testing a branch on your Mac

This is for trying a branch in Xcode. You do not need to edit code.

## One step

1. Open Terminal.
2. Go to the ONE Fitness project folder. If you are not sure where it is, type `cd ` (with the space) and drag the project folder onto the Terminal window, then press Return.
3. Run:

```bash
bash scripts/test_branch.sh the-branch-name
```

Replace `the-branch-name` with the name from the pull request. For this requests batch:

```bash
bash scripts/test_branch.sh cursor/batch2-coach-requests-f93d
```

The first security batch is still on `cursor/phase0-security-4fc9` if you are testing that one instead.

The script downloads that branch, refreshes the app, installs the iOS pieces, and opens `ios/Runner.xcworkspace` in Xcode. Press Play in Xcode to run it on your phone.

## If it stops and says you have unsaved changes

It stopped so it would not throw your work away. Nothing was switched and nothing was deleted. If you do not need those changes, ask for help putting them aside. If you do need them, save them first, then run the script again.

## This branch also needs a database update

The script does not change the live database. The security fixes in this branch do nothing on the phone until the SQL file and the Edge Functions are applied. The pull request has the exact clicks. Do that before you judge the tests below.

## What to try on the phone

Use three accounts: a client, a coach, and the owner.

1. **Coach code.** On the coach sign-up screen, a wrong code should stop you before the form, and it should not show you the real code. A right code should create a coach. Signing up as a client should still make a client.
2. **Private details.** Sign in as a client and open another person. You should not see their email, phone, or payments. Sign in as a coach, open any client: you should see their name, emergency contact, program, and visits, and you should be able to send a password-reset email. You should not see their phone, email, or card. Sign in as the owner: you should see those private details.
3. **Pay.** A coach's My Pay should show only their own pay. The owner should still see every coach's pay and every charge.
4. **Messages.** A coach can still email or text a client from chat. A client can still write in the app, and the coach gets an alert, but the client cannot send the gym's email or texts.
5. **Money powers.** A coach should not see Delete client, Edit balance, Add charge, or Payment details. Purchase for client should charge the plan's price (a coupon is fine) and the client should get a notice. The owner can still edit a balance, add a charge, and delete a client.
6. **Programs.** Only the owner should see the buttons that generate a program. A coach can still approve one that is already there. Finishing a nutrition form as a client should not start a new draft by itself. Those buttons should not say "AI", and a coach should not see a Regenerate button.

## This requests batch

Do the database steps in the pull request first, including the first security file if you have not run that one yet. Then the new file. Then deploy the functions the pull request lists. The phone will not enforce these rules until both are done.

Use a client, a coach, and the owner.

### Client

1. Book a session the way you usually do. If your account has been restricted, booking should stop and tell you to talk to ONE Fitness.
2. If a coach's freeze is approved, you should get a notice that says when it starts. It should not start the moment the coach taps Freeze.
3. When you are added to a session, you should still get the usual "you're booked" notice.

### Coach

1. On coach sign-up, "Apply now" should be under the code. You can still enter a real code and become a coach. Apply now should ask for your name, email, birthday, phone, why you'd be a good coach, an optional 20-second recording, a bio, documents, before-and-after photos, and up to 8 location photos, plus the location checklist. Sending it should not log you in.
2. The Schedule tab should show only your sessions and the clients in them. Book session should let you pick any coach's session and add a client there.
3. The Clients tab should list every client, not only people who booked with you.
4. Book one client for free. It should go through. Book a second client for free in the same week. That one should say it was sent to the owner, and should not appear on the schedule yet.
5. Open a client and tap Freeze. It should ask for a from date, a to date, and a reason, then say it was sent. The membership should not say Frozen yet.
6. From the same profile, ask to restrict booking, change the balance, or delete the account. Each one should land on the Requests tab as waiting. Nothing about the client should change yet.
7. My Pay should be in the menu and should show only your pay. A free session you added should not add to that pay.
8. Purchase for a client should let you type a coupon code. It should not show a list of codes.
9. On a client's program, you should not see the word "AI" or a Regenerate button. You can still approve a draft the owner already made.

### Owner

1. You should get a push when a coach sends a request, and an email when someone applies to be a coach.
2. Open Requests from the menu. Applications are at the top. Approve one: the applicant should get an email. If the coach code has not been used, the email includes it. Deny one: they should get a short email and no code.
3. On a waiting request, Approve should do the thing (restrict, balance, delete, or the extra free session). Deny should leave the client as they were. The coach should get a notice either way. The client should get a notice when it affects them.
4. Approve a freeze. It should not freeze them today. The notice should say it starts after 48 hours (or on the from-date, if that is later). You can still freeze someone yourself, straight away, from their profile.
5. Refund a payment in Reports. It should ask for your owner password again. A wrong password should not refund anything.
6. Customize Platform should no longer have switches for "coach can view revenue" or "coach can see other coaches' schedules". The note there says what the app actually does. My Pay stays available for every coach.
