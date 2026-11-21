import "package:web/web.dart" as web;

void replaceBrowserPath(String path) {
  final current = web.window.location.pathname;
  if (current == path) return;
  web.window.history.replaceState(null, "", path);
}

String currentBrowserPath() => web.window.location.pathname;
