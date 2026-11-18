import "dart:async";
import "dart:io";
import "dart:typed_data";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "package:image_picker/image_picker.dart";
import "package:path_provider/path_provider.dart";
import "package:record/record.dart";

import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/coach_application_files.dart";
import "../../../core/widgets/widgets.dart";

/// Apply now. Does not create a login. The owner gets an email and approves
/// or denies it in the app. An approval emails the coach code when one is
/// still unused.
class CoachApplyScreen extends StatefulWidget {
  const CoachApplyScreen({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  State<CoachApplyScreen> createState() => _CoachApplyScreenState();
}

class _CoachApplyScreenState extends State<CoachApplyScreen> {
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _email = TextEditingController();
  final _birthday = TextEditingController();
  final _phone = TextEditingController();
  final _pitch = TextEditingController();
  final _bio = TextEditingController();
  final _locationName = TextEditingController();
  final _locationAddress = TextEditingController();

  final _recorder = AudioRecorder();
  Timer? _tick;
  int _seconds = 0;
  bool _recording = false;
  String? _clipPath;

  String? _chosenType;
  final List<_ApplicationFile> _uploads = [];

  bool _busy = false;
  String? _error;
  bool _sent = false;

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_recorder.dispose());
    _first.dispose();
    _last.dispose();
    _email.dispose();
    _birthday.dispose();
    _phone.dispose();
    _pitch.dispose();
    _bio.dispose();
    _locationName.dispose();
    _locationAddress.dispose();
    super.dispose();
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      final path = await _recorder.stop();
      _tick?.cancel();
      setState(() {
        _recording = false;
        _clipPath = path;
      });
      return;
    }
    final allowed = await _recorder.hasPermission();
    if (!allowed) {
      setState(() => _error = "Microphone permission is needed for the optional clip.");
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = "${dir.path}/coach-answer.m4a";
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() {
      _recording = true;
      _seconds = 0;
      _error = null;
      _clipPath = null;
    });
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      if (_seconds >= 19) {
        final stopped = await _recorder.stop();
        _tick?.cancel();
        setState(() {
          _recording = false;
          _seconds = 20;
          _clipPath = stopped;
        });
        return;
      }
      setState(() => _seconds += 1);
    });
  }

  int get _fileCount => _uploads.fold(0, (sum, file) => sum + file.fileCount);

  int get _locationPhotoCount => _uploads.where((file) => file.kind == "location-photo").length;

  Future<void> _addChosenFile() async {
    final kind = _chosenType;
    if (kind == null) {
      setState(() => _error = "Choose a file type first.");
      return;
    }
    final blocked = applicationAddError(
      kind: kind,
      filesSoFar: _fileCount,
      locationPhotos: _locationPhotoCount,
    );
    if (blocked != null) {
      setState(() => _error = blocked);
      return;
    }
    if (kind == "before-after") {
      final pair = await showDialog<_PhotoPair>(
        context: context,
        builder: (_) => const _BeforeAfterDialog(),
      );
      if (pair == null || !mounted) return;
      setState(() {
        _uploads.add(_ApplicationFile.pair(before: pair.before, after: pair.after));
        _error = null;
      });
      return;
    }
    if (kind == "location-photo") {
      final bytes = await _pickPhoto();
      if (bytes == null || !mounted) return;
      setState(() {
        _uploads.add(_ApplicationFile.photo(kind: kind, bytes: bytes));
        _error = null;
      });
      return;
    }
    final picked = await FilePicker.platform.pickFiles(withData: true);
    final file = picked?.files.single;
    if (file?.bytes == null || !mounted) return;
    setState(() {
      _uploads.add(_ApplicationFile.document(kind: kind, name: file!.name, bytes: file.bytes!));
      _error = null;
    });
  }

  Future<List<int>?> _pickPhoto() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 80);
    if (picked == null) return null;
    return picked.readAsBytes();
  }

  Future<void> _submit() async {
    final missing = <String>[
      if (_first.text.trim().isEmpty) "first name",
      if (_last.text.trim().isEmpty) "last name",
      if (!_email.text.contains("@")) "email",
      if (_birthday.text.trim().isEmpty) "birthday",
      if (_phone.text.trim().isEmpty) "phone",
      if (_pitch.text.trim().isEmpty) "what makes you a great coach",
      if (_bio.text.trim().isEmpty) "bio",
      if (_locationName.text.trim().isEmpty) "location name",
      if (_locationAddress.text.trim().isEmpty) "location address",
    ];
    if (missing.isNotEmpty) {
      setState(() => _error = "Still needed: ${missing.join(", ")}.");
      return;
    }
    final uploadError = applicationUploadError(
      _uploads.where((file) => file.kind != "before-after" && file.kind != "location-photo").map((file) => file.kind),
    );
    if (uploadError != null) {
      setState(() => _error = uploadError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final docs = _uploads.where((file) => file.kind != "before-after" && file.kind != "location-photo").toList();
      final pairs = _uploads.where((file) => file.isPair).toList();
      final places = _uploads.where((file) => file.kind == "location-photo").toList();
      final files = <Map<String, String>>[
        if (_clipPath != null) {"key": "clip", "contentType": "audio/mp4"},
        for (var i = 0; i < docs.length; i++) {"key": "doc-$i", "contentType": "application/octet-stream"},
        for (var i = 0; i < pairs.length; i++) ...[
          {"key": "before-$i", "contentType": "image/jpeg"},
          {"key": "after-$i", "contentType": "image/jpeg"},
        ],
        for (var i = 0; i < places.length; i++) {"key": "location-$i", "contentType": "image/jpeg"},
      ];
      final started = await SupabaseService.startCoachApplication(email: _email.text.trim(), files: files);
      final uploads = (started["uploads"] as List?) ?? const [];
      final byKey = <String, Map<String, dynamic>>{
        for (final raw in uploads) (raw as Map)["key"].toString(): Map<String, dynamic>.from(raw),
      };

      Future<void> put(String key, List<int> bytes, String type) async {
        final slot = byKey[key];
        if (slot == null) throw Exception("Upload for $key wasn't prepared.");
        await SupabaseService.uploadToSignedUrl(
          signedUrl: slot["signedUrl"].toString(),
          bytes: bytes,
          contentType: type,
        );
      }

      if (_clipPath != null) {
        await put("clip", await File(_clipPath!).readAsBytes(), "audio/mp4");
      }
      for (var i = 0; i < docs.length; i++) {
        await put("doc-$i", docs[i].bytes!, "application/octet-stream");
      }
      for (var i = 0; i < pairs.length; i++) {
        await put("before-$i", pairs[i].before!, "image/jpeg");
        await put("after-$i", pairs[i].after!, "image/jpeg");
      }
      for (var i = 0; i < places.length; i++) {
        await put("location-$i", places[i].bytes!, "image/jpeg");
      }

      String? pathOf(String key) => byKey[key]?["path"]?.toString();
      await SupabaseService.finishCoachApplication({
        "applicationId": started["applicationId"],
        "firstName": _first.text.trim(),
        "lastName": _last.text.trim(),
        "email": _email.text.trim(),
        "birthday": _birthday.text.trim(),
        "phone": _phone.text.trim(),
        "pitch": _pitch.text.trim(),
        "bio": _bio.text.trim(),
        "locationName": _locationName.text.trim(),
        "locationAddress": _locationAddress.text.trim(),
        "clipPath": pathOf("clip"),
        "documentPaths": [
          for (var i = 0; i < docs.length; i++)
            if (pathOf("doc-$i") != null)
              {"name": docs[i].name, "path": pathOf("doc-$i"), "kind": docs[i].kind},
        ],
        "beforeAfterPaths": [
          for (var i = 0; i < pairs.length; i++)
            if (pathOf("before-$i") != null && pathOf("after-$i") != null)
              {"beforePath": pathOf("before-$i"), "afterPath": pathOf("after-$i")},
        ],
        "locationPhotoPaths": [
          for (var i = 0; i < places.length; i++)
            if (pathOf("location-$i") != null) pathOf("location-$i"),
        ],
      });
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst("Exception: ", ""));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionLabel("Application sent"),
                const HintBox(text: "The owner has your application. If you're approved, you'll get an email with the next step. The coach code, if one is ready, is in that email."),
                const SizedBox(height: 16),
                BtnGold(onPressed: widget.onBack, child: const Text("Back")),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          children: [
            BackBar(onBack: _busy ? () {} : widget.onBack, title: "Coach sign-up"),
            const SizedBox(height: 8),
            const SectionLabel("Apply now"),
            const HintBox(text: "No code yet? Send this application. The owner reviews it in the app and emails you if you're approved. You can still use a code if you already have one."),
            const SizedBox(height: 14),
            FieldLabeled(label: "First name", child: AppField(controller: _first)),
            const SizedBox(height: 10),
            FieldLabeled(label: "Last name", child: AppField(controller: _last)),
            const SizedBox(height: 10),
            FieldLabeled(label: "Email", child: AppField(controller: _email, keyboardType: TextInputType.emailAddress)),
            const SizedBox(height: 10),
            FieldLabeled(label: "Birthday", child: AppField(kind: FieldKind.date, controller: _birthday)),
            const SizedBox(height: 10),
            FieldLabeled(label: "Phone", child: AppField(controller: _phone, keyboardType: TextInputType.phone)),
            const SizedBox(height: 16),
            const SectionLabel("What makes you a great coach"),
            AppField(controller: _pitch, maxLines: 4),
            const SizedBox(height: 10),
            const Text(
              "Optional. Pick any exercise. You have 20 seconds. Coach me through one rep as if I'm your client standing in front of you right now: get me set up and cue me through the movement.",
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 8),
            BtnGhost(
              onPressed: _busy ? null : _toggleRecord,
              child: Text(_recording
                  ? "Stop (${20 - _seconds}s left)"
                  : _clipPath == null
                      ? "Record a 20-second answer"
                      : "Recorded. Tap to record again"),
            ),
            const SizedBox(height: 16),
            const SectionLabel("Bio"),
            AppField(controller: _bio, maxLines: 4),
            const SizedBox(height: 16),
            const SectionLabel("Where you'll coach"),
            const SizedBox(height: 8),
            FieldLabeled(label: "Location name", child: AppField(controller: _locationName)),
            const SizedBox(height: 10),
            FieldLabeled(label: "Address", child: AppField(controller: _locationAddress)),
            const SizedBox(height: 16),
            const SectionLabel("What to include"),
            const SizedBox(height: 8),
            for (final line in applicationChecks(
              kinds: _uploads.map((file) => file.kind),
              beforeAfterPairs: _uploads.where((file) => file.isPair).length,
              locationPhotos: _locationPhotoCount,
            ))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      line.done ? Icons.check : Icons.circle_outlined,
                      size: 16,
                      color: line.done ? AppColors.txt : AppColors.mute,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(line.label, style: TextStyle(fontSize: 13, height: 1.35, color: AppColors.txt))),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text(
              "To send this, include at least one certification, CPR card, or degree, a location approval notice or owner permission, and insurance. $_fileCount of $applicationFileCap files.",
              style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.mute),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.card,
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(10),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _chosenType,
                  hint: Text("Choose a file type", style: TextStyle(color: AppColors.mute, fontSize: 14)),
                  dropdownColor: AppColors.card,
                  style: TextStyle(color: AppColors.txt, fontSize: 14),
                  iconEnabledColor: AppColors.txt,
                  items: [
                    for (final option in applicationTypeOptions)
                      DropdownMenuItem(value: option.$1, child: Text(option.$2)),
                  ],
                  onChanged: _busy ? null : (value) => setState(() => _chosenType = value),
                ),
              ),
            ),
            const SizedBox(height: 8),
            BtnGhost(
              onPressed: _busy ? null : _addChosenFile,
              child: const Text("Add file"),
            ),
            for (var i = 0; i < _uploads.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _UploadedRow(
                  file: _uploads[i],
                  onRemove: _busy
                      ? null
                      : () => setState(() => _uploads.removeAt(i)),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: AppColors.txt, fontSize: 12)),
            ],
            const SizedBox(height: 16),
            BtnGold(
              full: true,
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? "Sending…" : "Send application"),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApplicationFile {
  _ApplicationFile.document({required this.kind, required this.name, required List<int> bytes})
      : bytes = bytes,
        before = null,
        after = null;

  _ApplicationFile.photo({required this.kind, required List<int> bytes})
      : name = "Photo",
        bytes = bytes,
        before = null,
        after = null;

  _ApplicationFile.pair({required List<int> before, required List<int> after})
      : kind = "before-after",
        name = "Before and after photo",
        bytes = null,
        before = before,
        after = after;

  final String kind;
  final String name;
  final List<int>? bytes;
  final List<int>? before;
  final List<int>? after;

  bool get isPair => before != null && after != null;
  int get fileCount => isPair ? 2 : 1;
}

