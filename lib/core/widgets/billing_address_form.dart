import "package:flutter/material.dart";
import "../../data/models/billing_address.dart";
import "../payments/billing_address_rules.dart";
import "../privacy/client_contact_privacy.dart";
import "../supabase/supabase_service.dart";
import "../theme/app_colors.dart";
import "app_buttons.dart";
import "app_text_field.dart";
import "back_bar.dart";

/// What is on file for [viewer]. A coach receives city and state only.
Future<({BillingAddress? address, bool onFile, String? city, String? state})> loadBillingForViewer(
  String clientId,
  BillingViewer viewer,
) async {
  if (viewer == BillingViewer.coach) {
    final flags = await SupabaseService.clientFileFlags(clientId);
    final onFile = flags?.billingOnFile ?? false;
    if (!onFile) return (address: null, onFile: false, city: null, state: null);
    final locality = await SupabaseService.loadBillingLocality(clientId);
    return (address: null, onFile: true, city: locality?.city, state: locality?.state);
  }
  final address = await SupabaseService.loadBillingAddress(clientId);
  return (
    address: address,
    onFile: address != null && address.line1.trim().isNotEmpty,
    city: address?.city,
    state: address?.state,
  );
}

/// Step 1 of adding a card or bank account, and the screen a client uses to
/// edit the address saved on the payment method. Pops a [BillingGate].
Future<BillingGate> collectBillingAddress(
  BuildContext context, {
  required String clientId,
  String? clientName,
  BillingViewer viewer = BillingViewer.client,
  bool saveOnly = false,
}) async {
  final loaded = await loadBillingForViewer(clientId, viewer);
  if (!context.mounted) return const BillingGate(cancelled: true);
  final gate = await Navigator.of(context).push<BillingGate>(
    MaterialPageRoute(
      builder: (_) => BillingAddressStepPage(
        clientId: clientId,
        clientName: clientName,
        viewer: viewer,
        loaded: loaded,
        saveOnly: saveOnly,
      ),
    ),
  );
  return gate ?? const BillingGate(cancelled: true);
}

class BillingAddressFields extends StatefulWidget {
  const BillingAddressFields({super.key, this.initial, required this.onChanged});
  final BillingAddress? initial;
  final ValueChanged<BillingAddress> onChanged;

  @override
  State<BillingAddressFields> createState() => _BillingAddressFieldsState();
}

class _BillingAddressFieldsState extends State<BillingAddressFields> {
  late final _name = TextEditingController(text: widget.initial?.name);
  late final _line1 = TextEditingController(text: widget.initial?.line1);
  late final _line2 = TextEditingController(text: widget.initial?.line2);
  late final _city = TextEditingController(text: widget.initial?.city);
  late final _state = TextEditingController(text: widget.initial?.state);
  late final _zip = TextEditingController(text: widget.initial?.postalCode);
  late final _country = TextEditingController(
    text: (widget.initial?.country.trim().isNotEmpty ?? false) ? widget.initial!.country : "US",
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChanged(_current());
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _line1, _line2, _city, _state, _zip, _country]) {
      c.dispose();
    }
    super.dispose();
  }

  BillingAddress _current() => BillingAddress(
        name: _name.text,
        line1: _line1.text,
        line2: _line2.text,
        city: _city.text,
        state: _state.text.toUpperCase(),
        postalCode: _zip.text,
        country: _country.text.trim().isEmpty ? "US" : _country.text,
      );

  void _emit() => widget.onChanged(_current());

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AppField(controller: _name, kind: FieldKind.name, placeholder: "Name on the address", onChanged: (_) => _emit()),
        const SizedBox(height: 8),
        AppField(controller: _line1, kind: FieldKind.text, placeholder: "Street address", onChanged: (_) => _emit()),
        const SizedBox(height: 8),
        AppField(controller: _line2, kind: FieldKind.text, placeholder: "Apt or suite (optional)", onChanged: (_) => _emit()),
        const SizedBox(height: 8),
        AppField(controller: _city, kind: FieldKind.name, placeholder: "City", onChanged: (_) => _emit()),
        const SizedBox(height: 8),
        AppField(controller: _state, kind: FieldKind.text, placeholder: "State", onChanged: (_) => _emit()),
        const SizedBox(height: 8),
        AppField(controller: _zip, kind: FieldKind.text, placeholder: "ZIP code", onChanged: (_) => _emit()),
        const SizedBox(height: 8),
        AppField(controller: _country, kind: FieldKind.text, placeholder: "Country", onChanged: (_) => _emit()),
      ],
    );
  }
}

