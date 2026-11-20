import "package:flutter/material.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../auth/password_rules.dart";
import "../supabase/supabase_service.dart";
import "../theme/app_colors.dart";
import "../utils/write_failure.dart";
import "widgets.dart";

/// New password and confirm, for the signed-in person. Saving calls
/// [SupabaseService.updatePassword]. The reset email stays as a second way.
class ChangePasswordForm extends StatefulWidget {
  const ChangePasswordForm({super.key, this.email});

  /// Address the reset link is sent to. Empty hides a useful send.
  final String? email;

  @override
  State<ChangePasswordForm> createState() => _ChangePasswordFormState();
}

class _ChangePasswordFormState extends State<ChangePasswordForm> {
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _show = false;
  bool _saving = false;
  bool _sending = false;
  String? _message;
  bool _error = false;

  @override
  void dispose() {
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _say(String text, {required bool error}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _error = error;
      _saving = false;
      _sending = false;
    });
  }

  Future<void> _save() async {
    final problem = passwordChangeError(_next.text, _confirm.text);
    setState(() {
      _message = problem;
      _error = problem != null;
      _saving = problem == null;
    });
    if (problem != null) return;
    try {
      await SupabaseService.updatePassword(_next.text);
      _next.clear();
      _confirm.clear();
      _say("Password updated.", error: false);
    } catch (e) {
      _say(writeFailureMessage(e, whatFailed: "Couldn't update the password"), error: true);
    }
  }

  Future<void> _sendReset() async {
    final email = (widget.email ?? "").trim();
    if (email.isEmpty) {
      _say("Add an email on this profile before sending a reset link.", error: true);
      return;
    }
    setState(() {
      _sending = true;
      _message = null;
    });
    try {
      await SupabaseService.sendPasswordReset(email);
      _say("Reset email sent.", error: false);
    } catch (e) {
      _say(writeFailureMessage(e, whatFailed: "Couldn't send the reset email"), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel("Change password"),
        const SizedBox(height: 8),
        _PasswordLine(
          controller: _next,
          hint: "New password",
          show: _show,
          onToggle: () => setState(() => _show = !_show),
          onChanged: () => setState(() => _message = null),
        ),
        const SizedBox(height: 8),
        _PasswordLine(
          controller: _confirm,
          hint: "Confirm password",
          show: _show,
          onToggle: () => setState(() => _show = !_show),
          onChanged: () => setState(() => _message = null),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _message!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: _error ? AppColors.errorText : AppColors.txt,
              ),
            ),
          ),
        const SizedBox(height: 10),
        BtnGold(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? "Saving…" : "Save"),
        ),
        TextButton(
          onPressed: _sending ? null : _sendReset,
          style: TextButton.styleFrom(
            foregroundColor: AppColors.mute,
            padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
          ),
          child: Text(
            _sending ? "Sending…" : "Send password reset email",
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _PasswordLine extends StatelessWidget {
  const _PasswordLine({
    required this.controller,
    required this.hint,
    required this.show,
    required this.onToggle,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final bool show;
  final VoidCallback onToggle;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: !show,
      keyboardType: TextInputType.visiblePassword,
      textCapitalization: TextCapitalization.none,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: (_) => onChanged(),
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
      style: TextStyle(color: AppColors.txt, fontSize: 14),
      cursorColor: AppColors.txt,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.mute, fontSize: 14),
        filled: true,
        fillColor: AppColors.bg,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        suffixIcon: IconButton(
          onPressed: onToggle,
          icon: Icon(show ? LucideIcons.eyeOff : LucideIcons.eye, size: 16, color: AppColors.mute),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.line)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.line)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: AppColors.txt)),
      ),
    );
  }
}

/// The screen a reset link opens. Saving the new password returns home.
class SetNewPasswordScreen extends StatefulWidget {
  const SetNewPasswordScreen({super.key, required this.onDone});

  final Future<void> Function() onDone;

  @override
  State<SetNewPasswordScreen> createState() => _SetNewPasswordScreenState();
}

class _SetNewPasswordScreenState extends State<SetNewPasswordScreen> {
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _message;
  bool _error = false;

  @override
  void dispose() {
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final problem = passwordChangeError(_next.text, _confirm.text);
    if (problem != null) {
      setState(() {
        _message = problem;
        _error = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await SupabaseService.updatePassword(_next.text);
      await widget.onDone();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = true;
        _message = writeFailureMessage(e, whatFailed: "Couldn't update the password");
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(24),
          children: [
            Text("Set a new password", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.txt)),
            const SizedBox(height: 8),
            Text("Choose a password for this account.", style: TextStyle(fontSize: 13, color: AppColors.mute)),
            const SizedBox(height: 18),
            _PasswordLine(
              controller: _next,
              hint: "New password",
              show: _show,
              onToggle: () => setState(() => _show = !_show),
              onChanged: () => setState(() => _message = null),
            ),
            const SizedBox(height: 8),
            _PasswordLine(
              controller: _confirm,
              hint: "Confirm password",
              show: _show,
              onToggle: () => setState(() => _show = !_show),
              onChanged: () => setState(() => _message = null),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_message!, style: TextStyle(fontSize: 12, color: _error ? AppColors.errorText : AppColors.txt)),
              ),
            const SizedBox(height: 16),
            BtnGold(onPressed: _busy ? null : _save, full: true, child: Text(_busy ? "Saving…" : "Save")),
          ],
        ),
      ),
    );
  }
}