class _PhotoPair {
  const _PhotoPair(this.before, this.after);
  final List<int> before;
  final List<int> after;
}

class _UploadedRow extends StatelessWidget {
  const _UploadedRow({required this.file, required this.onRemove});

  final _ApplicationFile file;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                "${applicationTypeLabel(file.kind)}${file.isPair ? "" : " · ${file.name}"}",
                style: TextStyle(fontSize: 13, color: AppColors.txt),
              ),
            ),
            TextButton(
              onPressed: onRemove,
              style: TextButton.styleFrom(foregroundColor: AppColors.txt, padding: EdgeInsets.zero, minimumSize: Size.zero),
              child: const Text("Remove", style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (file.isPair)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Expanded(child: _PhotoHalf(label: "Before", bytes: file.before!)),
                const SizedBox(width: 8),
                Expanded(child: _PhotoHalf(label: "After", bytes: file.after!)),
              ],
            ),
          ),
      ],
    );
  }
}

class _PhotoHalf extends StatelessWidget {
  const _PhotoHalf({required this.label, required this.bytes});

  final String label;
  final List<int> bytes;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: AppColors.mute, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 3 / 4,
          child: DecoratedBox(
            decoration: BoxDecoration(color: AppColors.card, border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(8)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(Uint8List.fromList(bytes), fit: BoxFit.cover),
            ),
          ),
        ),
      ],
    );
  }
}

