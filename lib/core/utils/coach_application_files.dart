/// Apply now uploads. One dropdown, then a file. A before-and-after choice
/// saves two photos as one pair and counts as two files.
const applicationFileCap = 20;
const locationPhotoCap = 8;

/// Dropdown order. The checklist above the button uses the same order.
const applicationTypeOptions = <(String, String)>[
  ("certification", "Certification"),
  ("cpr", "CPR"),
  ("degree", "Degree"),
  ("location-approval", "Location approval notice / Owner permission"),
  ("insurance", "Insurance"),
  ("before-after", "Before and after photo"),
  ("location-photo", "Location photo (max 8)"),
];

const credentialFileKinds = {"certification", "cpr", "degree"};

String applicationTypeLabel(String kind) {
  for (final option in applicationTypeOptions) {
    if (option.$1 == kind) return option.$2;
  }
  return "File";
}

int applicationFilesFor(String kind) => kind == "before-after" ? 2 : 1;

/// Why this type cannot be added, or null when it fits.
String? applicationAddError({
  required String kind,
  required int filesSoFar,
  required int locationPhotos,
}) {
  if (kind == "location-photo" && locationPhotos >= locationPhotoCap) {
    return "You can add up to 8 location photos.";
  }
  if (filesSoFar + applicationFilesFor(kind) > applicationFileCap) {
    return "An application can hold up to 20 files.";
  }
  return null;
}

class ApplicationCheck {
  const ApplicationCheck(this.label, this.done);

  final String label;
  final bool done;
}

/// A line is checked once that type has at least one upload.
List<ApplicationCheck> applicationChecks({
  required Iterable<String> kinds,
  required int beforeAfterPairs,
  required int locationPhotos,
}) {
  final have = kinds.toSet();
  return [
    for (final option in applicationTypeOptions)
      ApplicationCheck(
        option.$2,
        switch (option.$1) {
          "before-after" => beforeAfterPairs > 0,
          "location-photo" => locationPhotos > 0,
          _ => have.contains(option.$1),
        },
      ),
  ];
}

/// Null when the application has the files it needs to be sent.
///
/// At least one certification, CPR card, or degree. A location approval
/// notice or owner permission. Proof of insurance. Before-and-after photos
/// and location photos are not required.
String? applicationUploadError(Iterable<String> kinds) {
  final have = kinds.toSet();
  if (!have.any(credentialFileKinds.contains)) {
    return "Add at least one certification, CPR card, or degree.";
  }
  if (!have.contains("location-approval")) {
    return "Add a location approval notice or owner permission.";
  }
  if (!have.contains("insurance")) {
    return "Add proof of insurance.";
  }
  return null;
}

/// One line per type, in dropdown order, so the owner can see which file is which.
List<String> applicationReviewLines({
  required List<({String? kind, String name})> documents,
  required int beforeAfterPairs,
  required int locationPhotoCount,
}) {
  String files(String kind) {
    final names = [
      for (final doc in documents)
        if (doc.kind == kind && doc.name.trim().isNotEmpty) doc.name.trim(),
    ];
    return names.isEmpty ? "Not included" : names.join(", ");
  }

  final pairs = beforeAfterPairs == 0
      ? "Not included"
      : "$beforeAfterPairs pair${beforeAfterPairs == 1 ? "" : "s"}, side by side";
  final locations = locationPhotoCount == 0
      ? "Not included"
      : "$locationPhotoCount of 8";

  return [
    "Certification: ${files("certification")}",
    "CPR: ${files("cpr")}",
    "Degree: ${files("degree")}",
    "Location approval notice / Owner permission: ${files("location-approval")}",
    "Insurance: ${files("insurance")}",
    "Before and after photo: $pairs",
    "Location photo: $locations",
  ];
}
