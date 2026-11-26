import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/navigation/local_back_stack.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/utils/save_error.dart";
import "../../../core/theme/app_colors.dart";
import "../../../data/models/trainer.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/supabase_bootstrap_provider.dart";
import "../../../data/providers/trainer_providers.dart";
import "coaches_overview_screen.dart";
import "trainer_edit_form.dart";

/// The owner's one Staff page (bottom-right tab). Merges the old Staff tab
/// (StaffManager.jsx: add a trainer, edit profile/availability/pay, delete)
/// with the old Coaches page (CoachesOverview.jsx: approval code, review new
/// coaches, client counts, flags, password tools, badges, remove).
class StaffScreen extends ConsumerStatefulWidget {
  const StaffScreen({super.key});

  @override
  ConsumerState<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends ConsumerState<StaffScreen> {
  Trainer? _editing;
  bool _creating = false;

  @override
  Widget build(BuildContext context) {
    if (_editing != null || _creating) {
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() {
          _editing = null;
          _creating = false;
        }),
        child: TrainerEditForm(
          initial: _editing,
          isOwnerEditing: true,
          onCancel: () => setState(() {
            _editing = null;
            _creating = false;
          }),
          onSave: (t, password) async {
            String realId = t.id;
            try {
              if (_editing != null) {
                await SupabaseService.updateTrainerRow(
                  t.id,
                  name: t.name,
                  title: t.title,
                  coachName: t.coachName ?? "",
                  secondaryCoachName: t.secondaryCoachName,
                  clearSecondaryCoachName: (t.secondaryCoachName ?? "").isEmpty,
                  email: t.email,
                  phone: t.phone,
                  photo: t.photo,
                  disciplines: t.disciplines,
                  sessionTypes: t.sessionTypes,
                  locations: t.locations,
                  bio: t.bio ?? "",
                  // Only when they changed — they're most of the request.
                  beforeAfters: sameBeforeAfters(_editing!.beforeAfters, t.beforeAfters) ? null : t.beforeAfters,
                  availability: t.availability,
                  commissionRate: t.commissionRate,
                  payoutMode: t.payoutMode,
                  payoutRateCents: t.payoutRateCents,
                  referralCommissionPercent: t.referralCommissionPercent,
                );
              } else {
                // Brand-new trainer — real Supabase Auth account, created on
                // the owner's behalf without disturbing the owner's own
                // session (see signUpCoachOnBehalf's own doc comment).
                realId = await SupabaseService.signUpCoachOnBehalf(
                  email: t.email ?? "",
                  password: password ?? "",
                  name: t.name,
                  phone: t.phone,
                  photo: t.photo,
                  disciplines: t.disciplines,
                  sessionTypes: t.sessionTypes,
                  locations: t.locations,
                  bio: t.bio,
                  beforeAfters: t.beforeAfters,
                  availability: t.availability,
                  commissionRate: t.commissionRate,
                  coachCode: t.coachCode,
                  title: t.title,
                  coachName: t.coachName,
                  secondaryCoachName: t.secondaryCoachName,
                  payoutMode: t.payoutMode,
                  payoutRateCents: t.payoutRateCents,
                  referralCommissionPercent: t.referralCommissionPercent,
                  unavailability: t.unavailability,
                );
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      _editing != null
                          ? saveErrorMessage(e)
                          : "Couldn't create that trainer — ${e.toString().replaceFirst('Exception: ', '').replaceFirst('AuthException: ', '')}",
                    ),
                  ),
                );
              }
              return;
            }
            ref
                .read(trainersProvider.notifier)
                .upsert(
                  realId == t.id
                      ? t
                      : Trainer(
                          id: realId,
                          name: t.name,
                          email: t.email,
                          phone: t.phone,
                          photo: t.photo,
                          disciplines: t.disciplines,
                          sessionTypes: t.sessionTypes,
                          locations: t.locations,
                          bio: t.bio,
                          beforeAfters: t.beforeAfters,
                          availability: t.availability,
                          commissionRate: t.commissionRate,
                          coachCode: t.coachCode,
                          title: t.title,
                          coachName: t.coachName,
                          secondaryCoachName: t.secondaryCoachName,
                          payoutMode: t.payoutMode,
                          payoutRateCents: t.payoutRateCents,
                          referralCommissionPercent:
                              t.referralCommissionPercent,
                          unavailability: t.unavailability,
                        ),
                );
            setState(() {
              _editing = null;
              _creating = false;
            });
          },
          onDelete: _editing == null
              ? null
              : () async {
                  final t = _editing!;
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: AppColors.card,
                      title: const Text("Delete trainer?"),
                      content: Text(
                        "Delete ${t.name}? This permanently removes their profile and login, and stops every future session/availability of theirs from being offered or bookable — everywhere in the app, immediately. They can't be reactivated; to come back, they'd have to sign up again from scratch as a brand-new profile. This can't be undone.",
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text("Cancel")),
                        TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text("Delete")),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  try {
                    await SupabaseService.deleteCoachAccount(t.id);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(e.toString().replaceFirst("Exception: ", ""))),
                      );
                    }
                    return;
                  }
                  ref.read(trainersProvider.notifier).remove(t.id);
                  setState(() => _editing = null);
                  // Best-effort freshness — the server-side cleanup already
                  // cleared every client's dangling primary/referred trainer
                  // id. Pull the roster so those stored ids match the server.
                  // They do not hide any client.
                  try {
                    final freshRoster = await SupabaseService.loadRoster();
                    ref.read(trainerRosterProvider.notifier).setAll(freshRoster);
                  } catch (_) {}
                },
        ),
      );
    }

    // U7: the Staff tab and the Coaches page are one page. The roster,
    // the coach approval code, new-coach review, password tools, badges and
    // removal all come from CoachesOverviewScreen; adding a trainer and the
    // full profile/availability/pay editor come from here.
    final payReady = ref.watch(trainerPayReadyProvider);
    return CoachesOverviewScreen(
      editEnabled: payReady,
      onAddTrainer: () => setState(() => _creating = true),
      onEditTrainer: (t) => setState(() => _editing = t),
    );
  }
}

