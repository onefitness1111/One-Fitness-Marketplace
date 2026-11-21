import "dart:async";
import "package:app_links/app_links.dart";
import "package:flutter/foundation.dart" show kIsWeb;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "core/auth/web_launch.dart";
import "core/startup/launch_timing.dart";
import "core/chat/unread_chat.dart";
import "core/live_log/live_log_store.dart";
import "core/notifications/push_service.dart";
import "package:supabase_flutter/supabase_flutter.dart";
import "core/supabase/supabase_service.dart";
import "core/web/browser_path.dart";
import "core/web/portal_frame.dart";
import "core/web/portal_path.dart";
import "core/web/portal_route.dart";
import "core/web/url_strategy.dart";
import "features/client/shell/client_shell_state.dart";
import "core/notifications/push_prompt.dart";
import "core/widgets/change_password_form.dart";
import "core/motion/skeleton.dart";
import "core/theme/app_colors.dart";
import "core/updates/app_update.dart";
import "core/updates/app_update_sheet.dart";
import "core/theme/palette_scope.dart";
import "data/providers/client_providers.dart";
import "data/providers/role_provider.dart";
import "data/providers/supabase_bootstrap_provider.dart";
import "data/providers/theme_mode_provider.dart";
import "data/providers/trainer_providers.dart";
import "features/auth/client_auth_screen.dart";
import "features/client/shell/client_shell.dart";
import "features/shell/app_header.dart";
import "features/trainer/auth/trainer_auth_screen.dart";
import "features/trainer/shell/trainer_shell.dart";
import "features/trainer/shell/trainer_shell_state.dart";

Future<void> main() async {
  LaunchTiming.markProcessStart();
  WidgetsFlutterBinding.ensureInitialized();
  configureUrlStrategy();
  // Local only. Firebase, secure storage, PackageInfo, the update check,
  // and every network call wait until the first frame is up. The palette
  // is the exception: it is one SharedPreferences read, and opening on the
  // wrong one flashes the sign-in photo white.
  final storedTheme = ThemeModeNotifier.readStored();
  final launchUri = kIsWeb ? Uri.base : null;
  final launch = launchUri == null ? WebLaunchPlan.none : planWebLaunch(launchUri);
  runApp(
    ProviderScope(
      overrides: [
        initialThemeModeProvider.overrideWithValue(await storedTheme),
        webLaunchProvider.overrideWithValue(launch),
        webLaunchUriProvider.overrideWithValue(launchUri),
      ],
      child: const OneFitnessApp(),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    LaunchTiming.markFirstFrame();
    // Push must not sit in front of the first frame. Permission is still
    // asked later, after sign-in, not here.
    unawaited(PushService.init());
  });
}

/// Lets the Stripe-return check in _RootGate show a SnackBar without
/// needing a Scaffold ancestor at its own position in the tree (it sits
/// above every screen's own Scaffold) — the standard MaterialApp pattern
/// for exactly this.
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class OneFitnessApp extends StatelessWidget {
  const OneFitnessApp({super.key});

  @override
  Widget build(BuildContext context) {
    // PaletteScope owns installing the palette and repainting what's already
    // on screen when it changes — see its own doc comment for why a palette
    // swap doesn't otherwise reach the screen you're looking at.
    return PaletteScope(
      builder: (context, theme) => MaterialApp(
        title: "ONE Fitness",
        debugShowCheckedModeBanner: false,
        theme: theme,
        builder: (context, child) {
          final content = GestureDetector(
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: child ?? const SizedBox.shrink(),
          );
          if (!kIsWeb) return content;
          return PortalFrame(child: content);
        },
        scaffoldMessengerKey: scaffoldMessengerKey,
        onGenerateRoute: (settings) {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => _RootGate(initialPath: settings.name ?? PortalPath.home),
          );
        },
      ),
    );
  }
}

/// Mirrors App.jsx's top-level structure: the Coach/Client pill toggle
/// (Header) above whichever shell is active, hidden once a client is signed
/// in. Each side's own auth screen gates its own shell independently.
///
/// Before any of that renders, this waits on [supabaseBootstrapProvider] —
/// the real Supabase session restore + roster/trainers/bookings fetch —
/// same as App.jsx awaiting its own bootstrap Promise.all before mounting.
class _RootGate extends ConsumerStatefulWidget {
  const _RootGate({this.initialPath = PortalPath.home});

  final String initialPath;

