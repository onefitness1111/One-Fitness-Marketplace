/// Mirrors a booking record in App.jsx `bookings`.
class Booking {
  const Booking({
    required this.id,
    required this.clientId,
    required this.trainerId,
    required this.date, // ISO yyyy-MM-dd
    required this.slot, // minutes from midnight
    required this.sessionType,
    required this.discipline,
    this.status = "confirmed",
    this.attendanceStatus,
    this.clientStartedAt,
    this.locationName,
    this.isPhysicalAssessment = false,
    this.overriddenBy,
    this.overriddenAt,
    this.overrideReason,
    this.planId,
    this.durationMin = 60,
    this.countsTowardPay = true,
  });

  final String id;
  final String clientId;
  final String trainerId;
  final String date;
  final int slot;
  final String sessionType;
  final String discipline;
  final String status;
  final String? attendanceStatus; // checked-in | no-show | ...

  /// Set only when the CLIENT started this session themselves, early, from
  /// their own dashboard. A coach marking attendance does not set this.
  ///
  /// The coach's own Start Session button is a different gate: a checked-in
  /// attendance on this booking does unlock that slot (see sessionMayStart).
  final String? clientStartedAt;

  bool get clientStartedEarly => clientStartedAt != null;
  final String? locationName;
  final bool isPhysicalAssessment;

  /// Set only when an owner pushed a booking past a real conflict or a full
  /// class. The live trigger allows the insert when [overriddenBy] is set
  /// and the caller really is the owner. [overrideReason] starts with
  /// "conflict" or "capacity" and then names what was in the way.
  final String? overriddenBy;
  final String? overriddenAt;
  final String? overrideReason;

  /// The held plan whose session this booking used — chosen by
  /// canBookOffering at booking time. A client can hold a membership and
  /// several packages together, so usage is attributed per plan rather than
  /// inferred from the session type. Null for rows made before this existed.
  final String? planId;

  /// Minutes the session runs. 60 unless staff set an end time when booking.
  final int durationMin;

  /// False when the session was comped (a free add). It still shows on the
  /// schedule. It does not count toward that coach's pay.
  final bool countsTowardPay;

  int get endSlot => slot + durationMin;

  Booking copyWith({String? attendanceStatus}) => Booking(
        id: id,
        clientId: clientId,
        trainerId: trainerId,
        date: date,
        slot: slot,
        sessionType: sessionType,
        discipline: discipline,
        status: status,
        attendanceStatus: attendanceStatus,
        clientStartedAt: clientStartedAt,
        locationName: locationName,
        isPhysicalAssessment: isPhysicalAssessment,
        overriddenBy: overriddenBy,
        overriddenAt: overriddenAt,
        overrideReason: overrideReason,
        planId: planId,
        durationMin: durationMin,
        countsTowardPay: countsTowardPay,
      );

  /// Stamps the owner override the booking trigger looks for.
  Booking withOwnerOverride(String reason) => Booking(
        id: id,
        clientId: clientId,
        trainerId: trainerId,
        date: date,
        slot: slot,
        sessionType: sessionType,
        discipline: discipline,
        status: status,
        attendanceStatus: attendanceStatus,
        clientStartedAt: clientStartedAt,
        locationName: locationName,
        isPhysicalAssessment: isPhysicalAssessment,
        overriddenBy: "owner",
        overriddenAt: DateTime.now().toUtc().toIso8601String(),
        overrideReason: reason,
        planId: planId,
        durationMin: durationMin,
        countsTowardPay: countsTowardPay,
      );
}
