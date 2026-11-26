import "package:flutter_riverpod/flutter_riverpod.dart";
import "../models/booking.dart";
import "../models/charge.dart";
import "../models/client_info.dart";
import "../models/coach_merit_badge.dart";
import "../models/points_ledger_entry.dart";
import "../models/trainer.dart";
import "client_providers.dart";
import "trainer_providers.dart";
import "../../core/supabase/supabase_service.dart";

/// The six things the owner can switch on or off for each coach.
///
/// The names match the columns of `coach_permissions` in the database. A new
/// coach starts with all six off. The owner always has all six.
enum CoachPermission {
  billingAccess("billing_access", "Billing & payments", "See and add a client's saved cards and billing address."),
  chargeFees("charge_fees", "Charge fees", "Charge a client's card for fees, such as late-cancel and no-show fees."),
  editPlans("edit_plans", "Edit plans & memberships", "Change a client's plan, price, expiry and sessions left, or sell or cancel a membership for them."),
  sendTexts("send_texts", "Text clients", "Send text messages to clients. In-app messages are always on."),
  manageOtherSchedules("manage_other_schedules", "Other coaches' schedules", "Book sessions onto another coach's calendar."),
  seeOwnRevenue("see_own_revenue", "See own revenue", "See their own pay, earnings and revenue figures. Never other coaches'.");

  const CoachPermission(this.column, this.label, this.help);

  /// The `coach_permissions` column.
  final String column;

  /// Short plain-English switch label.
  final String label;

  /// One line under the label.
  final String help;

  static CoachPermission? fromColumn(String column) {
    for (final p in values) {
      if (p.column == column) return p;
    }
    return null;
  }
}

/// One coach's six switches.
class CoachPermissions {
  const CoachPermissions(this._on);

  /// Everything off. What a new coach, or a coach with no row, gets.
  static const none = CoachPermissions({});

  /// Everything on.
  static final all = CoachPermissions({...CoachPermission.values});

  factory CoachPermissions.fromRow(Map<String, dynamic> row) => CoachPermissions({
        for (final p in CoachPermission.values)
          if (row[p.column] == true) p,
      });

  final Set<CoachPermission> _on;

  bool allows(CoachPermission p) => _on.contains(p);

  CoachPermissions withPermission(CoachPermission p, bool value) =>
      CoachPermissions(value ? {..._on, p} : _on.where((x) => x != p).toSet());

  int get count => _on.length;
}

class CoachPermissionsState {
  const CoachPermissionsState({this.loaded = false, this.byCoach = const {}});

  /// False until the first answer from the server. While false the app does
  /// not hide anything; the server enforces every switch either way, so a
  /// failed load can never give a coach more than the owner allowed.
  final bool loaded;
  final Map<String, CoachPermissions> byCoach;
}

class CoachPermissionsNotifier extends Notifier<CoachPermissionsState> {
  @override
  CoachPermissionsState build() => const CoachPermissionsState();

  void setAll(Map<String, CoachPermissions> next) =>
      state = CoachPermissionsState(loaded: true, byCoach: next);

  void setOne(String coachId, CoachPermission p, bool value) {
    final current = state.byCoach[coachId] ?? CoachPermissions.none;
    state = CoachPermissionsState(
      loaded: true,
      byCoach: {...state.byCoach, coachId: current.withPermission(p, value)},
    );
  }

  void clear() => state = const CoachPermissionsState();
}

final coachPermissionsProvider =
    NotifierProvider<CoachPermissionsNotifier, CoachPermissionsState>(CoachPermissionsNotifier.new);

/// Whether the signed-in person may do [p]. The owner always may.
final coachCanProvider = Provider.family<bool, CoachPermission>((ref, p) {
  final auth = ref.watch(trainerAuthProvider);
  if (auth == null || auth == "owner") return true;
  final state = ref.watch(coachPermissionsProvider);
  if (!state.loaded) return true;
  return (state.byCoach[auth] ?? CoachPermissions.none).allows(p);
});

