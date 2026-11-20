import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../core/auth/password_rules.dart";
import "../supabase/supabase_service.dart";
import "../theme/app_colors.dart";
import "../utils/write_failure.dart";
import "../../data/providers/trainer_providers.dart";

/// The two ways staff can deal with someone who can't get in, side by side:
///
///   Send reset email  — the normal route. The person follows a link and
///                       chooses their own password; nobody else ever knows
///                       it. Available to any staff member.
///   Set a password    — the desk route, for someone locked out with no
///                       access to their email. Owner only, because being
///                       able to set another account's password is a way to
///                       take over the owner's account.
///
/// Used on both the coach profile form and the client profile, so the two
/// can't drift apart.
class PasswordActions extends ConsumerStatefulWidget {
  const PasswordActions({
    super.key,
    required this.profileId,
    required this.email,
    required this.name,
  });

  /// Null while a brand-new account is still being created — setting a
  /// password needs an account to set it on.
  final String? profileId;
  final String email;
  final String name;

  @override
  ConsumerState<PasswordActions> createState() => _PasswordActionsState();
}

class _PasswordActionsState extends ConsumerState<PasswordActions> {
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _message;
  bool _isError = false;

  void _say(String msg, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = msg;
      _isError = error;
      _busy = false;
    });
  }

  Future<void> _sendReset() async {
    final id = widget.profileId;
    if (id == null) {
      _say("Save this profile first, then you can send a reset link.", error: true);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await SupabaseService.sendPasswordResetFor(id);
      _say("Reset link sent to the email on their account.");
    } catch (e) {
      _say(_failure(e, "Couldn't send the reset email"), error: true);
    }
  }

  /// The edge function already phrases the refusal. A bare network failure
  /// still gets the connection hint.
  String _failure(Object e, String whatFailed) {
    if (e is Exception) {
      final msg = e.toString().replaceFirst(RegExp(r"^Exception:\s*"), "").trim();
      if (msg.isNotEmpty) return msg;
    }
    return writeFailureMessage(e, whatFailed: whatFailed);
  }

  @override
  void dispose() {
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _setPassword() async {
    final id = widget.profileId;
    if (id == null) {
      _say("Save this profile first, then you can set a password.", error: true);
      return;
    }
    final problem = passwordChangeError(_next.text, _confirm.text);
    if (problem != null) {
      _say(problem, error: true);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await SupabaseService.adminSetPassword(profileId: id, password: _next.text);
      _next.clear();
      _confirm.clear();
      _say("Password updated. Tell ${widget.name} the new password and ask them to change it after signing in.");
    } catch (e) {
      _say(_failure(e, "Couldn't set that password"), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOwner = ref.watch(trainerAuthProvider) == "owner";
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: AppColors.line),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        Text("Password", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.txt)),
        const SizedBox(height: 4),
        Text(
          isOwner
              ? "Set a password for ${widget.name}, or email them a link."
              : "Email them a link so they can choose a new password.",
          style: TextStyle(fontSize: 12, color: AppColors.mute, height: 1.4),
        ),
        if (isOwner) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _next,
            obscureText: !_show,
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            onChanged: (_) => setState(() => _message = null),
            style: TextStyle(color: AppColors.txt, fontSize: 14),
            decoration: InputDecoration(
              hintText: "New password",
              hintStyle: TextStyle(color: AppColors.mute),
              filled: true,
              fillColor: AppColors.bg,
              isDense: true,
              border: border,
              enabledBorder: border,
              focusedBorder: border,
              suffixIcon: IconButton(
                onPressed: () => setState(() => _show = !_show),
                icon: Icon(_show ? LucideIcons.eyeOff : LucideIcons.eye, size: 16, color: AppColors.mute),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _confirm,
            obscureText: !_show,
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            onChanged: (_) => setState(() => _message = null),
            style: TextStyle(color: AppColors.txt, fontSize: 14),
            decoration: InputDecoration(
              hintText: "Confirm password",
              hintStyle: TextStyle(color: AppColors.mute),
              filled: true,
              fillColor: AppColors.bg,
              isDense: true,
              border: border,
              enabledBorder: border,
              focusedBorder: border,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _busy ? null : _setPassword,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.txt,
              side: BorderSide(color: AppColors.txt),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: const Text("Set new password", style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
        TextButton(
          onPressed: _busy ? null : _sendReset,
          style: TextButton.styleFrom(foregroundColor: AppColors.mute),
          child: Text(_busy ? "Working…" : "Send reset email", style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        if (_message != null)
          Text(
            _message!,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: _isError ? AppColors.errorText : AppColors.txt,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}

