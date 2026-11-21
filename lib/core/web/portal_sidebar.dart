import "package:flutter/material.dart";
import "package:lucide_flutter/lucide_flutter.dart";

import "../theme/app_colors.dart";
import "../widgets/tap_highlight.dart";

class PortalNavEntry {
  const PortalNavEntry(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;
}

/// Left-hand menu for a wide browser. The phone keeps its bottom bar.
class PortalSidebar extends StatelessWidget {
  const PortalSidebar({
    super.key,
    required this.entries,
    required this.selected,
    required this.onSelect,
    this.footer,
  });

  static const width = 248.0;

  final List<PortalNavEntry> entries;
  final String selected;
  final ValueChanged<String> onSelect;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key("portal-sidebar"),
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.drawerBg,
          border: Border(right: BorderSide(color: AppColors.line)),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                child: Row(
                  children: [
                    Image.asset("assets/images/logo.png", height: 22),
                    const SizedBox(width: 10),
                    const Text(
                      "ONE Fitness",
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
                  children: [
                    for (final entry in entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: TapHighlight(
                          onTap: () => onSelect(entry.id),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
                            decoration: BoxDecoration(
                              color: selected == entry.id ? AppColors.gold : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  entry.icon,
                                  size: 18,
                                  color: selected == entry.id ? AppColors.onGold : AppColors.mute,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    entry.label,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: selected == entry.id ? AppColors.onGold : AppColors.txt,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (footer != null) footer!,
            ],
          ),
        ),
      ),
    );
  }
}

class PortalSignOutButton extends StatelessWidget {
  const PortalSignOutButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: TapHighlight(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            children: [
              Icon(LucideIcons.logOut, size: 16, color: AppColors.errorText),
              const SizedBox(width: 12),
              Text("Sign out", style: TextStyle(fontSize: 13, color: AppColors.errorText, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Puts [sidebar] beside [child] on a wide page. A narrow page is [child] alone.
class PortalBody extends StatelessWidget {
  const PortalBody({super.key, required this.wide, required this.sidebar, required this.child});

  final bool wide;
  final Widget sidebar;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!wide) return child;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sidebar,
        Expanded(child: child),
      ],
    );
  }
}
