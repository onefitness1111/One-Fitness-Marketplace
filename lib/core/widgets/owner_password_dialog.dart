import "package:flutter/material.dart";
import "../supabase/supabase_service.dart";
import "../theme/app_colors.dart";

/// Asks the owner to type their password again before a refund.
/// A wrong password does not continue. Signing in again refreshes the
/// session; it does not create a second account.
Future<bool> confirmOwnerPassword(BuildContext context) async {
  final password = TextEditingController();
  final email = SupabaseService.currentUser?.email ?? "";
  String? error;
  var busy = false;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text("Confirm it's you", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Type your owner password to refund this payment."),
            const SizedBox(height: 10),
            TextField(
              onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: "Password"),
              onSubmitted: (_) {},
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    if (password.text.isEmpty || email.isEmpty) {
                      setLocal(() => error = "Enter your password.");
                      return;
                    }
                    setLocal(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      await SupabaseService.signIn(email, password.text);
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } catch (_) {
                      setLocal(() {
                        busy = false;
                        error = "That password didn't match.";
                      });
                    }
                  },
            child: Text(busy ? "Checking…" : "Refund"),
          ),
        ],
      ),
    ),
  );
  password.dispose();
  return ok == true;
}
