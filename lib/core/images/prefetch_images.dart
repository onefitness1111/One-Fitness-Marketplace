import "dart:async";

import "package:flutter/widgets.dart";

/// Pulls above-the-fold photos into the image cache before the dashboard
/// frame. A slow photo does not hold the screen past [cap].
Future<void> prefetchNetworkImages(
  Iterable<String?> urls, {
  Duration cap = const Duration(milliseconds: 400),
}) async {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  final ratio = views.isEmpty ? 1.0 : views.first.devicePixelRatio;
  final config = ImageConfiguration(devicePixelRatio: ratio);
  final jobs = <Future<void>>[];
  final seen = <String>{};
  for (final raw in urls) {
    final url = (raw ?? "").trim();
    if (!url.startsWith("http") || !seen.add(url)) continue;
    if (jobs.length >= 8) break;
    jobs.add(_one(url, config));
  }
  if (jobs.isEmpty) return;
  try {
    await Future.wait(jobs).timeout(cap);
  } catch (_) {}
}

Future<void> _one(String url, ImageConfiguration config) async {
  final stream = NetworkImage(url).resolve(config);
  final done = Completer<void>();
  late final ImageStreamListener listener;
  listener = ImageStreamListener((image, _) {
    stream.removeListener(listener);
    if (!done.isCompleted) done.complete();
  }, onError: (Object error, StackTrace? stack) {
    stream.removeListener(listener);
    if (!done.isCompleted) done.complete();
  });
  stream.addListener(listener);
  await done.future;
}