class BillingAddressStepView extends StatelessWidget {
  const BillingAddressStepView({
    super.key,
    required this.viewer,
    required this.onFile,
    this.address,
    this.city,
    this.state,
    this.clientName,
    this.busy = false,
    this.error,
    this.saveOnly = false,
    this.onBack,
    this.onContinue,
    this.onChanged,
  });

  final BillingViewer viewer;
  final bool onFile;
  final BillingAddress? address;
  final String? city;
  final String? state;
  final String? clientName;
  final bool busy;
  final String? error;
  final bool saveOnly;
  final VoidCallback? onBack;
  final VoidCallback? onContinue;
  final ValueChanged<BillingAddress>? onChanged;

  @override
  Widget build(BuildContext context) {
    final access = billingAccessFor(
      viewer: viewer,
      onFile: onFile,
      full: address,
      city: city,
      state: state,
    );
    final coachLocked = viewer == BillingViewer.coach && onFile;
    final prefill = access.canReadFull
        ? billingAddressPrefill(saved: address, name: clientName)
        : null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BackBar(onBack: onBack, title: "Payment method"),
          const SizedBox(height: 10),
          Text(
            saveOnly ? "Billing address" : "Step 1 of 2",
            style: TextStyle(color: AppColors.mute, fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            saveOnly ? "Saved with the payment method" : "Billing address",
            style: TextStyle(color: AppColors.txt, fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            coachLocked
                ? "This address is on file. Only the city and state are shown, and it can't be replaced."
                : "Required. A card or bank account is saved only together with this address.",
            style: TextStyle(color: AppColors.mute, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          if (coachLocked)
            Text(
              billingSummary(access),
              style: TextStyle(color: AppColors.txt, fontSize: 16, fontWeight: FontWeight.w700),
            )
          else
            BillingAddressFields(initial: prefill, onChanged: onChanged ?? (_) {}),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
          ],
          const SizedBox(height: 18),
          BtnGold(
            full: true,
            onPressed: busy ? null : onContinue,
            child: Text(busy ? "Saving…" : (saveOnly ? "Save address" : "Continue")),
          ),
        ],
      ),
    );
  }
}

class BillingAddressStepPage extends StatefulWidget {
  const BillingAddressStepPage({
    super.key,
    required this.clientId,
    required this.viewer,
    required this.loaded,
    this.clientName,
    this.saveOnly = false,
  });

  final String clientId;
  final String? clientName;
  final BillingViewer viewer;
  final ({BillingAddress? address, bool onFile, String? city, String? state}) loaded;
  final bool saveOnly;

  @override
  State<BillingAddressStepPage> createState() => _BillingAddressStepPageState();
}

class _BillingAddressStepPageState extends State<BillingAddressStepPage> {
  BillingAddress? _draft;
  bool _busy = false;
  String? _error;

  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await commitAddressStep(
      viewer: widget.viewer,
      onFile: widget.loaded.onFile,
      draft: _draft ?? widget.loaded.address,
      save: (address) => SupabaseService.saveBillingAddress(widget.clientId, address),
    );
    if (!mounted) return;
    if (result.error != null || result.gate == null) {
      setState(() {
        _busy = false;
        _error = result.error ?? "Enter the billing address.";
      });
      return;
    }
    Navigator.of(context).pop(result.gate);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: BillingAddressStepView(
          viewer: widget.viewer,
          onFile: widget.loaded.onFile,
          address: widget.loaded.address,
          city: widget.loaded.city,
          state: widget.loaded.state,
          clientName: widget.clientName,
          busy: _busy,
          error: _error,
          saveOnly: widget.saveOnly,
          onBack: () => Navigator.of(context).pop(const BillingGate(cancelled: true)),
          onContinue: _continue,
          onChanged: (address) => _draft = address,
        ),
      ),
    );
  }
}
