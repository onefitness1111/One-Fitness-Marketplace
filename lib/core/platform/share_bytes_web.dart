import "dart:typed_data";

import "package:flutter/widgets.dart" show Rect;
import "package:share_plus/share_plus.dart";

/// Browser download of the same bytes the phone app would share.
Future<ShareResult> shareLocalBytes({
  required String filename,
  required Uint8List bytes,
  required String mimeType,
  String? subject,
  Rect? sharePositionOrigin,
}) {
  return SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(bytes, mimeType: mimeType, name: filename)],
      subject: subject,
      fileNameOverrides: [filename],
    ),
  );
}
