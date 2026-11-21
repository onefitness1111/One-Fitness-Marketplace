import "package:flutter/foundation.dart" show kIsWeb;
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../data/providers/client_providers.dart";
import "../../data/providers/trainer_providers.dart";
import "../../features/client/shell/client_shell_state.dart";
import "../../features/trainer/shell/trainer_shell_state.dart";
import "browser_path.dart";
import "portal_path.dart";

/// Set when /profile is opened before sign-in, so the profile shows
/// once the password is accepted.
class PendingPortalProfile extends Notifier<bool> {
  @override
  bool build() => false;

  void arm() => state = true;

  void clear() => state = false;
}

final pendingPortalProfileProvider =
    NotifierProvider<PendingPortalProfile, bool>(PendingPortalProfile.new);

void syncPortalAddress(WidgetRef ref, {required bool settingPassword}) {
  if (!kIsWeb) return;
  replaceBrowserPath(portalAddress(
    settingPassword: settingPassword,
    clientSignedIn: ref.read(clientSignedInProvider),
    staffSignedIn: ref.read(trainerAuthProvider) != null,
    clientScreen: ref.read(clientScreenProvider),
    trainerMode: ref.read(trainerModeProvider),
  ));
}

/// Opens profile when the address is /profile and someone is already signed in.
/// Otherwise remembers it for after sign-in.
void applyInitialPortalPath(WidgetRef ref, String initialPath) {
  if (!kIsWeb || !PortalPath.isProfile(initialPath)) return;
  final clientIn = ref.read(clientSignedInProvider);
  final staffIn = ref.read(trainerAuthProvider) != null;
  if (clientIn) {
    ref.read(clientScreenProvider.notifier).openFresh("settings");
  } else if (staffIn) {
    ref.read(trainerModeProvider.notifier).openFresh("myprofile");
  } else {
    ref.read(pendingPortalProfileProvider.notifier).arm();
  }
}

void openPendingProfile(WidgetRef ref, {required bool client}) {
  if (!kIsWeb || !ref.read(pendingPortalProfileProvider)) return;
  ref.read(pendingPortalProfileProvider.notifier).clear();
  if (client) {
    ref.read(clientScreenProvider.notifier).openFresh("settings");
  } else {
    ref.read(trainerModeProvider.notifier).openFresh("myprofile");
  }
}
