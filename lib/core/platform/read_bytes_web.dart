import "dart:typed_data";

import "web_fallback.dart";

Future<Uint8List> readLocalBytes(String path) {
  throw UnsupportedError("$kAvailableInMobileApp ($path)");
}
