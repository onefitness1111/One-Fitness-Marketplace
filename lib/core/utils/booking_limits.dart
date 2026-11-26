import "package:supabase_flutter/supabase_flutter.dart"
    show FunctionException, PostgrestException;

import "../payments/outstanding_balance.dart";
import "date_utils.dart";

/// How the live `enforce_booking_limits` trigger refused an insert.
///
/// That trigger is not in this repo. It raises one of:
/// "This coach already has a session that overlaps this time slot."
/// "This session is already at capacity (n/n)."
/// Overlap means the same coach and date and a start under 60 minutes
/// away, and it does not include the shared session being joined (identical
/// start, type, and discipline). An owner insert with `overridden_by` set
/// is let through.
enum BookingLimitKind { overlap, capacity }

/// What a coach sees. An owner is asked before these are the last word.
const coachOverlapRefusal = "This coach already has a session at that time.";
const coachCapacityRefusal = "That session is full.";

/// Only when the request never reached the server.
const bookingConnectionMessage =
    "Couldn't book that session — check your connection and try again.";

/// Clients never see another client's name, and never a coach's legal name.
const clientOverlapRefusal =
    "This coach was just booked for another session at that time. Please pick another time.";
const clientCapacityRefusal =
    "That session just filled up. Pick another time, or join the waitlist.";

/// Both ways a swallowed single-session refusal can read, when the function
/// reports "full" and drops the trigger sentence.
const ownerUnspecifiedLimitMessage =
    "That time didn't go through. This coach already has a session then, or the class is full. Book anyway?";

String bookingErrorText(Object error) {
  if (error is PostgrestException) {
    return [
      error.message,
      if (error.details != null) error.details.toString(),
      if (error.hint != null && error.hint!.trim().isNotEmpty) error.hint!,
    ].join(" ");
  }
  return error.toString();
}

/// Null when [error] is not the booking-limit trigger.
BookingLimitKind? classifyBookingLimitError(Object error) {
  final text = bookingErrorText(error).toLowerCase();
  if (text.contains("overlaps this time slot")) return BookingLimitKind.overlap;
  if (text.contains("already at capacity")) return BookingLimitKind.capacity;
  return null;
}

/// The block_frozen_client_booking sentence, when that is why a booking
/// was refused. It names the day booking opens again. Null otherwise.
String? frozenSentence(Object error) {
  final text = bookingErrorText(error);
  final match = RegExp(r"(Your|This client's) account is frozen[^.]*\.(\s*(You can book sessions starting that day|They can be booked starting that day|Message ONE Fitness to resume it)\.)?")
      .firstMatch(text);
  return match?.group(0);
}

/// True for a dropped socket, a timeout, or a host that never answered.
/// A Postgres refusal is not one of these, even if its text mentions a
/// connection — the server did answer.
bool isBookingNetworkError(Object error) {
  if (error is PostgrestException || error is FunctionException) return false;
  final lower = error.toString().toLowerCase();
  return lower.contains("socketexception") ||
      lower.contains("clientexception") ||
      lower.contains("handshakeexception") ||
      lower.contains("failed host lookup") ||
      lower.contains("timed out") ||
      lower.contains("timeoutexception") ||
      lower.contains("connection refused") ||
      lower.contains("connection reset") ||
      lower.contains("connection abort") ||
      lower.contains("connection closed") ||
      lower.contains("network is unreachable") ||
      lower.contains("networkexception") ||
      lower.contains("connection");
}

/// (count, cap) parsed from "already at capacity (4/4)".
(int, int)? capacityPairFromError(Object error) {
  final match = RegExp(
    r"already at capacity \((\d+)\s*/\s*(\d+)\)",
    caseSensitive: false,
  ).firstMatch(bookingErrorText(error));
  if (match == null) return null;
  return (int.parse(match.group(1)!), int.parse(match.group(2)!));
}

/// The sentence under a failed Book for someone who cannot override.
String staffBookingFailureMessage(
  Object error, {
  String whatFailed = "Couldn't book that session",
}) {
  final frozen = frozenSentence(error);
  if (frozen != null) return frozen;
  switch (classifyBookingLimitError(error)) {
    case BookingLimitKind.overlap:
      return coachOverlapRefusal;
    case BookingLimitKind.capacity:
      return coachCapacityRefusal;
    case null:
      break;
  }
  if (isBookingNetworkError(error)) {
    return whatFailed == "Couldn't book that session"
        ? bookingConnectionMessage
        : "$whatFailed — check your connection and try again.";
  }
  final plain = _plainServerSentence(error);
  if (plain.isNotEmpty) return plain;
  return "$whatFailed. Please try again.";
}

