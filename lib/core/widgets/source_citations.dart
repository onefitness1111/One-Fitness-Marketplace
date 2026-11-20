import "tap_highlight.dart";
import "package:flutter/material.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "package:url_launcher/url_launcher.dart";
import "../legal/health_sources.dart";
import "../theme/app_colors.dart";

/// Citations for health guidance, with the disclaimer that goes with them.
///
/// App Review guideline 1.4.1 requires that an app showing health or
/// medical recommendations cites its sources, and that the citations are
/// easy for the user to find. By default every source is on screen under
/// the guidance (the training screen). Pass [initiallyVisible] to keep the
/// first sources — and the disclaimer — on screen with no extra tap, and
/// to tuck the rest behind one control. That control stays on this page.
/// The citations are not moved to a legal screen.
class SourceCitations extends StatefulWidget {
  const SourceCitations({
    super.key,
    required this.sources,
    required this.disclaimer,
    this.initiallyVisible,
  });

  final List<HealthSource> sources;
  final String disclaimer;

  /// How many sources show before "Show N more sources". Null shows every
  /// source immediately, which is what screens other than nutrition use.
  final int? initiallyVisible;

  @override
  State<SourceCitations> createState() => _SourceCitationsState();
}

class _SourceCitationsState extends State<SourceCitations> {
  bool _expanded = false;

  bool get _canFold =>
      widget.initiallyVisible != null &&
      widget.initiallyVisible! < widget.sources.length &&
      widget.initiallyVisible! > 0;

  int get _shownCount {
    if (!_canFold || _expanded) return widget.sources.length;
    return widget.initiallyVisible!;
  }

  Future<void> _open(BuildContext context, HealthSource s) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await launchUrl(
        Uri.parse(s.url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw Exception("could not launch");
    } catch (_) {
      // The citation still has to be usable if the browser won't open —
      // showing the address means it can be typed or copied by hand.
      messenger.showSnackBar(
        SnackBar(content: Text(s.url), duration: const Duration(seconds: 8)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final disclaimer = Text(
      widget.disclaimer,
      style: TextStyle(fontSize: 11.5, color: AppColors.mute, height: 1.5),
    );
    final hidden =
        widget.sources.length -
        (widget.initiallyVisible ?? widget.sources.length);
    final moreLabel = hidden == 1
        ? "Show 1 more source ⌄"
        : "Show $hidden more sources ⌄";
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 14, bottom: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.bookOpen, size: 14, color: AppColors.gold),
              SizedBox(width: 7),
              Text(
                "SOURCES",
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.gold,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Default: the disclaimer leads, then every source. Folded: the
          // first sources lead, and the disclaimer stays under them so it
          // is never behind the "show more" tap. Guideline 1.4.1.
          if (!_canFold) ...[disclaimer, const SizedBox(height: 12)],
          Text(
            "This guidance is based on:",
            style: TextStyle(
              fontSize: 11.5,
              color: AppColors.txt,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          for (final s in widget.sources.take(_shownCount))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TapHighlight(
                onTap: () => _open(context, s),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.topic,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: AppColors.mute,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              s.title,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: AppColors.gold,
                                fontWeight: FontWeight.w700,
                                height: 1.35,
                                decoration: TextDecoration.underline,
                                decorationColor: AppColors.gold,
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.only(left: 6, top: 2),
                            child: Icon(
                              LucideIcons.externalLink,
                              size: 12,
                              color: AppColors.gold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 1),
                      Text(
                        "${s.publisher} · ${s.year}",
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.mute,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_canFold)
            Center(
              child: TapHighlight(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 8,
                  ),
                  child: Text(
                    _expanded ? "Show fewer ⌃" : moreLabel,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.mute,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          if (_canFold) ...[const SizedBox(height: 8), disclaimer],
        ],
      ),
    );
  }
}
