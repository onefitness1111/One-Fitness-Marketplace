/// Mirrors the web `ClientPlanEnrollment` shape — one entry in `clients.plans`.
class ClientPlanEnrollment {
  const ClientPlanEnrollment({
    required this.planId,
    required this.status,
    required this.startDate,
    this.termMonths,
    this.subscriptionId,
    this.cancelsAt,
    this.rolloverSessions = 0,
    this.rolloverMonth,
    this.endsAt,
    this.priceCents,
    this.maxSessionsOverride,
    this.maxSessionsOverrideMonth,
    this.rolloverMaxOverride,
    this.heldSessions,
    this.frozenFrom,
    this.heldFrom,
    this.heldUntil,
  });

  final String planId;
  final String status; // active | cancelled | ...
  final String startDate; // ISO yyyy-MM-dd
  final int? termMonths;

  /// The Stripe subscription this plan renews on — set for a paid
  /// membership, so each one a client holds renews and cancels on its own.
  final String? subscriptionId;

  /// Set once the client cancels a paid plan: it stays usable until this
  /// date (what's already paid for), then ends.
  final String? cancelsAt;

  /// Sessions carried over from the previous month, under the plan's
  /// roll-over rule (Plans → Advanced → roll over). They're added to this
  /// month's allowance and expire with it.
  final int rolloverSessions;

  /// The "YYYY-MM" [rolloverSessions] belongs to — a carry-over is good for
  /// that one month only, never stacked month after month.
  final String? rolloverMonth;

  /// Set when the client switched to a different plan: the old plan's
  /// remaining sessions stay usable until this date, but it doesn't renew.
  final String? endsAt;

  /// Owner-set price for this client only (cents); null = the plan's list price.
  final int? priceCents;

  /// This client's session allowance for this plan only. Null uses the
  /// membership's own count. A membership stamps [maxSessionsOverrideMonth]
  /// so the number lasts that month; a package leaves the month empty and
  /// the number stays until someone clears it.
  final int? maxSessionsOverride;
  final String? maxSessionsOverrideMonth;

  /// How many unused sessions this client may roll into next month on this
  /// plan. Null uses the membership's limit. 0 means none, for this client
  /// only.
  final int? rolloverMaxOverride;

  /// Unused sessions kept through the last freeze on this membership,
  /// written when the freeze started. They can be used from [heldFrom] (the
  /// freeze's end day) up to, not including, [heldUntil] (the next billing
  /// day). During that window they replace the monthly count; rolled-over
  /// sessions for the month still count on top and still expire with it.
  final int? heldSessions;

  /// First frozen day of the last freeze. With [heldUntil] it marks the
  /// months no sessions roll over from.
  final String? frozenFrom;
  final String? heldFrom;
  final String? heldUntil;

  /// True when [today] ("YYYY-MM-DD") is in the held-sessions window.
  bool holdActiveOn(String today) =>
      heldSessions != null &&
      heldFrom != null &&
      heldUntil != null &&
      today.compareTo(heldFrom!) >= 0 &&
      today.compareTo(heldUntil!) < 0;

  /// True when [date] falls in the held-sessions window, active or not.
  bool inHoldWindow(String date) =>
      heldFrom != null &&
      heldUntil != null &&
      date.compareTo(heldFrom!) >= 0 &&
      date.compareTo(heldUntil!) < 0;

  ClientPlanEnrollment copyWith({
    String? status,
    String? cancelsAt,
    bool clearCancelsAt = false,
    int? rolloverSessions,
    String? rolloverMonth,
    String? endsAt,
    bool clearEndsAt = false,
    int? priceCents,
    bool clearPrice = false,
    int? maxSessionsOverride,
    String? maxSessionsOverrideMonth,
    bool clearMaxSessionsOverride = false,
    int? rolloverMaxOverride,
    bool clearRolloverMaxOverride = false,
  }) =>
      ClientPlanEnrollment(
        planId: planId,
        status: status ?? this.status,
        startDate: startDate,
        termMonths: termMonths,
        subscriptionId: subscriptionId,
        cancelsAt: clearCancelsAt ? null : (cancelsAt ?? this.cancelsAt),
        rolloverSessions: rolloverSessions ?? this.rolloverSessions,
        rolloverMonth: rolloverMonth ?? this.rolloverMonth,
        endsAt: clearEndsAt ? null : (endsAt ?? this.endsAt),
        priceCents: clearPrice ? null : (priceCents ?? this.priceCents),
        maxSessionsOverride: clearMaxSessionsOverride ? null : (maxSessionsOverride ?? this.maxSessionsOverride),
        maxSessionsOverrideMonth: clearMaxSessionsOverride ? null : (maxSessionsOverrideMonth ?? this.maxSessionsOverrideMonth),
        rolloverMaxOverride: clearRolloverMaxOverride ? null : (rolloverMaxOverride ?? this.rolloverMaxOverride),
        heldSessions: heldSessions,
        frozenFrom: frozenFrom,
        heldFrom: heldFrom,
        heldUntil: heldUntil,
      );

  Map<String, dynamic> toJson() => {
        "planId": planId,
        "status": status,
        "startDate": startDate,
        if (termMonths != null) "termMonths": termMonths,
        if (subscriptionId != null) "subscriptionId": subscriptionId,
        if (cancelsAt != null) "cancelsAt": cancelsAt,
        if (rolloverSessions != 0) "rolloverSessions": rolloverSessions,
        if (rolloverMonth != null) "rolloverMonth": rolloverMonth,
        if (endsAt != null) "endsAt": endsAt,
        if (priceCents != null) "priceCents": priceCents,
        if (maxSessionsOverride != null) "maxSessionsOverride": maxSessionsOverride,
        if (maxSessionsOverrideMonth != null) "maxSessionsOverrideMonth": maxSessionsOverrideMonth,
        if (rolloverMaxOverride != null) "rolloverMaxOverride": rolloverMaxOverride,
        if (heldSessions != null) "heldSessions": heldSessions,
        if (frozenFrom != null) "frozenFrom": frozenFrom,
        if (heldFrom != null) "heldFrom": heldFrom,
        if (heldUntil != null) "heldUntil": heldUntil,
      };
}
