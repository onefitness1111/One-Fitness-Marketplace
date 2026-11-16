/// A paid-for single session. One credit = one session, good for 30 days from
/// purchase. It is "used" while [bookingId] is set; cancelling (early or late)
/// frees it again, a no-show forfeits it.
class SingleSessionCredit {
  const SingleSessionCredit({
    required this.id,
    required this.clientId,
    required this.sessionType,
    required this.priceCents,
    required this.status,
    required this.purchasedAt,
    required this.expiresAt,
    this.bookingId,
  });

  final String id;
  final String clientId;
  final String sessionType;
  final int priceCents;
  final String status; // active | refunded
  final DateTime purchasedAt;
  final DateTime expiresAt;
  final String? bookingId;

  /// Not used, not refunded and not past its expiry.
  bool get usable => status == "active" && bookingId == null && expiresAt.isAfter(DateTime.now());

  /// Whether a session on [isoDate] (yyyy-MM-dd) falls within this credit's life.
  bool coversDate(String isoDate) {
    final d = DateTime.tryParse(isoDate);
    return d != null && !d.isAfter(expiresAt);
  }

  factory SingleSessionCredit.fromRow(Map<String, dynamic> r) => SingleSessionCredit(
        id: r["id"].toString(),
        clientId: r["client_id"].toString(),
        sessionType: r["session_type"]?.toString() ?? "",
        priceCents: (r["price_cents"] as num?)?.toInt() ?? 0,
        status: r["status"]?.toString() ?? "active",
        bookingId: r["booking_id"]?.toString(),
        purchasedAt: DateTime.tryParse(r["purchased_at"]?.toString() ?? "")?.toLocal() ?? DateTime.now(),
        expiresAt: DateTime.tryParse(r["expires_at"]?.toString() ?? "")?.toLocal() ?? DateTime.now(),
      );
}

/// What a single-session purchase or staff booking came back with.
class SingleSessionOutcome {
  const SingleSessionOutcome({required this.status, this.bookingId, this.message, this.refunded = false, this.code});

  /// booked | full | error
  final String status;
  final String? bookingId;
  final String? message;
  final bool refunded;
  final String? code;

  bool get booked => status == "booked" && bookingId != null;
  bool get full => status == "full";

  factory SingleSessionOutcome.fromJson(Map<String, dynamic> j) => SingleSessionOutcome(
        status: j["status"]?.toString() ?? "error",
        bookingId: j["bookingId"]?.toString(),
        message: j["message"]?.toString(),
        refunded: j["refunded"] == true,
        code: j["code"]?.toString(),
      );
}
