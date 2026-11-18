import "dart:convert";
import "dart:typed_data";

/// Mirrors one entry in client.photos — an uploaded progress photo, stored
/// as a compressed `data:image/jpeg;base64,...` string directly in
/// client_records.data.photos (no real object storage — same approach the
/// app already uses for profile photos; see photo_picker_utils.dart).
class ProgressPhoto {
  const ProgressPhoto({
    required this.id,
    required this.date,
    required this.img,
    this.coachComment,
    this.coachCommentAt,
    this.addedBy,
  });

  final String id;
  final String date; // ISO yyyy-MM-dd
  /// A `data:image/...` URL for photos saved before private storage, or a
  /// path inside the progress-photos bucket (`<client id>/<id>.jpg`).
  final String img;

  bool get isStoredFile => img.isNotEmpty && !img.startsWith("data:");

  Uint8List? get inlineBytes {
    if (!img.startsWith("data:")) return null;
    final comma = img.indexOf(",");
    if (comma < 0) return null;
    try {
      return base64Decode(img.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  /// A coach's note left on this specific photo (Notifications spec —
  /// "Coach comments on a progress photo"), shown to the client and
  /// emailed once on save. One comment per photo, editable — not a full
  /// thread.
  final String? coachComment;
  final String? coachCommentAt;

  /// The staff member who added this photo, or null when the client added it
  /// themselves — which is every photo taken before coaches could add them.
  ///
  /// Recorded because this is the client's own progress gallery. A photo
  /// they didn't take appearing in it unlabelled would read as one they'd
  /// forgotten taking, and they'd have no way to tell the difference.
  final String? addedBy;

  Uint8List get bytes => inlineBytes ?? Uint8List(0);

  ProgressPhoto copyWith({String? coachComment, String? coachCommentAt}) => ProgressPhoto(
        id: id,
        date: date,
        img: img,
        coachComment: coachComment ?? this.coachComment,
        coachCommentAt: coachCommentAt ?? this.coachCommentAt,
        addedBy: addedBy,
      );
}
