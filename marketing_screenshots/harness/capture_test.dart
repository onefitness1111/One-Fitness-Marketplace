import "dart:convert";
import "dart:io";
import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:onefitness/core/theme/palette_scope.dart";
import "package:onefitness/core/utils/date_utils.dart";
import "package:onefitness/core/utils/merge_token_utils.dart";
import "package:onefitness/data/models/availability_block.dart";
import "package:onefitness/data/models/booking.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_plan.dart";
import "package:onefitness/data/models/client_record.dart";
import "package:onefitness/data/models/intake_schema.dart";
import "package:onefitness/data/models/membership_plan.dart";
import "package:onefitness/data/models/signature.dart";
import "package:onefitness/data/models/trainer.dart";
import "package:onefitness/data/models/waitlist_entry.dart";
import "package:onefitness/data/models/waiver_doc.dart";
import "package:onefitness/data/providers/client_providers.dart";
import "package:onefitness/data/providers/platform_settings_provider.dart";
import "package:onefitness/data/providers/theme_mode_provider.dart";
import "package:onefitness/data/providers/trainer_providers.dart";
import "package:onefitness/features/client/booking/date_strip.dart";
import "package:onefitness/features/client/shell/client_shell.dart";
import "package:onefitness/features/client/shell/client_shell_state.dart";
import "package:onefitness/features/trainer/shell/trainer_shell.dart";

/// Marketing captures of the client booking journey.
///
/// Widget tests normally pass `--use-test-fonts` and `--disable-asset-fonts`,
/// which draw every glyph as an Ahem block. This file loads Roboto (and the
/// Material icon font) with FontLoader, and the Lucide font from the asset
/// bundle. `marketing_screenshots/harness/capture.sh` runs the test with those
/// two engine switches removed so the loaded fonts are actually used.
///
/// Sample people only: client Tina Alvarez, Coach Will, Coach Maya.
/// Nothing here talks to Supabase, Stripe, or Twilio.

const _shotKey = Key("marketing-shot");

const _plan = MembershipPlan(
  id: "semiprivate-membership",
  name: "Semi-Private Membership",
  kind: PlanKind.membership,
  maxSessions: 12,
  allowedTypes: ["semi-private"],
  priceCents: 22900,
);

const _waiverBody = "Welcome to ONE Fitness. Please read this before your first session with a coach.\n\n"
    "Training is physical. Tell your coach about any injury or limit, follow their instructions, and stop if something hurts.\n\n"
    "Initial each section below, then sign. You need this on file before a session can be booked.";

const _waiver = WaiverDoc(
  id: "signup-waiver",
  title: "General Liability Waiver",
  body: _waiverBody,
);

final _signedWaiver = SignedDocument(
  id: "sig-tina",
  docId: _waiver.id,
  title: _waiver.title,
  signedAt: "2026-11-01T18:00:00.000Z",
  documentVersionHash: documentVersionHash(_waiverBody),
);

final _tina = ClientInfo(
  id: "tina",
  name: "Tina Alvarez",
  email: "tina@example.com",
  phone: "18185550119",
  city: "North Hollywood",
  state: "CA",
  homeLat: 34.172,
  homeLng: -118.376,
  birthday: "1992-03-14",
  membershipPlanId: "semiprivate-membership",
  primaryTrainerId: "coach-will",
  plans: [
    ClientPlanEnrollment(planId: "semiprivate-membership", status: "active", startDate: "2026-10-01"),
  ],
);

Trainer _coach({
  required String id,
  required String publicName,
  required List<int> slots,
  required String bio,
}) {
  return Trainer(
    id: id,
    name: publicName,
    coachName: publicName,
    phone: "18185550101",
    email: "$id@example.com",
    locationName: "ONE Fitness",
    locationAddress: "11300 Magnolia Blvd, North Hollywood, CA",
    bio: bio,
    availability: [
      AvailabilityBlock(
        sessionType: "semi-private",
        discipline: "personal-training",
        locationName: "ONE Fitness",
        byDay: {for (final day in [1, 2, 3, 4, 5, 6]) day: slots},
      ),
    ],
  );
}

