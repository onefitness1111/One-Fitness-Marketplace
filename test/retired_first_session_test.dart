import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/supabase/supabase_service.dart";
import "package:onefitness/core/widgets/badge_earned_modal.dart";
import "package:onefitness/core/widgets/merit_badge_row.dart";
import "package:onefitness/data/models/earned_badge.dart";
import "package:onefitness/data/models/merit_badge_def.dart";

EarnedBadge _row(String key, {String? revokedAt}) => EarnedBadge(
      id: key,
      clientId: "alix",
      badgeKey: key,
      earnedAt: "2026-11-01",
      revokedAt: revokedAt,
    );

void main() {
  test("first session is gone from the catalog and old rows are ignored", () {
    expect(kMeritBadges.map((b) => b.key), isNot(contains("first_session")));
    expect(kMeritBadges.map((b) => b.name), isNot(contains("First Session")));
    expect(meritBadgeByKey("first_session"), isNull);

    final keys = activeMeritBadgeKeys([
      _row("first_session", revokedAt: "2026-11-02"),
      _row("first_session"),
      _row("one_fitness"),
    ], "alix");
    expect(keys, ["one_fitness"]);

    final revoked = _row("first_session", revokedAt: "2026-11-02");
    final listed = kMeritBadges.any((b) => b.key == revoked.badgeKey);
    expect(listed, isFalse);
  });

  test("the app refuses to award or force a retired badge", () async {
    expect(meritBadgeByKey("record_breaker")?.category, "coach");
    await expectLater(
      SupabaseService.awardMeritBadge("alix", "first_session"),
      throwsA(predicate((Object e) => e.toString().contains("no longer awarded"))),
    );
    await expectLater(
      SupabaseService.grantMeritBadge("alix", "first_session", null),
      throwsA(predicate((Object e) => e.toString().contains("no longer awarded"))),
    );
    await expectLater(
      SupabaseService.forceAwardMeritBadge("alix", "first_session", null),
      throwsA(predicate((Object e) => e.toString().contains("no longer awarded"))),
    );
  });

  testWidgets("a retired badge does not celebrate", (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: BadgeEarnedModal(badgeKey: "first_session", onClose: _noop),
    ));
    expect(find.text("MERIT BADGE EARNED!"), findsNothing);
    expect(find.text("First Session"), findsNothing);
  });
}

void _noop() {}
