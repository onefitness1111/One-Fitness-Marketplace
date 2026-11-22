/// Mirrors the shape produced by src/data/membershipPlans.js — trimmed to the
/// fields the client-facing screens actually read.
///
/// [program] is the personalized *training* program; [nutritionProgram] is
/// the nutrition-only one. They're separate kinds rather than one "program"
/// bucket because they unlock different intake forms — see
/// intake_entitlements.dart — and a client can hold either, both, or neither.
enum PlanKind { membership, package, program, nutritionProgram }

/// What the client sees for each kind. "Program" alone was ambiguous once a
/// second program type existed.
String planKindLabel(PlanKind k) => switch (k) {
  PlanKind.membership => "Membership",
  PlanKind.package => "Package",
  PlanKind.program => "Personalized Program",
  PlanKind.nutritionProgram => "Nutrition Program",
};

/// Neither program kind is a membership or a session package — they grant
/// programming, not gym access or a session balance. Grouped here so the
/// several places that need "is this a program?" don't each re-list the
/// kinds and then get missed when another is added.
bool isProgramKind(PlanKind k) => k == PlanKind.program || k == PlanKind.nutritionProgram;

/// Where a plan sits for selling.
///
/// Active is on the client storefront. Ghost is hidden from clients and
/// still assignable by the owner and coaches. Archived is closed to new
/// sales. People already on a plan keep it in every state.
enum PlanStatus { active, ghost, archived }

/// [status] wins when it is one of the three names. Older rows only have
/// the archived flag: true is archived, anything else is active.
PlanStatus resolvePlanStatus(Object? raw, {bool archived = false}) {
  final value = raw is String ? raw.trim().toLowerCase() : "";
  return switch (value) {
    "active" => PlanStatus.active,
    "ghost" => PlanStatus.ghost,
    "archived" => PlanStatus.archived,
    _ => archived ? PlanStatus.archived : PlanStatus.active,
  };
}

/// Client storefront and plan lists. A ghost plan is not here, even when
/// the client already holds it — that plan is shown from their own record.
bool planInClientCatalog(MembershipPlan plan) => plan.status == PlanStatus.active;

/// Staff pickers. Ghost stays assignable. Archived does not.
bool planAssignableByStaff(MembershipPlan plan) => plan.status != PlanStatus.archived;

/// Adds ghost plans the caller already holds onto a catalog that omitted
/// them. A plan already in [catalog] is left as it is.
List<MembershipPlan> mergeHeldGhostPlans(List<MembershipPlan> catalog, List<MembershipPlan> held) {
  if (held.isEmpty) return catalog;
  final seen = {for (final plan in catalog) plan.id};
  final extra = [
    for (final plan in held)
      if (plan.status == PlanStatus.ghost && seen.add(plan.id)) plan,
  ];
  if (extra.isEmpty) return catalog;
  return [...catalog, ...extra];
}

/// Same merge for the raw `id` + `data` rows, before they are parsed.
List<Map<String, dynamic>> mergeHeldGhostRows(
  List<Map<String, dynamic>> catalog,
  List<Map<String, dynamic>> held,
) {
  if (held.isEmpty) return catalog;
  final seen = {for (final row in catalog) row["id"]?.toString()};
  final extra = [
    for (final row in held)
      if (!seen.contains(row["id"]?.toString()) && _rowIsGhost(row)) row,
  ];
  if (extra.isEmpty) return catalog;
  return [...catalog, ...extra];
}

bool _rowIsGhost(Map<String, dynamic> row) {
  final data = row["data"];
  if (data is! Map) return false;
  return resolvePlanStatus(data["status"], archived: data["archived"] == true) == PlanStatus.ghost;
}

