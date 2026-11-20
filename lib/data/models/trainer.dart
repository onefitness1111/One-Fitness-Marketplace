import "../../core/utils/coach_names.dart";
import "../../core/utils/offered_catalog.dart";
import "availability_block.dart";

/// A single entry in a trainer's `locations` jsonb list (real schema —
/// see supabaseData.js `trainerRowToApp`/`trainerFieldsToRow`).
class TrainerLocation {
  const TrainerLocation({
    required this.id,
    required this.name,
    this.address,
    this.hint,
    this.lat,
    this.lng,
  });

  final String id;
  final String name;
  final String? address;
  final String? hint;

  /// Coordinates for [address], the same role they play on GymLocation.
  ///
  /// Without these a coach's own location could be shown to a client but
  /// never measured, so a session run from it sorted last and showed no
  /// distance — the one case where "sessions near me" quietly stopped
  /// working. Set by the map picker, or geocoded from the address.
  final double? lat;
  final double? lng;

  bool get hasCoords => lat != null && lng != null;

  TrainerLocation copyWith({
    String? name,
    String? address,
    String? hint,
    double? lat,
    double? lng,
  }) =>
      TrainerLocation(
        id: id,
        name: name ?? this.name,
        address: address ?? this.address,
        hint: hint ?? this.hint,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
      );
}

/// One before/after transformation-photo pair, as stored in the trainer's
/// `before_afters` jsonb column. Either side may be null/empty.
class TrainerBeforeAfter {
  const TrainerBeforeAfter({required this.id, this.left, this.right});

  final String id;
  final String? left;
  final String? right;
}

/// Whether two before/after lists hold the same photos in the same order —
/// a profile save skips re-uploading them (the bulk of the request) when
/// nothing about them changed.
bool sameBeforeAfters(List<TrainerBeforeAfter> a, List<TrainerBeforeAfter> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id || a[i].left != b[i].left || a[i].right != b[i].right) return false;
  }
  return true;
}

/// A block of time this coach won't be working. Stored on the trainer's
/// `unavailability` jsonb column.
///
/// A blank end date is stored as the same day as [startDate]. Entries written
/// before times existed have no [startMin]/[endMin] and cover the whole day,
/// and their [note] is the reason clients see.
///
/// [allDay] true, or no times at all, blocks every slot that day. Otherwise
/// the minutes apply on each day from [startDate] through [endDate]:
/// a start with no end runs through the end of that day, and a start plus
/// an end is that same range on every day.
class TrainerUnavailability {
  const TrainerUnavailability({
    required this.id,
    required this.startDate,
    required this.endDate,
    this.note,
    this.allDay,
    this.startMin,
    this.endMin,
    this.reason,
    this.clientNote,
  });

  final String id;
  final String startDate; // ISO yyyy-MM-dd
  final String endDate; // ISO yyyy-MM-dd — same as startDate for a single day

  /// Older rows stored the reason here. New rows still write it so an old
  /// build keeps showing something, and also write [reason].
  final String? note;

  /// Null on rows saved before the time toggle existed.
  final bool? allDay;

  /// Minutes from midnight. Null with [endMin] null means the whole day.
  final int? startMin;

  /// Null when the block runs from [startMin] through the end of the day.
  final int? endMin;

  /// Short reason clients see. Falls back to [note] on older rows.
  final String? reason;

  /// What the coach says in chat to clients whose sessions were cancelled.
  /// Not a legal name, and not shown on the public coach card.
  final String? clientNote;

  /// Whole calendar days. A legacy row (no times) is all day even when
  /// [allDay] was never stored.
  bool get blocksWholeDay {
    if (allDay == true) return true;
    if (startMin == null && endMin == null) return true;
    return false;
  }

  /// The reason a client is allowed to see. Blank when the coach left none.
  String get displayReason {
    final chosen = (reason ?? "").trim();
    if (chosen.isNotEmpty) return chosen;
    return (note ?? "").trim();
  }

  factory TrainerUnavailability.fromJson(Map<dynamic, dynamic> e) {
    final start = (e["startDate"] ?? "").toString();
    return TrainerUnavailability(
      id: (e["id"] ?? "").toString(),
      startDate: start,
      endDate: (e["endDate"] ?? start).toString(),
      note: e["note"] as String?,
      allDay: e["allDay"] is bool ? e["allDay"] as bool : null,
      startMin: (e["startMin"] as num?)?.toInt(),
      endMin: (e["endMin"] as num?)?.toInt(),
      reason: e["reason"] as String?,
      clientNote: e["clientNote"] as String?,
    );
  }