final _will = _coach(
  id: "coach-will",
  publicName: "Coach Will",
  slots: [540, 1020],
  bio: "Strength and conditioning. Will builds programs around the way you actually train.",
);

final _maya = _coach(
  id: "coach-maya",
  publicName: "Coach Maya",
  slots: [540, 1080],
  bio: "Coaching for people who want a plan they can stick to, in a small semi-private group.",
);

Booking _booking({
  required String id,
  required String clientId,
  required String trainerId,
  required String date,
  required int slot,
  String? attendance,
}) {
  return Booking(
    id: id,
    clientId: clientId,
    trainerId: trainerId,
    date: date,
    slot: slot,
    sessionType: "semi-private",
    discipline: "personal-training",
    locationName: "ONE Fitness",
    planId: _plan.id,
    attendanceStatus: attendance,
  );
}

ClientRecord _record({required bool signed, bool intakeDone = true, bool physicalDone = true}) {
  return ClientRecord(
    id: _tina.id,
    tourSeenDashboard: true,
    tourSeenDrawer: true,
    onboardingComplete: true,
    signatures: signed ? [_signedWaiver] : const [],
    intake: {
      "personalTraining": IntakeRecord(completed: intakeDone),
      "nutritional": IntakeRecord(completed: intakeDone),
      "physical": IntakeRecord(completed: physicalDone),
    },
  );
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _iso(DateTime d) => isoDate(_dateOnly(d));

DateTime _addDays(DateTime d, int n) => _dateOnly(d).add(Duration(days: n));

/// First non-Sunday at least [minDays] from today. The gym is closed Sundays.
DateTime _futureDay({int minDays = 2}) {
  var day = _addDays(DateTime.now(), minDays);
  while (day.weekday == DateTime.sunday) {
    day = _addDays(day, 1);
  }
  return day;
}

DateTime _startOfWeek(DateTime day) {
  final sinceSunday = day.weekday % 7;
  return _addDays(day, -sinceSunday);
}

/// Another bookable day on the same week strip, or the following Monday.
DateTime _anotherDay(DateTime day) {
  final today = _dateOnly(DateTime.now());
  final start = _startOfWeek(day);
  for (var i = 0; i < 7; i++) {
    final candidate = _addDays(start, i);
    if (candidate == day || candidate.weekday == DateTime.sunday) continue;
    if (!candidate.isAfter(today)) continue;
    return candidate;
  }
  var next = _addDays(day, 1);
  while (next.weekday == DateTime.sunday) {
    next = _addDays(next, 1);
  }
  return next;
}

/// A slot later today, so the dashboard can offer check-in. -1 if the day is over.
int _laterTodaySlot() {
  final now = DateTime.now();
  final minutes = now.hour * 60 + now.minute;
  final slot = ((minutes + 50) ~/ 15) * 15;
  if (slot <= minutes || slot >= 24 * 60) return -1;
  return slot;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await _loadMarketingFonts();
  });

  setUp(() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.exceptionAsString();
      if (text.contains("overflowed")) {
        // ignore: avoid_print
        print("OVERFLOW: $text");
        return;
      }
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  });

  testWidgets("browse coaches and pick a future day", (tester) async {
    final day = _futureDay();
    final other = _anotherDay(day);
    await _open(
      tester,
      mode: ThemeMode.light,
      bookingDate: _iso(day),
      record: _record(signed: true),
      mine: [
        _booking(
          id: "past-tina",
          clientId: _tina.id,
          trainerId: _will.id,
          date: _iso(_addDays(DateTime.now(), -10)),
          slot: 540,
          attendance: "checked-in",
        ),
      ],
      others: [
        _booking(id: "other-1", clientId: "jordan", trainerId: _will.id, date: _iso(day), slot: 540),
      ],
    );
    expect(find.text("Coach Will"), findsWidgets);
    expect(find.text("Coach Maya"), findsWidgets);
    await _shoot(tester, "01_browse_coaches");

    await _selectDay(tester, other);
    expect(find.text(dayLabel(_iso(other))), findsWidgets);
    await _shoot(tester, "02_pick_day_time");
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("waiver is required before the first booking", (tester) async {
    final day = _futureDay();
    await _open(
      tester,
      mode: ThemeMode.light,
      bookingDate: _iso(day),
      record: _record(signed: false),
      mine: [
        _booking(
          id: "past-tina",
          clientId: _tina.id,
          trainerId: _will.id,
          date: _iso(_addDays(DateTime.now(), -10)),
          slot: 540,
          attendance: "checked-in",
        ),
      ],
    );
    await _tapCoach(tester, "Coach Maya");
    expect(find.text("Signature needed"), findsOneWidget);
    await _shoot(tester, "03_signature_needed");
    await tester.tap(find.text("Sign now"));
    await _settle(tester);
    expect(find.text("General Liability Waiver"), findsWidgets);
    expect(find.text("Read the document"), findsOneWidget);
    await _shoot(tester, "03b_waiver_signing");
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("free first session offer", (tester) async {
    await _open(
      tester,
      mode: ThemeMode.light,
      bookingDate: _iso(_futureDay()),
      record: _record(signed: true, physicalDone: false),
      mine: const [],
    );
    expect(find.text("Your first session is free"), findsOneWidget);
    expect(find.text("Book my free session"), findsOneWidget);
    await _shoot(tester, "03c_free_first_session");
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("confirm booking", (tester) async {
    await _open(
      tester,
      mode: ThemeMode.light,
      bookingDate: _iso(_futureDay()),
      record: _record(signed: true),
      mine: [
        _booking(
          id: "past-tina",
          clientId: _tina.id,
          trainerId: _will.id,
          date: _iso(_addDays(DateTime.now(), -10)),
          slot: 540,
          attendance: "checked-in",
        ),
      ],
    );
    await _tapCoach(tester, "Coach Maya");
    expect(find.text("Confirm booking"), findsOneWidget);
    expect(find.text("Coach Maya"), findsWidgets);
    await _shoot(tester, "04_confirm_booking");
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("upcoming schedule shows the booked session", (tester) async {
    final soon = _futureDay(minDays: 1);
    final later = _futureDay(minDays: 4);
    await _open(
      tester,
      mode: ThemeMode.light,
      goBooking: false,
      record: _record(signed: true),
      mine: [
        _booking(id: "up-1", clientId: _tina.id, trainerId: _will.id, date: _iso(soon), slot: 540),
        _booking(id: "up-2", clientId: _tina.id, trainerId: _maya.id, date: _iso(later), slot: 1080),
      ],
    );
    await tester.ensureVisible(find.text("NEXT SESSION"));
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, 120));
    await _settle(tester);
    expect(find.text("NEXT SESSION"), findsOneWidget);
    expect(find.textContaining("ONE Fitness"), findsWidgets);
    await _shoot(tester, "05_upcoming_schedule");
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("full session offers the waitlist", (tester) async {
    final day = _futureDay();
    final date = _iso(day);
    await _open(
      tester,
      mode: ThemeMode.light,
      bookingDate: date,
      record: _record(signed: true),
      mine: [
        _booking(
          id: "past-tina",
          clientId: _tina.id,
          trainerId: _will.id,
          date: _iso(_addDays(DateTime.now(), -10)),
          slot: 540,
          attendance: "checked-in",
        ),
      ],
      others: [
        for (var i = 0; i < 4; i++)
          _booking(id: "full-$i", clientId: "guest-$i", trainerId: _will.id, date: date, slot: 540),
        for (var i = 0; i < 4; i++)
          _booking(id: "eve-$i", clientId: "guest-e$i", trainerId: _maya.id, date: date, slot: 1080),
      ],
      waitlist: [
        WaitlistEntry(
          id: "wl-tina",
          clientId: _tina.id,
          clientName: _tina.name,
          trainerId: _maya.id,
          trainerName: _maya.displayTitle,
          date: date,
          slot: 1080,
          sessionType: "semi-private",
          discipline: "personal-training",
          status: "waiting",
          position: 1,
        ),
      ],
    );
    expect(find.text("+ Join waitlist"), findsOneWidget);
    await tester.ensureVisible(find.text("+ Join waitlist"));
    await _shoot(tester, "06_waitlist");
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("check in on session day", (tester) async {
    final slot = _laterTodaySlot();
    expect(slot, greaterThan(0), reason: "Need a slot later today to show check-in. Now is ${DateTime.now()}.");
    await _open(
      tester,
      mode: ThemeMode.light,
      goBooking: false,
      record: _record(signed: true),
      mine: [
        _booking(id: "today", clientId: _tina.id, trainerId: _will.id, date: isoToday(), slot: slot),
      ],
    );
    final button = find.textContaining("start my session");
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await _shoot(tester, "07_check_in");
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("book the same time next week", (tester) async {
    final yesterday = _addDays(DateTime.now(), -1);
    final sessionDay = yesterday.weekday == DateTime.sunday ? _addDays(yesterday, -1) : yesterday;
    await _open(
      tester,
      mode: ThemeMode.light,
      goBooking: false,
      record: _record(signed: true),
      mine: [
        _booking(
          id: "ended",
          clientId: _tina.id,
          trainerId: _will.id,
          date: _iso(sessionDay),
          slot: 540,
          attendance: "checked-in",
        ),
      ],
    );
    expect(find.text("Book the same time next week"), findsOneWidget);
    expect(find.textContaining("Coach Will"), findsWidgets);
    await _shoot(tester, "08_rebook_next_week");
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("dark mode of the four lead screens", (tester) async {
    final day = _futureDay();
    await _open(
      tester,
      mode: ThemeMode.dark,
      bookingDate: _iso(day),
      record: _record(signed: true),
      mine: [
        _booking(
          id: "past-tina",
          clientId: _tina.id,
          trainerId: _will.id,
          date: _iso(_addDays(DateTime.now(), -10)),
          slot: 540,
          attendance: "checked-in",
        ),
      ],
      others: [
        _booking(id: "other-1", clientId: "jordan", trainerId: _will.id, date: _iso(day), slot: 540),
      ],
    );
    await _shoot(tester, "01_browse_coaches_dark");
    await _tapCoach(tester, "Coach Maya");
    expect(find.text("Confirm booking"), findsOneWidget);
    await _shoot(tester, "04_confirm_booking_dark");
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("dark mode upcoming schedule", (tester) async {
    final soon = _futureDay(minDays: 1);
    final later = _futureDay(minDays: 4);
    await _open(
      tester,
      mode: ThemeMode.dark,
      goBooking: false,
      record: _record(signed: true),
      mine: [
        _booking(id: "up-1", clientId: _tina.id, trainerId: _will.id, date: _iso(soon), slot: 540),
        _booking(id: "up-2", clientId: _tina.id, trainerId: _maya.id, date: _iso(later), slot: 1080),
      ],
    );
    await tester.ensureVisible(find.text("NEXT SESSION"));
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, 120));
    await _settle(tester);
    await _shoot(tester, "05_upcoming_schedule_dark");
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("coach can change a self check-in", (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool("ofm.staffTour.coach-will.coach-home", true);
    final container = ProviderContainer(
      overrides: [initialThemeModeProvider.overrideWithValue(ThemeMode.light)],
    );
    addTearDown(container.dispose);
    container.read(trainerAuthProvider.notifier).signIn(_will.id);
    container.read(trainersProvider.notifier).setAll([_will, _maya]);
    container.read(trainerRosterProvider.notifier).setAll([_tina]);
    container.read(trainerClientRecordsProvider.notifier).setAll({_tina.id: _record(signed: true)});
    container.read(allBookingsProvider.notifier).setAll([
      Booking(
        id: "tina-self-checkin",
        clientId: _tina.id,
        trainerId: _will.id,
        date: isoToday(),
        slot: 1290,
        sessionType: "semi-private",
        discipline: "personal-training",
        locationName: "ONE Fitness",
        planId: _plan.id,
        attendanceStatus: "checked-in",
        clientStartedAt: "2026-11-18T21:00:00.000Z",
      ),
    ]);
    container.read(membershipPlansProvider.notifier).setAll(const [_plan]);
    container.read(blockedTimesProvider.notifier).setAll(const []);
    container.read(earnedBadgesProvider.notifier).setAll(const []);
    container.read(platformSettingsProvider.notifier).update(
          (s) => s.copyWith(
            businessName: "ONE Fitness Marketplace",
            locationName: "ONE Fitness",
            locationAddress: "11300 Magnolia Blvd, North Hollywood, CA",
          ),
        );

    tester.view.physicalSize = const Size(1290, 2796);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewPadding = FakeViewPadding.zero;
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: PaletteScope(
          builder: (context, theme) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            darkTheme: theme,
            home: const RepaintBoundary(key: _shotKey, child: TrainerShell()),
          ),
        ),
      ),
    );
    await _settle(tester);
    final noShow = find.text("No Show");
    expect(noShow, findsWidgets);
    await tester.ensureVisible(noShow.first);
    expect(find.text("Tina Alvarez"), findsWidgets);
    expect(find.text("Check In"), findsWidgets);
    await _shoot(tester, "09_coach_change_checkin");
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets("dark mode rebook", (tester) async {
    final yesterday = _addDays(DateTime.now(), -1);
    final sessionDay = yesterday.weekday == DateTime.sunday ? _addDays(yesterday, -1) : yesterday;
    await _open(
      tester,
      mode: ThemeMode.dark,
      goBooking: false,
      record: _record(signed: true),
      mine: [
        _booking(
          id: "ended",
          clientId: _tina.id,
          trainerId: _will.id,
          date: _iso(sessionDay),
          slot: 540,
          attendance: "checked-in",
        ),
      ],
    );
    expect(find.text("Book the same time next week"), findsOneWidget);
    await _shoot(tester, "08_rebook_next_week_dark");
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _loadMarketingFonts() async {
  final manifestJson = await rootBundle.loadString("FontManifest.json");
  final families = json.decode(manifestJson) as List<dynamic>;
  for (final raw in families) {
    final family = raw as Map<String, dynamic>;
    final loader = FontLoader(family["family"] as String);
    for (final font in family["fonts"] as List<dynamic>) {
      loader.addFont(rootBundle.load((font as Map<String, dynamic>)["asset"] as String));
    }
    await loader.load();
  }

  final dir = Directory("marketing_screenshots/fonts");
  final roboto = FontLoader("Roboto");
  for (final name in const [
    "Roboto-Light.ttf",
    "Roboto-Regular.ttf",
    "Roboto-Italic.ttf",
    "Roboto-Medium.ttf",
    "Roboto-MediumItalic.ttf",
    "Roboto-Bold.ttf",
    "Roboto-BoldItalic.ttf",
    "Roboto-Black.ttf",
  ]) {
    final bytes = await File("${dir.path}/$name").readAsBytes();
    roboto.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
  }
  await roboto.load();

  final icons = FontLoader("MaterialIcons");
  final iconBytes = await File("${dir.path}/MaterialIcons-Regular.otf").readAsBytes();
  icons.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(iconBytes))));
  await icons.load();
}

Future<void> _settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 8),
    );
  } catch (_) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _open(
  WidgetTester tester, {
  required ThemeMode mode,
  required ClientRecord record,
  required List<Booking> mine,
  List<Booking> others = const [],
  List<WaitlistEntry> waitlist = const [],
  String? bookingDate,
  bool goBooking = true,
}) async {
  final container = ProviderContainer(
    overrides: [initialThemeModeProvider.overrideWithValue(mode)],
  );
  addTearDown(container.dispose);

  container.read(clientInfoProvider.notifier).update((_) => _tina);
  container.read(clientRecordProvider.notifier).update((_) => record);
  container.read(trainersProvider.notifier).setAll([_will, _maya]);
  container.read(membershipPlansProvider.notifier).setAll(const [_plan]);
  container.read(clientBookingsProvider.notifier).setAll(mine);
  container.read(allBookingsProvider.notifier).setAll([...mine, ...others]);
  container.read(waitlistProvider.notifier).setAll(waitlist);
  container.read(blockedTimesProvider.notifier).setAll(const []);
  container.read(earnedBadgesProvider.notifier).setAll(const []);
  container.read(waiversProvider.notifier).setAll(const [_waiver]);
  container.read(platformSettingsProvider.notifier).update(
        (s) => s.copyWith(
          businessName: "ONE Fitness Marketplace",
          locationName: "ONE Fitness",
          locationAddress: "11300 Magnolia Blvd, North Hollywood, CA",
          locationHint: "Second floor, side entrance",
          locationLat: 34.1867,
          locationLng: -118.379,
          bookingCoachScope: "any",
          requireWaiverAtSignup: true,
        ),
      );
  if (bookingDate != null) {
    container.read(pendingBookingTargetProvider.notifier).set(BookingTarget(initialDate: bookingDate));
  }

  tester.view.physicalSize = const Size(1290, 2796);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = FakeViewPadding.zero;
  tester.view.viewPadding = FakeViewPadding.zero;
  tester.view.viewInsets = FakeViewPadding.zero;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: PaletteScope(
        builder: (context, theme) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          darkTheme: theme,
          home: const RepaintBoundary(key: _shotKey, child: ClientShell()),
        ),
      ),
    ),
  );
  await _settle(tester);

  if (find.text("Skip for now").evaluate().isNotEmpty) {
    await tester.tap(find.text("Skip for now"));
    await _settle(tester);
  }
  if (goBooking) {
    container.read(clientScreenProvider.notifier).go("booking");
    await _settle(tester);
  }
}

Future<void> _selectDay(WidgetTester tester, DateTime day) async {
  final label = "${day.day}";
  for (var i = 0; i < 4; i++) {
    final cell = find.descendant(of: find.byType(DateStrip), matching: find.text(label));
    if (cell.evaluate().isNotEmpty) {
      await tester.ensureVisible(cell.first);
      await tester.tap(cell.first);
      await _settle(tester);
      return;
    }
    final next = find.descendant(
      of: find.byType(DateStrip),
      matching: find.byIcon(LucideIcons.chevronRight),
    );
    await tester.tap(next);
    await _settle(tester);
  }
  throw StateError("Date strip never showed day $label");
}

Future<void> _tapCoach(WidgetTester tester, String name) async {
  final coach = find.text(name);
  expect(coach, findsWidgets);
  await tester.ensureVisible(coach.first);
  await tester.tap(coach.first);
  await _settle(tester);
}

Future<void> _shoot(WidgetTester tester, String name) async {
  await _settle(tester);
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
  final captured = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List();
    final file = File("marketing_screenshots/$name.png");
    await file.writeAsBytes(bytes, flush: true);
    return "${image.width}x${image.height} ${bytes.length}";
  });
  // ignore: avoid_print
  print("SHOT $name $captured");
}