class MembershipPlan {
  const MembershipPlan({
    required this.id,
    required this.name,
    required this.kind,
    this.description,
    this.startDate,
    this.endDate,
    this.renewalDay,
    this.maxSessions,
    this.termMonths,
    this.allowedTypes = const [],
    this.priceCents = 0,
    PlanStatus? status,
    bool archived = false,
    this.paymentType,
    this.feeItemProductId,
    this.category,
    this.sortOrder,
    this.allowGuests = false,
    this.guestFeeCents = 0,
    this.rolloverEnabled = false,
    this.rolloverMaxVisits = 0,
    this.cancellationNoticeDays = 0,
    this.earlyTerminationFeeCents = 0,
    this.serviceBalanceEnabled = false,
    this.sharingEnabled = false,
    this.sharingMaxAccounts = 1,
    this.public = true,
    this.limitOnePerAccount = false,
    this.expirationEnabled = false,
    this.expirationDays,
  })  : status = status ?? (archived ? PlanStatus.archived : PlanStatus.active),
        archived = (status ?? (archived ? PlanStatus.archived : PlanStatus.active)) == PlanStatus.archived;

  final String id;
  final String name;
  final PlanKind kind;
  final int? maxSessions;
  final int? termMonths;
  final List<String> allowedTypes;

  /// Cents — "/mo" for membership plans, a flat one-time price for
  /// package/program plans. Drives Reports' revenue/payroll math.
  final int priceCents;

  /// Active, ghost, or archived. The archived flag below follows this.
  final PlanStatus status;

  /// True only when [status] is archived. Ghost plans are not archived:
  /// billing, sessions, and rollover keep running, and staff can still
  /// assign the plan. Older code that only knows this flag treats ghost
  /// as a normal live plan, which is why clients are also blocked in the
  /// database.
  final bool archived;

  /// "subscription" | "one-time" | null. Plans created before this field
  /// existed have neither — see [effectivePaymentType].
  final String? paymentType;

  /// A one-time package's linked Fee Item (Product id) — set via Package
  /// Setup's "Fee Item" picker. Referenced by ManageProducts.jsx's
  /// delete-guard: a product this points to gets archived, not deleted.
  final String? feeItemProductId;

  /// package_categories entry this plan is grouped under (Products/plan
  /// pickers share the same catalog — see packageCategoriesProvider).
  final String? category;

  /// Where this plan sits in the owner's chosen order, within its category.
  ///
  /// Carried on the plan itself because `membership_plans` is an id/jsonb
  /// table with nothing else to hang order on, and `loadMembershipPlans`
  /// selects with no `order by` — so before this field the Access Hub's
  /// up/down arrows rearranged the list in memory and the next load came
  /// back in whatever order Postgres felt like. Null on plans saved before
  /// this existed; those sort after the ordered ones, by name.
  final int? sortOrder;

  /// What the client is actually buying, in their words rather than a
  /// feature list — shown on the plan card and the detail view.
  final String? description;

  /// ISO yyyy-MM-dd. When this plan starts or becomes available; null means
  /// it simply runs from whenever it is bought, which is the normal case for
  /// an ongoing membership. Mainly for dated offerings — a program that runs
  /// from a fixed start, or a seasonal package.
  final String? startDate;

  /// ISO yyyy-MM-dd. The last day this plan is sold. After it, the plan
  /// disappears from the Access Hub and can no longer be bought or assigned
  /// — but it is NOT a cut-off for people already on it: their access and
  /// their bookings carry on exactly as before, and a membership keeps
  /// renewing. It closes the door, it doesn't empty the room.
  ///
  /// Together with [startDate] this is the window the plan is on sale for;
  /// see `planOnSale`. Null means on sale indefinitely, which is the normal
  /// case.
  final String? endDate;

  /// Memberships only: the day of the month (1–28) every client on this
  /// plan is billed. "Renews on the 21st" — a client who joins on the 10th
  /// pays a prorated amount for the 10th–21st, then the full price on the
  /// 21st each month. Null bills each client on their own signup day.
  /// Capped at 28 so it exists in every month.
  final int? renewalDay;

  // ── PackageSetupModal's Advanced Settings — highest-value subset ──
  // (contract attachment and a couple of lower-value toggles —
  // allowBookingBeyondBillingInterval, includeGuestsInVisitCount — are
  // deliberately not ported; see manage_memberships_screen.dart.)
  final bool allowGuests;

