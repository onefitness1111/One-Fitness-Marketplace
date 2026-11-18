import "dart:async";
import "dart:io";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "package:image_picker/image_picker.dart";
import "package:path_provider/path_provider.dart";
import "package:record/record.dart";

import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
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

  final List<({String name, List<int> bytes, String type})> _docs = [];
  final List<({String label, List<int> bytes})> _beforeAfter = [];
  final List<List<int>> _locationPhotos = [];

  bool _permission = false;
  bool _clientsAllowed = false;
  bool _followRules = false;

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
    if (!_permission || !_clientsAllowed || !_followRules) {
      setState(() => _error = "Tick every box on the location approval notice.");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final files = <Map<String, String>>[
        if (_clipPath != null) {"key": "clip", "contentType": "audio/mp4"},
        for (var i = 0; i < _docs.length; i++) {"key": "doc-$i", "contentType": _docs[i].type},
        for (var i = 0; i < _beforeAfter.length; i++)
          {"key": _beforeAfter[i].label, "contentType": "image/jpeg"},
        for (var i = 0; i < _locationPhotos.length; i++) {"key": "location-$i", "contentType": "image/jpeg"},
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
      for (var i = 0; i < _docs.length; i++) {
        await put("doc-$i", _docs[i].bytes, _docs[i].type);
      }
      for (final item in _beforeAfter) {
        await put(item.label, item.bytes, "image/jpeg");
      }
      for (var i = 0; i < _locationPhotos.length; i++) {
        await put("location-$i", _locationPhotos[i], "image/jpeg");
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
        "locationChecks": {
          "permission": _permission,
          "clientsAllowed": _clientsAllowed,
          "followRules": _followRules,
        },
        "clipPath": pathOf("clip"),
        "documentPaths": [
          for (var i = 0; i < _docs.length; i++)
            if (pathOf("doc-$i") != null) {"name": _docs[i].name, "path": pathOf("doc-$i")},
        ],
        "beforeAfterPaths": [
          for (final item in _beforeAfter)
            if (pathOf(item.label) != null) {"label": item.label, "path": pathOf(item.label)},
        ],
        "locationPhotoPaths": [
          for (var i = 0; i < _locationPhotos.length; i++)
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
            const SectionLabel("Documents"),
            const HintBox(text: "Certifications, CPR, degrees, and accolades. Add each file you have."),
            const SizedBox(height: 8),
            BtnGhost(
              onPressed: _docs.length >= 12
                  ? null
                  : () async {
                      final picked = await FilePicker.platform.pickFiles(withData: true);
                      final file = picked?.files.single;
                      if (file?.bytes == null) return;
                      setState(() => _docs.add((name: file!.name, bytes: file.bytes!, type: "application/octet-stream")));
                    },
              child: Text("Add a document (${_docs.length})"),
            ),
            for (final doc in _docs)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(doc.name, style: TextStyle(fontSize: 12, color: AppColors.mute)),
              ),
            const SizedBox(height: 16),
            const SectionLabel("Before and after"),
            BtnGhost(
              onPressed: _beforeAfter.length >= 12
                  ? null
                  : () async {
                      final bytes = await _pickPhoto();
                      if (bytes == null) return;
                      final label = _beforeAfter.length.isEven ? "before-${_beforeAfter.length ~/ 2}" : "after-${_beforeAfter.length ~/ 2}";
                      setState(() => _beforeAfter.add((label: label, bytes: bytes)));
                    },
              child: Text("Add a photo (${_beforeAfter.length})"),
            ),
            const SizedBox(height: 16),
            const SectionLabel("Where you'll coach"),
            const SizedBox(height: 8),
            FieldLabeled(label: "Location name", child: AppField(controller: _locationName)),
            const SizedBox(height: 10),
            FieldLabeled(label: "Address", child: AppField(controller: _locationAddress)),
            const SizedBox(height: 10),
            const Text("Location approval notice", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            Material(
              type: MaterialType.transparency,
              child: CheckboxListTile(
                value: _permission,
                onChanged: (v) => setState(() => _permission = v ?? false),
                title: const Text("I have permission to coach at this location", style: TextStyle(fontSize: 13)),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            Material(
              type: MaterialType.transparency,
              child: CheckboxListTile(
                value: _clientsAllowed,
                onChanged: (v) => setState(() => _clientsAllowed = v ?? false),
                title: const Text("This location allows ONE Fitness clients", style: TextStyle(fontSize: 13)),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            Material(
              type: MaterialType.transparency,
              child: CheckboxListTile(
                value: _followRules,
                onChanged: (v) => setState(() => _followRules = v ?? false),
                title: const Text("I will follow the location's rules", style: TextStyle(fontSize: 13)),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ),
            BtnGhost(
              onPressed: _locationPhotos.length >= 8
                  ? null
                  : () async {
                      final bytes = await _pickPhoto();
                      if (bytes == null) return;
                      setState(() => _locationPhotos.add(bytes));
                    },
              child: Text("Add a location photo (${_locationPhotos.length} of 8)"),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
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
