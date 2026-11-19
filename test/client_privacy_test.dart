import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/payments/billing_address_rules.dart";
import "package:onefitness/core/payments/client_charge.dart";
import "package:onefitness/core/privacy/client_contact_privacy.dart";
import "package:onefitness/data/models/billing_address.dart";

void main() {
  const address = BillingAddress(
    name: "Alex Client",
    line1: "1 Gym St",
    city: "Burbank",
    state: "CA",
    postalCode: "91502",
  );

  test("a coach is denied the phone and the street, and can still write", () {
    final view = clientContactForViewer(
      viewerIsOwner: false,
      viewerIsClient: false,
      phoneOnFile: true,
      billingOnFile: true,
      phone: "8185551212",
      address: address,
    );
    expect(view.phone, isNull);
    expect(view.address, isNull);
    expect(view.phoneOnFile, isTrue);
    expect(onFileLabel(true), "On file");
    expect(onFileLabel(false), "Not on file");

    final after = afterCoachWrite(
      wrotePhone: true,
      wroteAddress: true,
      phoneWasOnFile: false,
      addressWasOnFile: false,
    );
    expect(after.phone, isNull);
    expect(after.address, isNull);
    expect(after.phoneOnFile, isTrue);
    expect(leaksPrivateContact({"phoneOnFile": true, "phone": "8185551212"}), isTrue);
    expect(leaksPrivateContact({"phoneOnFile": true, "billingOnFile": true}), isFalse);
  });

  test("the client and the owner can read what a coach cannot", () {
    final owner = clientContactForViewer(
      viewerIsOwner: true,
      viewerIsClient: false,
      phoneOnFile: true,
      billingOnFile: true,
      phone: "8185551212",
      address: address,
    );
    expect(owner.phone, "8185551212");
    expect(owner.address?.line1, "1 Gym St");
    expect(phoneForViewer(viewerIsOwner: false, viewerIsClient: false, phone: "8185551212"), isNull);
  });

  test("a US billing address needs a real state and a 5 or 9 digit ZIP", () {
    expect(billingAddressError(address), isNull);
    expect(
      billingAddressError(const BillingAddress(name: "A", line1: "1", city: "Burbank", state: "CA", postalCode: "91502-1234")),
      isNull,
    );
    expect(
      billingAddressError(const BillingAddress(name: "A", line1: "1", city: "Burbank", state: "California", postalCode: "91502")),
      isNotNull,
    );
    expect(
      billingAddressError(const BillingAddress(name: "A", line1: "1", city: "Burbank", state: "CA", postalCode: "915")),
      isNotNull,
    );
  });

  test("a coach charges only their own client, and a bad card asks for a new one", () {
    expect(mayChargeClient(senderIsOwner: false, senderId: "chris", primaryTrainerId: "chris"), isTrue);
    expect(mayChargeClient(senderIsOwner: false, senderId: "chris", primaryTrainerId: "pat"), isFalse);
    expect(mayChargeClient(senderIsOwner: true, senderId: "owner", primaryTrainerId: "pat"), isTrue);
    expect(feeCentsFor("late"), 1500);
    expect(feeCentsFor("close"), 2500);
    expect(chargeNeedsNewCard("authentication_required"), isTrue);
    expect(chargeNeedsNewCard("card_declined"), isTrue);
    expect(chargeNeedsBillingAddress(hasCard: true, cardHasAddress: false), isTrue);
    expect(chargeNeedsBillingAddress(hasCard: true, cardHasAddress: true), isFalse);
  });

  test("city and state from an older profile prefill the billing form", () {
    final filled = billingAddressPrefill(city: "Burbank", state: "CA", name: "Alex");
    expect(filled.city, "Burbank");
    expect(filled.state, "CA");
    expect(filled.country, "US");
    expect(filled.line1, isEmpty);
  });
}
