import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/coach/review_prompt.dart";
import "../../../core/motion/client_foreground.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../data/models/booking.dart";
import "../../../data/providers/client_providers.dart";
import "session_rating_card.dart";

typedef ReviewStateLoader = Future<({Set<String> reviewed, List<ReviewDeferral> deferred})> Function();
typedef ReviewSubmitter = Future<void> Function({
  required String bookingId,
  required String trainerId,
  required int stars,
  String? body,
});
typedef ReviewDeferrer = Future<void> Function(String bookingId, String trainerId);

/// Asks once after the newest checked-in session finishes. Coaches and the
/// owner never mount this. It waits if a workout-complete screen is up.
class SessionRatingHost extends ConsumerStatefulWidget {
  const SessionRatingHost({
    super.key,
    @visibleForTesting this.loadState,
    @visibleForTesting this.submitReview,
    @visibleForTesting this.deferReview,
    @visibleForTesting this.now,
    @visibleForTesting this.currentClientId,
  });

  final ReviewStateLoader? loadState;
  final ReviewSubmitter? submitReview;
  final ReviewDeferrer? deferReview;
  final DateTime Function()? now;
  final String? currentClientId;

  @override
  ConsumerState<SessionRatingHost> createState() => _SessionRatingHostState();
}

class _SessionRatingHostState extends ConsumerState<SessionRatingHost> with WidgetsBindingObserver {
  CheckedInSession? _ask;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ClientForeground.blockers.addListener(_onBlock);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ClientForeground.blockers.removeListener(_onBlock);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  void _onBlock() {
    if (ClientForeground.blockers.value == 0) unawaited(_refresh());
    if (mounted) setState(() {});
  }

  String? _resolvedClientId() {
    if (widget.currentClientId != null) return widget.currentClientId;
    try {
      return SupabaseService.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  String _checkedInSignature(List<Booking> bookings) {
    final items = [
      for (final b in bookings)
        if (b.status != "cancelled" && b.attendanceStatus == "checked-in")
          "${b.id}:${b.clientId}:${b.trainerId}:${b.date}:${b.slot}:${b.durationMin}",
    ]..sort();
    return items.join("|");
  }

  Future<void> _refresh() async {
    if (_busy || _ask != null || ClientForeground.blockers.value > 0) return;
    final clientId = _resolvedClientId();
    if (clientId == null || clientId.isEmpty) return;
    _busy = true;
    try {
      final bookings = ref.read(clientBookingsProvider);
      final loader = widget.loadState ?? SupabaseService.loadReviewState;
      final state = await loader();
      final id = nextSessionToRate(
        checkedIn: [
          for (final booking in bookings)
            CheckedInSession(
              bookingId: booking.id,
              trainerId: booking.trainerId,
              date: booking.date,
              slot: booking.slot,
              durationMin: booking.durationMin,
              clientId: booking.clientId,
              attendanceStatus: booking.attendanceStatus,
              cancelled: booking.status == "cancelled",
            ),
        ],
        reviewedBookingIds: state.reviewed,
        deferrals: state.deferred,
        currentClientId: clientId,
        now: widget.now?.call(),
      );
      if (!mounted || id == null) return;
      final match = bookings.where((b) => b.id == id);
      if (match.isEmpty) return;
      final booking = match.first;
      setState(() {
        _ask = CheckedInSession(
          bookingId: booking.id,
          trainerId: booking.trainerId,
          date: booking.date,
          slot: booking.slot,
          durationMin: booking.durationMin,
          clientId: booking.clientId,
          attendanceStatus: booking.attendanceStatus,
          cancelled: booking.status == "cancelled",
        );
      });
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<Booking>>(clientBookingsProvider, (prev, next) {
      if (_checkedInSignature(prev ?? const []) != _checkedInSignature(next)) {
        unawaited(_refresh());
      }
    });
    final ask = _ask;
    if (ask == null || ClientForeground.blockers.value > 0) return const SizedBox.shrink();
    final coach = ref.watch(trainersProvider).where((t) => t.id == ask.trainerId);
    final name = coach.isEmpty ? "your coach" : coach.first.displayTitle;
    return SessionRatingCard(
      coachName: name,
      onSubmit: (stars, text) async {
        final submit = widget.submitReview ?? SupabaseService.submitCoachReview;
        await submit(
          bookingId: ask.bookingId,
          trainerId: ask.trainerId,
          stars: stars,
          body: text,
        );
        if (!mounted) return;
        setState(() => _ask = null);
      },
      onNotToday: () async {
        final defer = widget.deferReview ?? SupabaseService.deferReview;
        await defer(ask.bookingId, ask.trainerId);
        if (!mounted) return;
        setState(() => _ask = null);
      },
    );
  }
}
