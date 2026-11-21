import "dart:typed_data";
import "dart:ui" as ui;

import "package:flutter/material.dart";
import "package:flutter/rendering.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:http/http.dart" as http;
import "../../../core/platform/share_bytes.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/booking_utils.dart";
import "../../../core/utils/date_utils.dart";
import "../../../core/utils/progress_summary.dart";
import "../../../core/utils/share_origin.dart";
import "../../../core/widgets/app_buttons.dart";
import "../../../data/models/progress_photo.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";

/// A ONE Fitness card the client can send to Instagram from the share sheet.
class ResultsShareButton extends ConsumerStatefulWidget {
  const ResultsShareButton({super.key});

  @override
  ConsumerState<ResultsShareButton> createState() => _ResultsShareButtonState();
}

class _ResultsShareButtonState extends ConsumerState<ResultsShareButton> {
  final _boundary = GlobalKey();
  bool _busy = false;
  bool _includePhoto = true;
  ui.Image? _photo;

  Future<void> _open() async {
    final record = ref.read(clientRecordProvider);
    final photos = [...record.photos]..sort((a, b) => b.date.compareTo(a.date));
    _photo = null;
    if (photos.isNotEmpty) {
      final bytes = await _bytes(photos.first);
      if (bytes != null) {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        _photo = frame.image;
      }
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: AppColors.bg,
          contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RepaintBoundary(
                  key: _boundary,
                  child: _CardFace(
                    summary: _summary(),
                    photo: _includePhoto ? _photo : null,
                  ),
                ),
                if (_photo != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Include a photo", style: TextStyle(fontSize: 14)),
                    value: _includePhoto,
                    activeThumbColor: AppColors.txt,
                    onChanged: (v) => setLocal(() => _includePhoto = v),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close")),
            TextButton(
              onPressed: _busy ? null : () => _share(ctx),
              child: Text(_busy ? "Saving…" : "Share"),
            ),
          ],
        ),
      ),
    );
  }

  ProgressSummary _summary() {
    final record = ref.read(clientRecordProvider);
    final info = ref.read(clientInfoProvider);
    final from = addDaysIso(isoToday(), -30);
    return summarizeProgress(
      clientId: info.id,
      bookings: ref.read(allBookingsProvider),
      logs: record.workoutLogs,
      measurements: record.measurements,
      photos: record.photos,
      from: from,
      to: isoToday(),
    );
  }

  Future<void> _share(BuildContext origin) async {
    final boundary = _boundary.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return;
    setState(() => _busy = true);
    try {
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      if (!origin.mounted) return;
      await shareLocalBytes(
        filename: "one-fitness-results.png",
        bytes: data.buffer.asUint8List(),
        mimeType: "image/png",
        sharePositionOrigin: shareOriginFrom(origin),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't open the share sheet.")));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List?> _bytes(ProgressPhoto photo) async {
    final inline = photo.inlineBytes;
    if (inline != null && inline.isNotEmpty) return inline;
    if (!photo.isStoredFile) return null;
    try {
      final url = await SupabaseService.signedProgressPhotoUrl(photo.img);
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
      child: BtnGhost(
        onPressed: _open,
        full: true,
        child: const Text("Share results card"),
      ),
    );
  }
}

class _CardFace extends StatelessWidget {
  const _CardFace({required this.summary, required this.photo});
  final ProgressSummary summary;
  final ui.Image? photo;

  @override
  Widget build(BuildContext context) {
    final weight = summary.changeFor("Weight");
    final lift = summary.liftGains.isEmpty ? null : summary.liftGains.first;
    return Container(
      width: 320,
      color: Colors.black,
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Image.asset("assets/images/logo.png", height: 36),
              const SizedBox(width: 10),
              const Text("ONE FITNESS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
            ],
          ),
          const SizedBox(height: 18),
          if (photo != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 180,
                width: double.infinity,
                child: RawImage(image: photo, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 16),
          ],
          _line("Sessions", "${summary.sessionsDone}"),
          _line("Workouts", "${summary.workoutsLogged}"),
          if (weight != null)
            _line("Weight", "${_n(weight.before)} to ${_n(weight.after)} lb"),
          if (lift != null)
            _line(lift.name, "${_n(lift.before)} to ${_n(lift.after)} lb"),
          const SizedBox(height: 14),
          Text("Last 30 days", style: TextStyle(color: AppColors.mute, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _line(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(color: Color(0xFFD9D9D9), fontSize: 14))),
            Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
          ],
        ),
      );

  String _n(double n) => n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(1);
}
