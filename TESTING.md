# Testing a branch on your Mac

This is for trying a branch in Xcode. You do not need to edit code.

## One step

1. Open Terminal.
2. Go to the ONE Fitness project folder. If you are not sure where it is, type `cd ` (with the space) and drag the project folder onto the Terminal window, then press Return.
3. Run:

```bash
bash scripts/test_branch.sh the-branch-name
```

Replace `the-branch-name` with the name from the pull request. For this security batch:

```bash
bash scripts/test_branch.sh cursor/phase0-security-4fc9
```

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
6. **Programs.** Only the owner should see the buttons that generate a program. A coach can still approve one that is already there. Finishing a nutrition form as a client should not start a new draft by itself.