/// One coach's switches, for the owner's Staff page. A coach not in the map
/// has everything off.
final coachPermissionsForProvider = Provider.family<CoachPermissions, String>((ref, coachId) {
  return ref.watch(coachPermissionsProvider).byCoach[coachId] ?? CoachPermissions.none;
});

// ---------------------------------------------------------------------------
// Reports: the same reports for everyone, scoped to the viewer.
// ---------------------------------------------------------------------------

/// Sessions a coach ran and the clients they booked or served, straight from
/// the server's own filter (coach_report_bookings / coach_report_client_ids),
/// so a coach's report never holds anyone else's sessions. Not assigned
/// clients: no coach-client assignment is read anywhere.
class CoachReportData {
  const CoachReportData({this.bookings = const [], this.clientIds = const {}});
  final List<Booking> bookings;
  final Set<String> clientIds;
}

final coachReportDataProvider = FutureProvider<CoachReportData>((ref) async {
  final results = await Future.wait([
    SupabaseService.loadCoachReportBookings(),
    SupabaseService.loadCoachReportClientIds(),
  ]);
  return CoachReportData(
    bookings: results[0] as List<Booking>,
    clientIds: results[1] as Set<String>,
  );
});

bool _isOwnerView(String? auth) => auth == null || auth == "owner";

/// Whether revenue figures may show in reports: the owner always, a coach
/// only with "See own revenue" on.
final reportRevenueVisibleProvider = Provider<bool>((ref) => ref.watch(coachCanProvider(CoachPermission.seeOwnRevenue)));

final reportBookingsProvider = Provider<List<Booking>>((ref) {
  final auth = ref.watch(trainerAuthProvider);
  if (_isOwnerView(auth)) return ref.watch(allBookingsProvider);
  return ref.watch(coachReportDataProvider).asData?.value.bookings ?? const [];
});

final reportRosterProvider = Provider<List<ClientInfo>>((ref) {
  final auth = ref.watch(trainerAuthProvider);
  final roster = ref.watch(trainerRosterProvider);
  if (_isOwnerView(auth)) return roster;
  final ids = ref.watch(coachReportDataProvider).asData?.value.clientIds ?? const <String>{};
  return roster.where((c) => ids.contains(c.id)).toList();
});

/// A coach's reports list only themselves.
final reportTrainersProvider = Provider<List<Trainer>>((ref) {
  final auth = ref.watch(trainerAuthProvider);
  final all = ref.watch(trainersProvider);
  if (_isOwnerView(auth)) return all;
  return all.where((t) => t.id == auth).toList();
});

/// Charges: the owner sees all. A coach sees only their own, and only with
/// "See own revenue" on (the database applies the same rule).
final reportChargesProvider = Provider<List<Charge>>((ref) {
  final auth = ref.watch(trainerAuthProvider);
  final all = ref.watch(chargesProvider);
  if (_isOwnerView(auth)) return all;
  if (!ref.watch(reportRevenueVisibleProvider)) return const [];
  return all.where((c) => c.trainerId == auth).toList();
});

final reportLedgerProvider = Provider<List<PointsLedgerEntry>>((ref) {
  final auth = ref.watch(trainerAuthProvider);
  final all = ref.watch(pointsLedgerProvider);
  if (_isOwnerView(auth)) return all;
  final ids = ref.watch(coachReportDataProvider).asData?.value.clientIds ?? const <String>{};
  return all.where((e) => ids.contains(e.clientId)).toList();
});

final reportCoachBadgesProvider = Provider<List<CoachMeritBadge>>((ref) {
  final auth = ref.watch(trainerAuthProvider);
  final all = ref.watch(coachMeritBadgesProvider);
  if (_isOwnerView(auth)) return all;
  if (!ref.watch(reportRevenueVisibleProvider)) return const [];
  return all.where((b) => b.trainerId == auth).toList();
});
