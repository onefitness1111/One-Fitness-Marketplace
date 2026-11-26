import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/legal/terms_screen.dart";
import "../../../core/navigation/local_back_stack.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/utils/save_error.dart";
import "../../../data/models/trainer.dart" show sameBeforeAfters;
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/blocked_users_screen.dart";
import "../../../core/widgets/delete_account_screen.dart";
import "../../../core/notifications/push_prompt.dart";
import "../../../core/widgets/change_password_form.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";
import "../shell/trainer_shell_state.dart";
import "coach_merit_badges_screen.dart";
import "trainer_edit_form.dart";

/// Set right before opening My Profile from somewhere that wants a section
/// open on arrival (My Pay's "See badge progress" link opens "badges").
/// Read once and cleared.
class PendingMyProfileSection extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? section) => state = section;
}

final pendingMyProfileSectionProvider =
    NotifierProvider<PendingMyProfileSection, String?>(PendingMyProfileSection.new);

/// A coach editing their own profile (App.jsx trainerMode "myprofile") —
/// same form as Staff management, minus commission rate and delete-someone-
/// else, plus the coach's own Account section: the Terms they agreed to,
/// and deleting their own account (Apple guideline 5.1.1(v), which applies
/// to every account-holding role, not just clients).
///
/// U8: a coach's Merit Badge progress lives here and only here — the
/// "Merit Badges" button opens this month's progress, Coach of the Month,
/// how badges work, and the badge history.
class MyProfileScreen extends ConsumerStatefulWidget {
  const MyProfileScreen({super.key});

  @override
  ConsumerState<MyProfileScreen> createState() => _MyProfileScreenState();
}

class _MyProfileScreenState extends ConsumerState<MyProfileScreen> {
  /// null = the profile form; otherwise "terms" or "delete".
  String? _section;

  void _close() => setState(() => _section = null);

  @override
  void initState() {
    super.initState();
    final pending = ref.read(pendingMyProfileSectionProvider);
    if (pending != null) {
      _section = pending;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(pendingMyProfileSectionProvider.notifier).set(null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_section == "badges") {
      return LocalBackScope(
        isOpen: true,
        onBack: _close,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
              child: BackBar(onBack: _close, title: "My Profile"),
            ),
            const Expanded(child: CoachMeritBadgesScreen()),
          ],
        ),
      );
    }
    if (_section == "blocked") {
      return LocalBackScope(
        isOpen: true,
        onBack: _close,
        child: BlockedUsersScreen(onBack: _close),
      );
    }

    if (_section == "terms") {
      return LocalBackScope(
        isOpen: true,
        onBack: _close,
        child: TermsScreen(onBack: _close),
      );
    }
    if (_section == "delete") {
      return LocalBackScope(
        isOpen: true,
        onBack: _close,
        child: DeleteAccountScreen(
          isCoach: true,
          onBack: _close,
          onDeleted: () {
            ref.read(accountDeletedNoticeProvider.notifier).show();
            ref.read(trainerAuthProvider.notifier).signOut();
          },
        ),
      );
    }

    final trainerAuth = ref.watch(trainerAuthProvider);
    final trainers = ref.watch(trainersProvider);
    final matches = trainers.where((t) => t.id == trainerAuth);
    if (matches.isEmpty) {
      return const Padding(padding: EdgeInsets.all(18), child: HintBox(text: "Profile not found."));
    }
    if (_section == "password") {
      return LocalBackScope(
        isOpen: true,
        onBack: _close,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(18),
          children: [
            BackBar(onBack: _close, title: "Change password"),
            const SizedBox(height: 14),
            ChangePasswordForm(email: matches.first.email ?? ""),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Above the profile form rather than inside it: the theme is a
        // device setting, not part of the profile being saved, and burying
        // it in a form with a Save button would imply otherwise.
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 14, 18, 4),
          child: ThemeModePicker(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
          child: Row(
            children: [
              TextButton(
                onPressed: () => setState(() => _section = "password"),
                style: TextButton.styleFrom(foregroundColor: AppColors.txt, padding: EdgeInsets.zero),
                child: const Text("Change password", style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              const Spacer(),
              TextButton.icon(
                key: const Key("my-profile-merit-badges"),
                onPressed: () => setState(() => _section = "badges"),
                style: TextButton.styleFrom(foregroundColor: AppColors.gold, padding: EdgeInsets.zero),
                icon: const Icon(LucideIcons.award, size: 15),
                label: const Text("Merit Badges", style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
        Expanded(
          child: TrainerEditForm(
            initial: matches.first,
            isOwnerEditing: false,
            onCancel: () => ref.read(trainerModeProvider.notifier).goBack(),
            onSave: (t, password) async {
              try {
                await SupabaseService.updateTrainerRow(
                  t.id,
                  name: t.name,
                  title: t.title,
                  coachName: t.coachName ?? "",
                  secondaryCoachName: t.secondaryCoachName,
                  email: t.email,
                  phone: t.phone,
                  photo: t.photo,
                  disciplines: t.disciplines,
                  sessionTypes: t.sessionTypes,
                  locations: t.locations,
                  bio: t.bio ?? "",
                  // Only when they changed — they're most of the request.
                  beforeAfters: sameBeforeAfters(matches.first.beforeAfters, t.beforeAfters) ? null : t.beforeAfters,
                  availability: t.availability,
                );
              } catch (e) {
                // ignore: avoid_print
                print("[my profile] save failed: $e");
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(saveErrorMessage(e)), duration: const Duration(seconds: 6)),
                  );
                }
                return;
              }
              ref.read(trainersProvider.notifier).upsert(t);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("✓ Profile saved")),
                );
              }
              ref.read(trainerModeProvider.notifier).goBack();
            },
          ),
        ),
        // Pinned below the form so it's reachable without saving first, and
        // stays two taps from the menu: Menu -> My Profile -> Delete Account.
        Container(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => setState(() => _section = "blocked"),
                  style: TextButton.styleFrom(foregroundColor: AppColors.mute),
                  icon: const Icon(LucideIcons.ban, size: 15),
                  label: const Text("Blocked", style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () => setState(() => _section = "terms"),
                  style: TextButton.styleFrom(foregroundColor: AppColors.mute),
                  icon: const Icon(LucideIcons.fileText, size: 15),
                  label: const Text("Terms of Use", style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () => setState(() => _section = "delete"),
                  style: TextButton.styleFrom(foregroundColor: AppColors.errorText),
                  icon: const Icon(LucideIcons.trash2, size: 15),
                  label: const Text("Delete Account", style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