  /// Only the fields clients and the next save need. [note] repeats the
  /// reason so an older app still has a label. No legal name is written.
  Map<String, dynamic> toJson() {
    final why = displayReason;
    return {
      "id": id,
      "startDate": startDate,
      "endDate": endDate,
      "allDay": blocksWholeDay,
      if (!blocksWholeDay && startMin != null) "startMin": startMin,
      if (!blocksWholeDay && endMin != null) "endMin": endMin,
      if (why.isNotEmpty) "note": why,
      if (why.isNotEmpty) "reason": why,
      if ((clientNote ?? "").trim().isNotEmpty) "clientNote": clientNote!.trim(),
    };
  }
}

/// Mirrors a trainer/coach record (App.jsx `trainers`) — trimmed to the
/// fields the client-facing Chat and Booking screens need.
class Trainer {
  const Trainer({
    required this.id,
    required this.name,
    this.title,
    this.photo,
    this.phone,
    this.email,
    this.locationName,
    this.locationAddress,
    this.locations = const [],
    this.bio,
    this.beforeAfters = const [],
    this.availability = const [],
    this.commissionRate = 0,
    this.disciplines = const [],
    this.sessionTypes = const [],
    this.reviewedByOwner = true,
    this.signupAt,
    this.payoutMode = "perSession",
    this.payoutRateCents = 0,
    this.referralCommissionPercent = 0,
    this.coachCode,
    this.unavailability = const [],
    this.coachName,
    this.secondaryCoachName,
    this.firstName,
    this.lastName,
  });

  final String id;

  /// Legal name. Clients and other coaches never receive this — the server
  /// replaces it with [coachName] before it leaves the database. The owner
  /// still sees it.
  final String name;

  /// [availability] minus anything the owner deleted from the catalogue
  /// (Customize Platform → Services) — what the app should show and offer.
  /// The saved [availability] itself is left untouched, so the coach's own
  /// editor still has the full record.
  List<AvailabilityBlock> get offeredAvailability =>
      availability.where((b) => LiveCatalog.offers(b.sessionType, b.discipline)).toList();

  /// [disciplines] still offered by the gym.
  List<String> get offeredDisciplines => disciplines.where(LiveCatalog.offersDiscipline).toList();

  /// [sessionTypes] still offered by the gym.
  List<String> get offeredSessionTypes => sessionTypes.where(LiveCatalog.offersType).toList();

  /// Keeps this coach's profile and swaps in pay fields from [source].
  /// Used when a fresh directory load must not wipe rates already on screen.
  Trainer withPayFrom(Trainer source) => Trainer(
        id: id,
        name: name,
        title: title,
        photo: photo,
        phone: phone,
        email: email,
        locationName: locationName,
        locationAddress: locationAddress,
        locations: locations,
        bio: bio,
        beforeAfters: beforeAfters,
        availability: availability,
        commissionRate: source.commissionRate,
        disciplines: disciplines,
        sessionTypes: sessionTypes,
        reviewedByOwner: reviewedByOwner,
        signupAt: signupAt,
        payoutMode: source.payoutMode,
        payoutRateCents: source.payoutRateCents,
        referralCommissionPercent: source.referralCommissionPercent,
        coachCode: coachCode,
        unavailability: unavailability,
        coachName: coachName,
        secondaryCoachName: secondaryCoachName,
        firstName: firstName,
        lastName: lastName,
      );

  /// Only availability is routinely replaced in place (the owner creating
  /// a one-off session, a coach editing their week); everything else goes
  /// through the full edit form, which rebuilds the whole object.
  Trainer copyWith({
    List<AvailabilityBlock>? availability,
    List<TrainerUnavailability>? unavailability,
  }) => Trainer(
        id: id,
        name: name,
        title: title,
        photo: photo,
        phone: phone,
        email: email,
        locationName: locationName,
        locationAddress: locationAddress,
        locations: locations,
        bio: bio,
        beforeAfters: beforeAfters,
        availability: availability ?? this.availability,
        commissionRate: commissionRate,
        disciplines: disciplines,
        sessionTypes: sessionTypes,
        reviewedByOwner: reviewedByOwner,
        signupAt: signupAt,
        payoutMode: payoutMode,
        payoutRateCents: payoutRateCents,
        referralCommissionPercent: referralCommissionPercent,
        coachCode: coachCode,
        unavailability: unavailability ?? this.unavailability,
        coachName: coachName,
        secondaryCoachName: secondaryCoachName,
        firstName: firstName,
        lastName: lastName,
      );