class _BeforeAfterDialog extends StatefulWidget {
  const _BeforeAfterDialog();

  @override
  State<_BeforeAfterDialog> createState() => _BeforeAfterDialogState();
}

class _BeforeAfterDialogState extends State<_BeforeAfterDialog> {
  List<int>? _before;
  List<int>? _after;

  Future<void> _pick(bool before) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 80);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      if (before) {
        _before = bytes;
      } else {
        _after = bytes;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ready = _before != null && _after != null;
    return Dialog(
      backgroundColor: AppColors.bg,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text("Before and after photo", style: TextStyle(color: AppColors.txt, fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text("Add the before photo on the left and the after photo on the right. They are saved together.", style: TextStyle(color: AppColors.mute, fontSize: 12, height: 1.4)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _PickHalf(label: "Before", bytes: _before, onPick: () => _pick(true))),
                const SizedBox(width: 8),
                Expanded(child: _PickHalf(label: "After", bytes: _after, onPick: () => _pick(false))),
              ],
            ),
            const SizedBox(height: 14),
            BtnGold(
              full: true,
              onPressed: ready ? () => Navigator.of(context).pop(_PhotoPair(_before!, _after!)) : null,
              child: const Text("Save pair"),
            ),
            const SizedBox(height: 8),
            BtnGhost(onPressed: () => Navigator.of(context).pop(), child: const Text("Cancel")),
          ],
        ),
      ),
    );
  }
}

class _PickHalf extends StatelessWidget {
  const _PickHalf({required this.label, required this.bytes, required this.onPick});

  final String label;
  final List<int>? bytes;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: AppColors.txt, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        AspectRatio(
          aspectRatio: 3 / 4,
          child: Material(
            color: AppColors.card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: AppColors.line)),
            child: InkWell(
              onTap: onPick,
              child: bytes == null
                  ? Center(child: Text("Add photo", style: TextStyle(color: AppColors.mute, fontSize: 12)))
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(Uint8List.fromList(bytes!), fit: BoxFit.cover),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
