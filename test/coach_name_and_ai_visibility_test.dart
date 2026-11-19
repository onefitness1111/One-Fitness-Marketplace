import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/ai_visibility.dart";
import "package:onefitness/core/utils/coach_names.dart";
import "package:onefitness/data/models/trainer.dart";

void main() {
  test("clients see the coach name, never the legal name", () {
    expect(coachPublicName(coachName: "Coach Chris"), "Coach Chris");
    expect(coachPublicName(), "your coach");
    final unnamed = Trainer(id: "u", name: "Chris McCarthy", firstName: "Chris", lastName: "McCarthy");
    expect(unnamed.displayTitle, "your coach");
    final coach = Trainer(
      id: "t",
      name: "Chris McCarthy",
      firstName: "Chris",
      lastName: "McCarthy",
      coachName: "Coach Chris",
      secondaryCoachName: "Chris M",
    );
    expect(coach.displayTitle, "Coach Chris");
    expect(exposesLegalCoachName(shown: coach.displayTitle, legalName: coach.name, coachName: coach.coachName), isFalse);
    expect(exposesLegalCoachName(shown: "Chris McCarthy", legalName: coach.name, coachName: coach.coachName), isTrue);
    expect(exposesLegalCoachName(shown: "Chris McCarthy Coach Chris", legalName: coach.name, coachName: coach.coachName), isTrue);
    expect(prefixMessage("Coach Chris", "see you at 6"), "Coach Chris: see you at 6");
    expect(prefixMessage("Coach Chris", "Coach Chris: see you at 6"), "Coach Chris: see you at 6");
    expect(prefixMessage("ONE Fitness Marketplace", "We're open"), "ONE Fitness Marketplace: We're open");
  });

  test("only the owner sees the word AI", () {
    expect(ownerSeesAi("owner"), isTrue);
    expect(ownerSeesAi("coach"), isFalse);
    expect(ownerSeesAi("client"), isFalse);
    expect(ownerSeesAi(null), isFalse);
    expect(attributionForRole("AI (draft)", isOwner: false), "");
    expect(attributionForRole("AI (draft)", isOwner: true), "AI (draft)");
    expect(attributionForRole("Coach Chris", isOwner: false), "Coach Chris");
    expect(
      ownerOnlyAiText("This is what the AI program drafter reads.", isOwner: false),
      "",
    );
    expect(
      ownerOnlyAiText("This is what the AI program drafter reads.", isOwner: true),
      contains("AI"),
    );
  });
}
