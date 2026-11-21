import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/supabase/supabase_service.dart";

/// profile id -> balance in cents. Negative means the client owes the gym.
class ClientBalancesNotifier extends Notifier<Map<String, int>> {
  /// A test or a screenshot set the map. Automatic refresh leaves it alone.
  bool seeded = false;

  @override
  Map<String, int> build() => {};

  void seed(Map<String, int> next) {
    seeded = true;
    state = next;
  }

  void replace(Map<String, int> next) {
    seeded = false;
    state = next;
  }

  Future<void> refresh(List<String> ids, {bool force = false}) async {
    if (seeded && !force) return;
    final next = await SupabaseService.loadClientBalances(ids);
    if (seeded && !force) return;
    state = next;
  }
}

final clientBalancesProvider = NotifierProvider<ClientBalancesNotifier, Map<String, int>>(
  ClientBalancesNotifier.new,
);