  /// One-time (package) plans only — subscriptions don't charge per-guest.
  final int guestFeeCents;

  /// Subscription (membership) plans only.
  final bool rolloverEnabled;
  final int rolloverMaxVisits;

  /// Subscription (membership) plans only — notice required before
  /// cancelling a renewal without incurring [earlyTerminationFeeCents].
  final int cancellationNoticeDays;
  final int earlyTerminationFeeCents;

  /// One-time (package) plans only.
  final bool serviceBalanceEnabled;

  final bool sharingEnabled;
  final int sharingMaxAccounts;
  final bool public;

  /// One-time (package) plans only.
  final bool limitOnePerAccount;
  final bool expirationEnabled;
  final int? expirationDays;

  /// This plan, filed under [category] (and placed at [sortOrder] within it).
  /// Every other field is carried over unchanged.
  MembershipPlan withCategory(String? category, {int? sortOrder}) => MembershipPlan(
        id: id,
        name: name,
        kind: kind,
        description: description,
        startDate: startDate,
        endDate: endDate,
        renewalDay: renewalDay,
        maxSessions: maxSessions,
        termMonths: termMonths,
        allowedTypes: allowedTypes,
        priceCents: priceCents,
        status: status,
        paymentType: paymentType,
        feeItemProductId: feeItemProductId,
        category: category,
        sortOrder: sortOrder ?? this.sortOrder,
        allowGuests: allowGuests,
        guestFeeCents: guestFeeCents,
        rolloverEnabled: rolloverEnabled,
        rolloverMaxVisits: rolloverMaxVisits,
        cancellationNoticeDays: cancellationNoticeDays,
        earlyTerminationFeeCents: earlyTerminationFeeCents,
        serviceBalanceEnabled: serviceBalanceEnabled,
        sharingEnabled: sharingEnabled,
        sharingMaxAccounts: sharingMaxAccounts,
        public: public,
        limitOnePerAccount: limitOnePerAccount,
        expirationEnabled: expirationEnabled,
        expirationDays: expirationDays,
      );

  /// Same plan, with a new visibility. Every other field stays.
  MembershipPlan copyWith({PlanStatus? status}) => MembershipPlan(
        id: id,
        name: name,
        kind: kind,
        description: description,
        startDate: startDate,
        endDate: endDate,
        renewalDay: renewalDay,
        maxSessions: maxSessions,
        termMonths: termMonths,
        allowedTypes: allowedTypes,
        priceCents: priceCents,
        status: status ?? this.status,
        paymentType: paymentType,
        feeItemProductId: feeItemProductId,
        category: category,
        sortOrder: sortOrder,
        allowGuests: allowGuests,
        guestFeeCents: guestFeeCents,
        rolloverEnabled: rolloverEnabled,
        rolloverMaxVisits: rolloverMaxVisits,
        cancellationNoticeDays: cancellationNoticeDays,
        earlyTerminationFeeCents: earlyTerminationFeeCents,
        serviceBalanceEnabled: serviceBalanceEnabled,
        sharingEnabled: sharingEnabled,
        sharingMaxAccounts: sharingMaxAccounts,
        public: public,
        limitOnePerAccount: limitOnePerAccount,
        expirationEnabled: expirationEnabled,
        expirationDays: expirationDays,
      );
}

/// Mirrors membershipPlans.js `planPaymentType`, extended for programs.
///
/// Programs are always one-time, even if a plan row says otherwise: the
/// subscription slot on a client (`stripe_subscription_id`) belongs to their
/// membership, and cancel/change/freeze all operate on it. A recurring
/// program would either have to steal that slot — taking the membership's
/// billing controls with it — or bill forever with nothing in the app able to
/// stop it. Kept in sync with create-checkout-session, which enforces the
/// same rule server-side where the real charge is made.
String effectivePaymentType(MembershipPlan p) =>
    isProgramKind(p.kind) ? "one-time" : (p.paymentType ?? (p.kind == PlanKind.package ? "one-time" : "subscription"));
