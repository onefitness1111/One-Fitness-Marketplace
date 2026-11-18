import "package:flutter/material.dart";
import "../supabase/supabase_service.dart";
import "../theme/app_colors.dart";
import "../../data/models/progress_photo.dart";

/// A progress photo. Older ones are still a data URL inside the client
/// record. New ones are a path in the private bucket, opened with a
/// short-lived signed link.
class ProgressPhotoView extends StatefulWidget {
  const ProgressPhotoView({super.key, required this.photo, this.fit = BoxFit.cover});

  final ProgressPhoto photo;
  final BoxFit fit;

  @override
  State<ProgressPhotoView> createState() => _ProgressPhotoViewState();
}

class _ProgressPhotoViewState extends State<ProgressPhotoView> {
  String? _url;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProgressPhotoView old) {
    super.didUpdateWidget(old);
    if (old.photo.img != widget.photo.img) {
      _url = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    if (!widget.photo.isStoredFile) return;
    try {
      final url = await SupabaseService.signedProgressPhotoUrl(widget.photo.img);
      if (!mounted) return;
      setState(() => _url = url);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.photo.isStoredFile) {
      final bytes = widget.photo.inlineBytes;
      if (bytes == null) return const SizedBox.shrink();
      return Image.memory(bytes, fit: widget.fit, gaplessPlayback: true);
    }
    final url = _url;
    if (url == null) {
      return ColoredBox(
        color: AppColors.card,
        child: Center(
          child: _failed
              ? Icon(Icons.hide_image_outlined, color: AppColors.mute)
              : SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.mute),
                ),
        ),
      );
    }
    return Image.network(url, fit: widget.fit, gaplessPlayback: true);
  }
}