  @override
  ConsumerState<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<_RootGate> {
  bool _checkedStripeReturn = false;
  bool _portalApplied = false;
  AppUpdateConfig? _updateConfig;
  UpdatePrompt _updatePrompt = UpdatePrompt.none;
  bool _updateDismissed = false;
  StreamSubscription<Uri>? _linkSub;
  StreamSubscription<AuthState>? _authSub;
  bool _setPassword = false;

  /// Coming back to the app re-reads membership state, so a cancellation
  /// or freeze made on another device (staff cancelling a client's
  /// membership, say) shows without signing out and in again.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onPause: () {
      LiveLogStore.instance.flush();
    },
    onInactive: () {
      LiveLogStore.instance.flush();
    },
    onResume: () {
      refreshClientInfos(ref).catchError((Object e) {
        // ignore: avoid_print
        print("[resume] membership refresh failed: $e");
      });
      _checkAppUpdate();
      ref.read(unreadChatKeysProvider.notifier).refresh();
      ref.read(pushNoticeProvider.notifier).refresh();
    },
  );

  @override
  void initState() {
    super.initState();
    final launch = ref.read(webLaunchProvider);
    _setPassword = launch.kind == WebLaunchKind.setPassword;
    if (launch.message != null) {
      final message = launch.message!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(content: Text(message), duration: const Duration(seconds: 8)),
        );
      });
    }
    if (_setPassword && kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        replaceBrowserPath(PortalPath.resetPassword);
      });
    }
    // Uri.base's own `?stripe=...` only exists on Flutter web (the browser
    // reloads this same "page"); on mobile the equivalent is Stripe's
    // browser handing off to the app's own "onefitness://checkout-return"
    // deep link instead — see membership_hub_screen.dart's returnUrl and
    // the matching intent-filter/CFBundleURLTypes entries.
    if (!kIsWeb) _initDeepLinks();
    try {
      _authSub = SupabaseService.client.auth.onAuthStateChange.listen((data) {
        if (data.event == AuthChangeEvent.passwordRecovery && mounted) {
          setState(() => _setPassword = true);
        }
      });
    } catch (_) {
      // Widget tests build the app before Supabase is initialised.
    }
    LiveLogStore.instance.ensureLoaded();
    _lifecycle; // created now so it's listening from the first frame
    // PackageInfo and the app-config read used to start in this method,
    // before the first frame. They run after it. A blocking update sheet
    // appears when the check finishes, only if this build is below the
    // minimum or force_update is set. It does not hold the dashboard.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkAppUpdate();
    });
  }

  Future<void> _checkAppUpdate() async {
    final row = await SupabaseService.loadAppConfig();
    if (!mounted || row == null) return;
    final config = AppUpdateConfig.fromJson(row);
    final installed = await installedAppVersion();
    if (!mounted) return;
    setState(() {
      _updateConfig = config;
      _updatePrompt = updatePromptFor(installed: installed, config: config);
    });
  }

  Future<void> _initDeepLinks() async {
    final links = AppLinks();
    try {
      final initial = await links.getInitialLink();
      if (initial != null) _handleDeepLink(initial);
    } catch (_) {
      // No initial link, or the platform channel isn't ready yet — either
      // way there's nothing to recover from here.
    }
    _linkSub = links.uriLinkStream.listen(_handleDeepLink, onError: (_) {});
  }

  void _schedulePortalRoute() {
    if (!kIsWeb || _portalApplied) return;
    _portalApplied = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      applyInitialPortalPath(ref, widget.initialPath);
      syncPortalAddress(ref, settingPassword: _setPassword);
    });
  }

  void _handleDeepLink(Uri uri) {
    if (uri.scheme == "onefitness" && uri.host == "reset-password") {
      unawaited(() async {
        try {
          await SupabaseService.recoverSessionFromUrl(uri);
        } catch (e) {
          // ignore: avoid_print
          print("[reset] session: $e");
        }
      }());
      return;
    }
    if (uri.scheme != "onefitness" || uri.host != "checkout-return") return;
    final stripeParam = uri.queryParameters["stripe"];
    if (stripeParam == null) return;
    _showStripeSnack(stripeParam);
    // A successful payment is only ever actually applied server-side by
    // stripe-webhook, often with a short delay — re-running the same
    // fetch+seed used at sign-in gives this landing its best shot at
    // showing the new membership without the client having to leave and
    // come back to this screen themselves.
    if (stripeParam == "success") loadAndSeedCoreData(ref);
  }

  /// One-time check for `?stripe=success`/`?stripe=cancel` on the URL —
  /// create-checkout-session's `success_url`/`cancel_url` land back on this
  /// same page on web (see membership_hub_screen.dart's `returnUrl`). The
  /// plan itself is only ever granted by stripe-webhook confirming payment
  /// (never here, and often not instantly), so this deliberately doesn't
  /// claim the purchase is done — just that Stripe took the payment and
  /// the membership will show up once the webhook's caught up.
  void _checkStripeReturn() {
    if (_checkedStripeReturn) return;
    _checkedStripeReturn = true;
    if (!kIsWeb) return;
    final stripeParam = Uri.base.queryParameters["stripe"];
    if (stripeParam == null) return;
    _showStripeSnack(stripeParam);
  }

  Widget _withUpdateNotice(Widget child) {
    final config = _updateConfig;
    if (config == null || _updatePrompt == UpdatePrompt.none) return child;
    if (_updatePrompt == UpdatePrompt.optional && _updateDismissed) return child;
    final blocking = _updatePrompt == UpdatePrompt.blocking;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: AppUpdateNotice(
            config: config,
            blocking: blocking,
            onDismiss: blocking ? null : () => setState(() => _updateDismissed = true),
          ),
        ),
      ],
    );
  }

  void _showStripeSnack(String stripeParam) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messenger = scaffoldMessengerKey.currentState;
      if (messenger == null) return;
      if (stripeParam == "success") {
        messenger.showSnackBar(const SnackBar(
          content: Text("Payment received — your membership will update shortly."),
          duration: Duration(seconds: 6),
        ));
      } else if (stripeParam == "cancel") {
        messenger.showSnackBar(const SnackBar(content: Text("Checkout was cancelled — nothing was charged.")));
      }
    });
  }

  @override
  void dispose() {
    _linkSub?.cancel();
    _authSub?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_setPassword) {
      return SetNewPasswordScreen(
        onDone: () async {
          await loadAndSeedCoreData(ref);
          if (mounted) setState(() => _setPassword = false);
        },
      );
    }
    final bootstrap = ref.watch(supabaseBootstrapProvider);

    return bootstrap.when(
      loading: () => Scaffold(
        backgroundColor: AppColors.bg,
        body: const AppLoading(),
      ),
      error: (err, st) {
        // fall back to mock/signed-out state rather than block the app
        _schedulePortalRoute();
        return const _RootContent();
      },
      data: (_) {
        _checkStripeReturn();
        _schedulePortalRoute();
        return _withUpdateNotice(const _RootContent());
      },
    );
  }
}