/// A drag that the server refused. The original booking is still where it was.
String moveFailureMessage(Object error, {required String whatFailed}) {
  final frozen = frozenSentence(error);
  if (frozen != null) return frozen;
  switch (classifyBookingLimitError(error)) {
    case BookingLimitKind.overlap:
      return coachOverlapRefusal;
    case BookingLimitKind.capacity:
      return coachCapacityRefusal;
    case null:
      break;
  }
  if (isBookingNetworkError(error)) {
    return "$whatFailed — check your connection and try again.";
  }
  return "$whatFailed — nothing was changed.";
}

/// Why a client's own booking was refused. No override, and no other
/// client's name — the only person named, when anyone is, is the coach,
/// and only by the public coach name the caller already chose.
String clientBookingErrorMessage(Object error) {
  final text = bookingErrorText(error);
  // The freeze trigger already says when the freeze ends (U14).
  final frozen = frozenSentence(error);
  if (frozen != null) return frozen;
  // Unified unpaid-balance check (O4): BALANCE_DUE and BALANCE_GRACE_USED.
  final balanceMsg = unpaidBalanceErrorMessage(text);
  if (balanceMsg != null) return balanceMsg;
  if (text.contains("waiver-required")) {
    return "Please sign the waiver under Signatures (in the menu) before booking.";
  }
  switch (classifyBookingLimitError(error)) {
    case BookingLimitKind.overlap:
      return clientOverlapRefusal;
    case BookingLimitKind.capacity:
      return clientCapacityRefusal;
    case null:
      break;
  }
  if (text.contains("membership") || text.contains("plan")) {
    return "That session isn't covered by your current plan — see Membership for what each plan covers.";
  }
  if (isBookingNetworkError(error)) return bookingConnectionMessage;
  return "Couldn't book that session. Please try again.";
}

String _coachWords(String coachName) {
  final name = coachName.trim();
  if (name.isEmpty || name == "your coach") return "This coach";
  return name;
}

/// "Coach Chris already has a session at 12:45 PM with Jordan. Book anyway?"
///
/// [clientName] is the name coaches see for the person already in the
/// conflicting session. [conflictSlot] is that session's start, in minutes
/// from midnight. Without a slot, the sentence stays general — the local
/// schedule didn't have the row the server just refused.
String ownerOverlapOverrideMessage({
  required String coachName,
  int? conflictSlot,
  String? clientName,
}) {
  final coach = _coachWords(coachName);
  if (conflictSlot == null) {
    return "$coach already has a session that overlaps this time. Book anyway?";
  }
  final who = (clientName ?? "").trim();
  final withWhom = who.isEmpty ? "" : " with $who";
  return "$coach already has a session at ${fmtSlot(conflictSlot)}$withWhom. Book anyway?";
}

/// Matches the manual-booking capacity prompt: "This session is at capacity
/// (3/4). Add Jordan anyway?"
String ownerCapacityOverrideMessage({
  required String clientName,
  int? count,
  int? cap,
}) {
  final who = clientName.trim().isEmpty ? "this client" : clientName.trim();
  if (count != null && cap != null) {
    return "This session is at capacity ($count/$cap). Add $who anyway?";
  }
  return "That session is full. Add $who anyway?";
}

/// The prompt without its closing question, for `override_reason`.
String overrideDetail(String prompt) => prompt
    .replaceFirst(RegExp(r"\s*Book anyway\?$"), "")
    .replaceFirst(RegExp(r"\s*Add .+ anyway\?$"), "")
    .trim();

/// `conflict` or `capacity`, then the sentence the owner just confirmed.
String overrideReasonFor(BookingLimitKind kind, {String? detail}) {
  final lead = kind == BookingLimitKind.overlap ? "conflict" : "capacity";
  final extra = (detail ?? "").trim();
  if (extra.isEmpty) return lead;
  return "$lead — $extra";
}

String _plainServerSentence(Object error) {
  var text = bookingErrorText(error).trim();
  text = text.replaceFirst(RegExp(r"^Exception:\s*"), "");
  if (text.contains("PostgrestException") || text.contains("FunctionException"))
    return "";
  final lower = text.toLowerCase();
  if (lower.contains("violates") ||
      lower.contains("syntax error") ||
      lower.contains("sqlstate") ||
      lower.contains("pigeon")) {
    return "";
  }
  if (text.isEmpty || text.length > 280) return "";
  return text;
}
