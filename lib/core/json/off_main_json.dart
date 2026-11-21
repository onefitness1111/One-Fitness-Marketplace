import "dart:convert";

import "package:flutter/foundation.dart";

/// JSON this size and up is decoded on a background isolate.
///
/// Smaller payloads stay on the caller. Spinning up an isolate costs more
/// than parsing a few kilobytes, and the sign-in gaps were the big bodies
/// (the profile directory and client record blobs), not these.
const offMainJsonBytes = 12 * 1024;

dynamic _decode(String source) => jsonDecode(source);

String _encode(Object? value) => jsonEncode(value);

Future<dynamic> decodeJsonOffMain(String source) {
  if (source.length < offMainJsonBytes) return Future<dynamic>.value(jsonDecode(source));
  return compute(_decode, source);
}

/// Encodes [value] away from the UI isolate when it is large enough to hitch.
///
/// [weight] is a cheap size hint (usually the length of the biggest string
/// already seen, or 0 to stay on the caller). The snapshot write used to
/// run `jsonEncode` on the UI isolate after the dashboard was ready, which
/// froze the first frames.
Future<String> encodeJsonOffMain(Object? value, {int weight = 0}) {
  if (weight < offMainJsonBytes) return Future<String>.value(jsonEncode(value));
  return compute(_encode, value);
}