class _RootContent extends ConsumerWidget {
  const _RootContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The staff shell has no Navigator: which screen shows is a string in
    // trainerModeProvider, and nothing used to reset it between sessions.
    // An owner who signed out from the Coaches page left "coaches" behind,
    // and the next staff session — a brand-new coach signing up — opened
    // straight onto it. Every change of staff identity (sign-in, sign-out,
    // owner → coach) therefore lands on Dashboard. This listener fires
    // synchronously inside the signIn/signOut call, before the next build,
    // so the stale screen never renders even for a frame.
    ref.listen<String?>(trainerAuthProvider, (prev, next) {
      if (prev != next) {
        ref.read(trainerModeProvider.notifier).reset();
        if (kIsWeb && next != null) openPendingProfile(ref, client: false);
      }
      if (kIsWeb) syncPortalAddress(ref, settingPassword: false);
    });
    ref.listen(clientSignedInProvider, (prev, next) {
      if (!kIsWeb) return;
      if (next == true && prev != true) openPendingProfile(ref, client: true);
      syncPortalAddress(ref, settingPassword: false);
    });
    ref.listen(clientScreenProvider, (_, _) {
      if (kIsWeb) syncPortalAddress(ref, settingPassword: false);
    });
    ref.listen(trainerModeProvider, (_, _) {
      if (kIsWeb) syncPortalAddress(ref, settingPassword: false);
    });

    final role = ref.watch(roleProvider);
    final clientSignedIn = ref.watch(clientSignedInProvider);
    final clientSigningUp = ref.watch(clientSigningUpProvider);
    final trainerAuth = ref.watch(trainerAuthProvider);

    final staffSignedIn = role == "trainer" && trainerAuth != null;
    final showHeader = !((role == "client" && (clientSignedIn || clientSigningUp)) || staffSignedIn);
    final body = role == "trainer" ? (trainerAuth == null ? const TrainerAuthScreen() : const TrainerShell()) : (clientSignedIn ? const ClientShell() : const ClientAuthScreen());

    if (!showHeader) return body;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const AppHeader(),
          Expanded(child: body),
        ],
      ),
    );
  }
}
