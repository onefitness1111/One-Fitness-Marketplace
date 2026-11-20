import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../core/coach/review_prompt.dart";
import "../../../core/motion/client_foreground.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/utils/date_utils.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/trainer_providers.dart";
import "session_rating_card.dart";

/// Asks about one checked-in session after the app is open. Coaches and the
/// owner never mount this. It waits if a workout-complete screen is up.
class SessionRatingHost extends ConsumerStatefulWidget {
  const SessionRatingHost({super.key});

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

  Future<void> _refresh() async {
    if (_busy || _ask != null || ClientForeground.blockers.value > 0) return;
    _busy = true;
    try {
      final bookings = ref.read(clientBookingsProvider);
      final state = await SupabaseService.loadReviewState();
      final id = nextSessionToRate(
        checkedIn: [
          for (final booking in bookings)
            if (booking.attendanceStatus == "checked-in")
              CheckedInSession(bookingId: booking.id, trainerId: booking.trainerId, date: booking.date),
        ],
        reviewedBookingIds: state.reviewed,
        deferrals: state.deferred,
        today: isoToday(),
      );
      if (!mounted || id == null) return;
      final match = bookings.where((b) => b.id == id);
      if (match.isEmpty) return;
      setState(() => _ask = CheckedInSession(bookingId: match.first.id, trainerId: match.first.trainerId, date: match.first.date));
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ask = _ask;
    if (ask == null || ClientForeground.blockers.value > 0) return const SizedBox.shrink();
    final coach = ref.watch(trainersProvider).where((t) => t.id == ask.trainerId);
    final name = coach.isEmpty ? "your coach" : coach.first.displayTitle;
    return SessionRatingCard(
      coachName: name,
      onSubmit: (stars, text) async {
        setState(() => _ask = null);
        try {
          await SupabaseService.submitCoachReview(
            bookingId: ask.bookingId,
            trainerId: ask.trainerId,
            stars: stars,
            body: text,
          );
        } catch (_) {}
      },
      onNotToday: () async {
        setState(() => _ask = null);
        try {
          await SupabaseService.deferReview(ask.bookingId, ask.trainerId);
        } catch (_) {}
      },
    );
  }
}
