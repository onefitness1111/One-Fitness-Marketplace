import "package:flutter_web_plugins/url_strategy.dart";

/// Path addresses (/login) on the website. On the phone this is a no-op.
void configureUrlStrategy() {
  usePathUrlStrategy();
}
