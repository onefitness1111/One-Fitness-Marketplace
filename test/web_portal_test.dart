import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/auth/password_rules.dart";
import "package:onefitness/core/auth/portal_session.dart";
import "package:onefitness/core/auth/recovery_link.dart";
import "package:onefitness/core/auth/web_launch.dart";
import "package:onefitness/core/platform/web_fallback.dart";
import "package:onefitness/core/web/portal_path.dart";
import "package:onefitness/features/client/shell/client_shell_state.dart";
import "package:onefitness/features/trainer/shell/trainer_shell_state.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("the phone reset link is unchanged and the website has its own", () {
    expect(kPasswordResetRedirect, "onefitness://reset-password");
    expect(passwordResetRedirectFor(onWeb: false), kMobilePasswordResetRedirect);
    expect(
      passwordResetRedirectFor(onWeb: true),
      "https://portal.onefitnessworkout.com/reset-password",
    );
    expect(passwordResetRedirectFor(onWeb: true), isNot(contains("onefitness://")));
    expect(passwordResetSentMessage(onWeb: false), contains("this phone"));
    expect(passwordResetSentMessage(onWeb: true), contains("this browser"));
  });

  test("the website keeps the Supabase session and refreshes it", () {
    expect(PortalSessionPolicy.persistSession, isTrue);
    expect(PortalSessionPolicy.autoRefreshToken, isTrue);
  });

  test("a reset link is recognised and a Stripe return is not", () {
    final pkce = Uri.parse("https://portal.onefitnessworkout.com/reset-password?code=abc");
    expect(planWebLaunch(pkce).kind, WebLaunchKind.setPassword);

    final hash = Uri.parse(
      "https://portal.onefitnessworkout.com/reset-password#access_token=a&refresh_token=b&type=recovery",
    );
    expect(planWebLaunch(hash).kind, WebLaunchKind.setPassword);

    final tokenHash = Uri.parse(
      "https://portal.onefitnessworkout.com/reset-password?token_hash=hash&type=recovery",
    );
    expect(planWebLaunch(tokenHash).kind, WebLaunchKind.setPassword);
    expect(RecoveryLink.parse(tokenHash)!.tokenHash, "hash");

    final expired = Uri.parse(
      "https://portal.onefitnessworkout.com/reset-password?error=access_denied&error_description=Email+link+is+invalid+or+has+expired",
    );
    final expiredPlan = planWebLaunch(expired);
    expect(expiredPlan.kind, WebLaunchKind.error);
    expect(expiredPlan.message, contains("Request a new one"));
    expect(expiredPlan.message, isNot(contains("+")));

    final stripe = Uri.parse("https://portal.onefitnessworkout.com/?stripe=success");
    expect(planWebLaunch(stripe).kind, WebLaunchKind.none);

    final stray = Uri.parse("https://portal.onefitnessworkout.com/?error=access_denied");
    expect(planWebLaunch(stray).kind, WebLaunchKind.none);
  });

  test("login, profile, and home addresses follow who is signed in", () {
    expect(PortalPath.normalize("/login/"), "/login");
    expect(PortalPath.normalize("/profile?from=email"), "/profile");
    expect(PortalPath.normalize("reset-password"), "/reset-password");
    expect(PortalPath.isProfile("/profile/"), isTrue);

    expect(
      portalAddress(
        settingPassword: false,
        clientSignedIn: false,
        staffSignedIn: false,
        clientScreen: "dashboard",
        trainerMode: "dashboard",
      ),
      "/login",
    );
    expect(
      portalAddress(
        settingPassword: true,
        clientSignedIn: false,
        staffSignedIn: false,
        clientScreen: "dashboard",
        trainerMode: "dashboard",
      ),
      "/reset-password",
    );
    expect(
      portalAddress(
        settingPassword: false,
        clientSignedIn: true,
        staffSignedIn: false,
        clientScreen: "settings",
        trainerMode: "dashboard",
      ),
      "/profile",
    );
    expect(
      portalAddress(
        settingPassword: false,
        clientSignedIn: false,
        staffSignedIn: true,
        clientScreen: "dashboard",
        trainerMode: "myprofile",
      ),
      "/profile",
    );
    expect(
      portalAddress(
        settingPassword: false,
        clientSignedIn: true,
        staffSignedIn: false,
        clientScreen: "dashboard",
        trainerMode: "dashboard",
      ),
      "/",
    );
    expect(kAvailableInMobileApp, "Available in the mobile app.");
  });

  test("opening profile from a link does not leave a back stack", () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final client = container.read(clientScreenProvider.notifier);
    client.go("plans");
    expect(client.canGoBack, isTrue);
    client.openFresh("settings");
    expect(container.read(clientScreenProvider), "settings");
    expect(client.canGoBack, isFalse);

    final staff = container.read(trainerModeProvider.notifier);
    staff.go("clients");
    expect(staff.canGoBack, isTrue);
    staff.openFresh("myprofile");
    expect(container.read(trainerModeProvider), "myprofile");
    expect(staff.canGoBack, isFalse);
  });
}
