import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/data/cache/bootstrap_cache.dart";
import "package:onefitness/data/providers/dashboard_load.dart";

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test("the dashboard booking window is today, two weeks back, and two weeks ahead", () {
    final window = dashboardBookingWindow(DateTime(2026, 11, 21));
    expect(window.from, isoDate(DateTime(2026, 11, 7)));
    expect(window.to, isoDate(DateTime(2026, 12, 5)));
    expect(dashboardBookingLookbackDays, 14);
    expect(dashboardBookingLookaheadDays, 14);
  });

  test("clients and coaches paint before the full gym download; the owner does not", () {
    expect(shellBeforeFullGymDownload("client"), isTrue);
    expect(shellBeforeFullGymDownload("coach"), isTrue);
    expect(shellBeforeFullGymDownload("owner"), isFalse);
    expect(shellBeforeFullGymDownload(null), isFalse);
  });

  test("the coach's first record read leaves workout logs out", () {
    expect(coachDashboardRecordColumns.contains("workoutLogs"), isFalse);
    expect(coachDashboardRecordColumns.contains("programDays"), isFalse);
    expect(coachDashboardRecordColumns.contains("savedPrograms"), isTrue);
    expect(coachDashboardRecordColumns.contains("nutrition"), isTrue);
    expect(fullDashboardRecordColumns.contains("workoutLogs"), isTrue);
    expect(bookingSelectColumns.contains("client_id"), isTrue);
    expect(bookingSelectColumns.contains("*"), isFalse);
  });

  test("opening chat or the shop does not happen during the dashboard read", () {
    expect(sectionsForClientScreen("dashboard"), {GymSection.badges});
    expect(sectionsForClientScreen("chat"), {GymSection.messages});
    expect(sectionsForClientScreen("shop"), {GymSection.products});
    expect(sectionsForClientScreen("history"), {GymSection.bookingsRest});
    expect(sectionsForStaffScreen("dashboard"), isEmpty);
    expect(sectionsForStaffScreen("schedule"), contains(GymSection.bookingsRest));
    expect(sectionsForStaffScreen("schedule"), contains(GymSection.blocked));
    expect(sectionsForStaffScreen("chat"), {GymSection.messages});
  });

  test("sign-out keeps this user's snapshot and the next account cannot read it", () async {
    await BootstrapCache.write("user-a", {"hello": "a"});
    expect((await BootstrapCache.read("user-a"))?["hello"], "a");

    await BootstrapCache.activate("user-b");
    expect(await BootstrapCache.read("user-a"), isNull);
    expect(await BootstrapCache.read("user-b"), isNull);

    await BootstrapCache.write("user-b", {"hello": "b"});
    await BootstrapCache.activate("user-b");
    expect((await BootstrapCache.read("user-b"))?["hello"], "b");
  });
}
