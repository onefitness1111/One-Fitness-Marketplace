import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/auth/password_rules.dart";

void main() {
  test("a new password has to be long enough and match", () {
    expect(passwordChangeError("short", "short"), isNotNull);
    expect(passwordChangeError("longenough", "different"), "Those passwords don't match.");
    expect(passwordChangeError("longenough", "longenough"), isNull);
    expect(kPasswordResetRedirect, "onefitness://reset-password");
  });
}
