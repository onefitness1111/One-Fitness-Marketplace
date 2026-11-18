import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/coach_application_files.dart";

void main() {
  test("the checklist follows the dropdown, in order", () {
    final labels = applicationTypeOptions.map((option) => option.$2).toList();
    expect(labels, [
      "Certification",
      "CPR",
      "Degree",
      "Location approval notice / Owner permission",
      "Insurance",
      "Before and after photo",
      "Location photo (max 8)",
    ]);
    final checks = applicationChecks(
      kinds: const ["cpr", "location-approval", "insurance"],
      beforeAfterPairs: 1,
      locationPhotos: 0,
    );
    expect(checks.map((line) => line.label), labels);
    expect(checks.map((line) => line.done), [false, true, false, true, true, true, false]);
  });

  test("a credential, the approval file, and insurance are enough to send", () {
    expect(applicationUploadError(["degree", "location-approval", "insurance"]), isNull);
    expect(applicationUploadError(["certification", "location-approval", "insurance"]), isNull);
  });

  test("before-and-after photos and location photos are not required", () {
    expect(applicationUploadError(["cpr", "location-approval", "insurance"]), isNull);
  });

  test("each required group blocks the application on its own", () {
    expect(
      applicationUploadError(["location-approval", "insurance"]),
      "Add at least one certification, CPR card, or degree.",
    );
    expect(
      applicationUploadError(["certification", "insurance"]),
      "Add a location approval notice or owner permission.",
    );
    expect(
      applicationUploadError(["certification", "location-approval"]),
      "Add proof of insurance.",
    );
  });

  test("a before-and-after pair counts as two files, and the cap is 20", () {
    expect(applicationFilesFor("before-after"), 2);
    expect(applicationFilesFor("certification"), 1);
    expect(applicationAddError(kind: "before-after", filesSoFar: 18, locationPhotos: 0), isNull);
    expect(
      applicationAddError(kind: "before-after", filesSoFar: 19, locationPhotos: 0),
      "An application can hold up to 20 files.",
    );
    expect(
      applicationAddError(kind: "location-photo", filesSoFar: 8, locationPhotos: 8),
      "You can add up to 8 location photos.",
    );
    expect(applicationFileCap, greaterThanOrEqualTo(17));
    expect(applicationFileCap, 20);
  });

  test("the owner sees every type, and a pair is described side by side", () {
    expect(
      applicationReviewLines(
        documents: const [
          (kind: "cpr", name: "cpr-card.pdf"),
          (kind: "location-approval", name: "notice.pdf"),
          (kind: "insurance", name: "policy.pdf"),
        ],
        beforeAfterPairs: 1,
        locationPhotoCount: 2,
      ),
      [
        "Certification: Not included",
        "CPR: cpr-card.pdf",
        "Degree: Not included",
        "Location approval notice / Owner permission: notice.pdf",
        "Insurance: policy.pdf",
        "Before and after photo: 1 pair, side by side",
        "Location photo: 2 of 8",
      ],
    );
  });
}
