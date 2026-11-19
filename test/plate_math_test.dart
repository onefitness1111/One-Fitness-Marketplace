import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/plate_math.dart";

void main() {
  test("135 is one 45 on each side", () {
    final plan = platesPerSide(135);
    expect(plan.tooLight, isFalse);
    expect(plan.perSide, [45]);
    expect(plan.remainder, 0);
    expect(plan.label, "Per side: 45");
  });

  test("185 is a 45 and a 25 on each side", () {
    expect(platesPerSide(185).perSide, [45, 25]);
  });

  test("the empty bar and a too-light weight stay simple", () {
    expect(platesPerSide(45).label, "Just the 45 lb bar.");
    expect(platesPerSide(25).tooLight, isTrue);
    expect(platesPerSide(25).perSide, isEmpty);
  });

  test("2.5 plates are used, and a leftover is named", () {
    expect(platesPerSide(50).perSide, [2.5]);
    final odd = platesPerSide(47);
    expect(odd.perSide, isEmpty);
    expect(odd.remainder, greaterThan(0));
  });
}
