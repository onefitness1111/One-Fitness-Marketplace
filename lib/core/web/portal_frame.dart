import "package:flutter/material.dart";

/// The website fills the browser window. Wide screens pick their own
/// chrome inside the shells. Narrow screens keep the phone layout.
class PortalFrame extends StatelessWidget {
  const PortalFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
