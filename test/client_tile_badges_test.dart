import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/widgets/merit_badge_row.dart";
import "package:onefitness/core/widgets/merit_badge_shield.dart";
import "package:onefitness/data/models/earned_badge.dart";

EarnedBadge _badge(String clientId, String key, {String? revokedAt}) => EarnedBadge(
      id: "$clientId-$key",
      clientId: clientId,
      badgeKey: key,
      earnedAt: "2026-11-01",
      revokedAt: revokedAt,
    );

void main() {
  test("a tile lists only that client's active catalog badges, four then +N", () {
    final badges = [
      _badge("alix", "night_owl"),
      _badge("alix", "one_fitness"),
      _badge("alix", "early_bird"),
      _badge("alix", "daytimer"),
      _badge("alix", "progress_tracker"),
      _badge("alix", "record_breaker", revokedAt: "2026-11-02"),
      _badge("alix", "gym_citizen_rerack"),
      _badge("art", "squad"),
    ];

    final keys = activeMeritBadgeKeys(badges, "alix");
    expect(keys, ["one_fitness", "early_bird", "daytimer", "night_owl", "progress_tracker"]);

    final window = tileBadgeWindow(keys);
    expect(window.shown, ["one_fitness", "early_bird", "daytimer", "night_owl"]);
    expect(window.extra, 1);

    expect(activeMeritBadgeKeys(badges, "nobody"), isEmpty);
    expect(tileBadgeWindow(const []).extra, 0);
  });

  testWidgets("the tile paints four shields and +1, or a blank line", (tester) async {
    final badges = [
      _badge("alix", "one_fitness"),
      _badge("alix", "early_bird"),
      _badge("alix", "daytimer"),
      _badge("alix", "night_owl"),
      _badge("alix", "squad"),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 114,
          child: ClientTileBadges(clientId: "alix", earnedBadges: badges),
        ),
      ),
    ));
    expect(find.byType(MeritBadgeShield), findsNWidgets(4));
    expect(find.text("+1"), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const MaterialApp(
      home: Center(child: ClientTileBadges(clientId: "alix", earnedBadges: [])),
    ));
    expect(find.byType(MeritBadgeShield), findsNothing);
    expect(find.textContaining("+"), findsNothing);
  });

  testWidgets("badges fit on one line inside a client tile", (tester) async {
    final badges = [
      for (final key in ["one_fitness", "early_bird", "daytimer", "night_owl", "squad", "habit"])
        _badge("alix", key),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 180,
          height: 78,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
            child: Row(
              children: [
                const SizedBox(width: 32, height: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        "Alix Fischer",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                      const SizedBox(height: 3),
                      ClientTileBadges(clientId: "alix", earnedBadges: badges),
                      const SizedBox(height: 2),
                      const Text(
                        "alix@exam…com",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text("+2"), findsOneWidget);
    expect(find.text("Alix Fischer"), findsOneWidget);
  });
}