  /// What the coach typed as their coach name, for example "Coach Chris".
  final String? coachName;

  /// Only the owner (and the coach, on their own profile) can see this.
  final String? secondaryCoachName;

  /// Legal first and last name. Null on any phone that is not the owner's
  /// or this coach's own.
  final String? firstName;
  final String? lastName;

  /// Kept for older rows. Clients do not see it; [displayTitle] is the
  /// coach name.
  final String? title;
  final String? photo;
  final String? phone;
  final String? email;
  final String? locationName;

  /// The only name a client or another coach should see.
  String get displayTitle => coachPublicName(coachName: coachName);

  /// Legal name plus the public coach name, for the owner only.
  String get ownerNameLine {
    final legal = name.trim();
    final coach = displayTitle;
    final second = (secondaryCoachName ?? "").trim();
    final parts = <String>[
      if (legal.isNotEmpty) legal,
      if (coach.isNotEmpty && coach != legal) coach,
      if (second.isNotEmpty) second,
    ];
    return parts.join(" · ");
  }
  final String? locationAddress;

  /// Real, directly-stored columns — NOT derived from [availability]'s
  /// blocks (mirrors `trainerDisciplines`/`trainerSessionTypes` in
  /// schedulingHelpers.js, which read `t.disciplines`/`t.sessionTypes`
  /// directly). A coach can select a discipline/session type before ever
  /// adding an availability block for it.
  final List<String> disciplines;
  final List<String> sessionTypes;

  /// Full `locations` list (the real schema supports more than one; the
  /// app's own edit form only ever writes a single entry, but a coach's
  /// row may carry more if edited elsewhere).
  final List<TrainerLocation> locations;

  final String? bio;
  final List<TrainerBeforeAfter> beforeAfters;
  final List<AvailabilityBlock> availability;

  /// Time off — see [TrainerUnavailability]. Distinct from [availability]'s
  /// weekly recurring blocks: calendar dates, and on a partial day only the
  /// minutes that overlap. Saving a new entry cancels sessions that overlap
  /// it. Checked at slot-generation time (booking_utils.dart's
  /// fallsInUnavailability).
  final List<TrainerUnavailability> unavailability;

  /// Percent (e.g. 20 = 20%) of session revenue paid to this coach — legacy
  /// field, no longer read by payroll math (see [payoutMode]/
  /// [payoutRateCents]). Left in the model/DB rather than removed since
  /// dropping a column is destructive and this app never reads it anymore.
  final num commissionRate;

  /// False only for a coach who self-signed-up with an approval code and
  /// hasn't yet been opened by the owner on Coaches Overview (mirrors
  /// CoachesOverview.jsx's "New" badge / `reviewedByOwner === false`).
  /// Owner-added coaches (Staff → +Trainer) start `true` — no review needed.
  final bool reviewedByOwner;

  /// ISO date the coach self-signed-up, if they did (null for owner-added
  /// coaches) — shown in the expanded Coaches Overview card.
  final String? signupAt;

  /// "perClient" | "perHour" | "perSession" — owner picks exactly one mode
  /// per coach; [payoutRateCents] is that mode's $ rate (cents). Replaces
  /// [commissionRate] as the real payroll source of truth — see
  /// report_utils.dart's TrainerRangeStats.
  final String payoutMode;
  final int payoutRateCents;

  /// Percent of every membership/package purchase made by a client this
  /// coach referred (via [coachCode]) — charged to the client as a
  /// surcharge on top of the listed price, credited to this coach as a
  /// `charges` row (category "referral_commission"). Independent of
  /// [payoutMode]/[payoutRateCents] — a second, separate income stream.
  final num referralCommissionPercent;

  /// Unique, set once at signup (self-signup or owner-added), never
  /// editable afterward — a client entering this at their own signup links
  /// to this coach (see clients.referred_by_trainer_id) and becomes their
  /// primary client. Null for a coach created before this feature shipped.
  final String? coachCode;
}
