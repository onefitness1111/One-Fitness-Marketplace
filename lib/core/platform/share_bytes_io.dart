import "dart:io";
import "dart:typed_data";

import "package:flutter/widgets.dart" show Rect;
import "package:path_provider/path_provider.dart";
import "package:share_plus/share_plus.dart";

/// Writes a temp file and opens the phone share sheet. Same path the
/// download buttons used before the web build needed a second version.
Future<ShareResult> shareLocalBytes({
  required String filename,
  required Uint8List bytes,
  required String mimeType,
  String? subject,
  Rect? sharePositionOrigin,
}) async {
  final dir = await getTemporaryDirectory();
  final file = File("${dir.path}/$filename");
  await file.writeAsBytes(bytes);
  return SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: mimeType)],
      subject: subject,
      sharePositionOrigin: sharePositionOrigin,
    ),
  );
}
