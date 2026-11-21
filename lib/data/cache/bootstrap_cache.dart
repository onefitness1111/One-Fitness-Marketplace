import "package:shared_preferences/shared_preferences.dart";

import "../../core/json/off_main_json.dart";

import "../models/booking.dart";
import "../models/client_info.dart";
import "../models/client_record.dart";
import "../models/membership_plan.dart";
import "../models/trainer.dart";
import "../models/waiver_doc.dart";
import "../providers/platform_settings_provider.dart";

/// What the first screen can paint without waiting on the network.
class CachedFirstScreen {
  const CachedFirstScreen({
    required this.profile,
    required this.roster,
    required this.trainers,
    required this.bookings,
    required this.records,
    required this.plans,
    required this.waivers,
    required this.settings,
    required this.payReady,
    required this.isClient,
    this.extras = const {},
  });

  final Map<String, dynamic>? profile;
  final List<ClientInfo> roster;
  final List<Trainer> trainers;
  final List<Booking> bookings;
  final Map<String, ClientRecord> records;
  final List<MembershipPlan> plans;
  final List<WaiverDoc> waivers;
  final PlatformSettings? settings;
  final bool payReady;
  final bool isClient;

  /// Badges, balance, renewal offers, quiet nudges, live days, and today's
  /// charges. Saved with the snapshot so a warm open is the whole screen.
  final Map<String, dynamic> extras;
}

/// On-device copy of the last successful first-screen load for one user.
///
/// The key is the signed-in user id. It holds only rows that user could
/// already read under RLS (names, bookings, records, plans). No session
/// token, no refresh token, no card number.
///
/// Signing out deletes that snapshot.
/// [activate] also drops it when a different person signs in on this device.
/// [deleteFor] is used for sign-out and account deletion.
class BootstrapCache {
  static const _userKey = "onefitness.bootstrap.user";

  static String _dataKey(String userId) => "onefitness.bootstrap.$userId";

  /// Drops [userId]'s snapshot. Also drops the previous user's snapshot when
  /// [userId] is a different person than the one last cached on this device.
  static Future<void> activate(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final previous = prefs.getString(_userKey);
      if (previous != null && previous != userId) {
        await prefs.remove(_dataKey(previous));
      }
      await prefs.setString(_userKey, userId);
    } catch (_) {}
  }

  static Future<void> deleteFor(String? userId) async {
    if (userId == null || userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_dataKey(userId));
      if (prefs.getString(_userKey) == userId) {
        await prefs.remove(_userKey);
      }
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> read(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_dataKey(userId));
      if (raw == null || raw.isEmpty) return null;
      // The snapshot is the last dashboard, programs included. Decoding it
      // on the UI isolate was a multi-second freeze before the first paint.
      final decoded = await decodeJsonOffMain(raw);
      if (decoded is! Map) return null;
      return decoded.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String userId, Map<String, dynamic> payload) async {
    try {
      final encoded = await encodeJsonOffMain(payload, weight: _weight(payload));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dataKey(userId), encoded);
      await prefs.setString(_userKey, userId);
    } catch (_) {}
  }

  /// Stops walking once the payload is clearly big enough to leave the UI isolate.
  static int _weight(Object? value) {
    var seen = 0;
    void walk(Object? v) {
      if (seen >= offMainJsonBytes) return;
      if (v is String) {
        seen += v.length;
      } else if (v is List) {
        for (final e in v) {
          walk(e);
          if (seen >= offMainJsonBytes) return;
        }
      } else if (v is Map) {
        for (final e in v.values) {
          walk(e);
          if (seen >= offMainJsonBytes) return;
        }
      }
    }

    walk(value);
    return seen;
  }
}
