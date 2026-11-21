import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/payments/payment_sheet_service.dart";
import "../../../core/privacy/client_contact_privacy.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/billing_address_form.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/billing_address.dart";
import "../../../data/models/saved_payment_method.dart";
import "../../../data/providers/platform_settings_provider.dart";

/// Profile Settings → Payment Details, and the staff view of the same screen.
/// The address sits inside the payment method, not in a section of its own.
class PaymentMethodScreenView extends StatelessWidget {
  const PaymentMethodScreenView({
    super.key,
    required this.title,
    required this.onBack,
    required this.access,
    required this.addressLoading,
    required this.methods,
    required this.methodsLoading,
    this.methodsError = false,
    this.adding = false,
    this.removingId,
    this.onAdd,
    this.onEditAddress,
    this.onRemove,
  });

  final String title;
  final VoidCallback onBack;
  final BillingAddressAccess? access;
  final bool addressLoading;
  final List<SavedPaymentMethod> methods;
  final bool methodsLoading;
  final bool methodsError;
  final bool adding;
  final String? removingId;
  final VoidCallback? onAdd;
  final VoidCallback? onEditAddress;
  final ValueChanged<SavedPaymentMethod>? onRemove;

  @override
  Widget build(BuildContext context) {
    final shown = access;
    final summary = addressLoading || shown == null ? "Loading…" : billingSummary(shown);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(18),
      children: [
        BackBar(onBack: onBack, title: title),
        const SizedBox(height: 14),
        AppCard(
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Payment method", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 12),
              Text("Billing address", style: TextStyle(color: AppColors.mute, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(summary, style: TextStyle(color: AppColors.txt, fontSize: 14, height: 1.35, fontWeight: FontWeight.w600)),
              if (shown != null && shown.canEdit)
                TextButton(onPressed: onEditAddress, style: _linkStyle(), child: const Text("Edit"))
              else if (shown != null && shown.canAdd)
                TextButton(onPressed: onEditAddress, style: _linkStyle(), child: const Text("Add")),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Container(height: 1, color: AppColors.line),
              ),
              if (methodsLoading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator(color: AppColors.gold)),
                )
              else if (methodsError)
                Text("Couldn't load the saved cards — pull down to try again.", style: TextStyle(color: AppColors.mute, fontSize: 13))
              else if (methods.isEmpty)
                Text(
                  "No card or bank account yet.",
                  style: TextStyle(color: AppColors.mute, fontSize: 13, height: 1.4),
                )
              else
                for (final method in methods) _MethodRow(method: method, removing: removingId == method.id, onRemove: onRemove),
            ],
          ),
        ),
        const SizedBox(height: 14),
        BtnGold(
          full: true,
          onPressed: adding ? null : onAdd,
          child: Text(adding ? "Opening…" : "Add payment method"),
        ),
        const SizedBox(height: 12),
        const HintBox(
          text: "Card and bank numbers are stored by Stripe, not by ONE Fitness. A payment method is saved only with a billing address.",
        ),
      ],
    );
  }
}

ButtonStyle _linkStyle() => TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: AppColors.gold,
    );

class _MethodRow extends StatelessWidget {
  const _MethodRow({required this.method, required this.removing, this.onRemove});
  final SavedPaymentMethod method;
  final bool removing;
  final ValueChanged<SavedPaymentMethod>? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(method.isCard ? LucideIcons.creditCard : LucideIcons.landmark, size: 18, color: AppColors.gold),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(method.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                Text(
                  [
                    if (method.expiry != null) "Expires ${method.expiry}",
                    if (method.isDefault) "Used for membership renewals",
                  ].join(" · ").ifEmpty(method.isCard ? "Saved card" : "Saved bank account"),
                  style: TextStyle(fontSize: 12, color: AppColors.mute),
                ),
              ],
            ),
          ),
          if (removing)
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold))
          else if (onRemove != null)
            IconButton(
              tooltip: "Remove",
              onPressed: () => onRemove!(method),
              icon: Icon(LucideIcons.trash2, size: 17, color: AppColors.mute),
            ),
        ],
      ),
    );
  }
}

/// Step 2. The card number or bank account is entered on Stripe's screen.
class CardEntryStepView extends StatelessWidget {
  const CardEntryStepView({
    super.key,
    required this.addressSummary,
    required this.bank,
    this.busy = false,
    this.error,
    this.onBack,
    this.onPickCard,
    this.onPickBank,
    this.onContinue,
  });

  final String addressSummary;
  final bool bank;
  final bool busy;
  final String? error;
  final VoidCallback? onBack;
  final VoidCallback? onPickCard;
  final VoidCallback? onPickBank;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BackBar(onBack: onBack, title: "Payment method"),
          const SizedBox(height: 10),
          Text("Step 2 of 2", style: TextStyle(color: AppColors.mute, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text("Card or bank", style: TextStyle(color: AppColors.txt, fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            "The number is entered on Stripe's secure screen. Nothing is saved unless the billing address from step 1 is attached.",
            style: TextStyle(color: AppColors.mute, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          Text("Address on this payment method", style: TextStyle(color: AppColors.mute, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(addressSummary, style: TextStyle(color: AppColors.txt, fontSize: 14, height: 1.35, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          _TenderChoice(title: "Card", detail: "Debit or credit card", selected: !bank, icon: LucideIcons.creditCard, onTap: onPickCard),
          const SizedBox(height: 8),
          _TenderChoice(title: "Bank account", detail: "US bank account", selected: bank, icon: LucideIcons.landmark, onTap: onPickBank),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
          ],
          const SizedBox(height: 18),
          BtnGold(
            full: true,
            onPressed: busy ? null : onContinue,
            child: Text(busy ? "Opening…" : (bank ? "Enter bank account" : "Enter card")),
          ),
        ],
      ),
    );
  }
}

class _TenderChoice extends StatelessWidget {
  const _TenderChoice({
    required this.title,
    required this.detail,
    required this.selected,
    required this.icon,
    this.onTap,
  });

  final String title;
  final String detail;
  final bool selected;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: EdgeInsets.zero,
      borderColor: selected ? AppColors.gold : AppColors.line,
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.gold),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                Text(detail, style: TextStyle(color: AppColors.mute, fontSize: 12)),
              ],
            ),
          ),
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, size: 18, color: selected ? AppColors.gold : AppColors.mute),
        ],
      ),
    );
  }
}

class AddPaymentMethodPage extends ConsumerStatefulWidget {
  const AddPaymentMethodPage({
    super.key,
    required this.clientId,
    required this.viewer,
    this.clientName,
  });

  final String clientId;
  final String? clientName;
  final BillingViewer viewer;

  @override
  ConsumerState<AddPaymentMethodPage> createState() => _AddPaymentMethodPageState();
}

class _AddPaymentMethodPageState extends ConsumerState<AddPaymentMethodPage> {
  ({BillingAddress? address, bool onFile, String? city, String? state})? _loaded;
  BillingAddress? _draft;
  BillingGate? _gate;
  var _step = 1;
  var _busy = false;
  var _bank = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loaded = await loadBillingForViewer(widget.clientId, widget.viewer);
    if (mounted) setState(() => _loaded = loaded);
  }

  Future<void> _commitAddress() async {
    final loaded = _loaded;
    if (loaded == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await commitAddressStep(
      viewer: widget.viewer,
      onFile: loaded.onFile,
      draft: _draft ?? loaded.address,
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
    setState(() {
      _busy = false;
      _gate = result.gate;
      _step = 2;
      _error = null;
    });
  }

  Future<void> _enterPayment() async {
    final gate = _gate;
    if (gate == null || !gate.proceed) {
      setState(() => _error = "Add a billing address before saving a payment method.");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await PaymentSheetService.addPaymentMethod(
      businessName: ref.read(platformSettingsProvider).businessName,
      clientId: widget.viewer == BillingViewer.client ? null : widget.clientId,
      billing: gate.address,
      useStoredBilling: gate.storedOnFile,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.cancelled) return;
    if (!result.ok) {
      setState(() => _error = result.error ?? "Couldn't save that payment method.");
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _loaded;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: loaded == null
            ? Center(child: CircularProgressIndicator(color: AppColors.gold))
            : _step == 1
                ? BillingAddressStepView(
                    viewer: widget.viewer,
                    onFile: loaded.onFile,
                    address: loaded.address,
                    city: loaded.city,
                    state: loaded.state,
                    clientName: widget.clientName,
                    busy: _busy,
                    error: _error,
                    onBack: () => Navigator.of(context).pop(false),
                    onContinue: _commitAddress,
                    onChanged: (address) => _draft = address,
                  )
                : CardEntryStepView(
                    addressSummary: _summary(loaded),
                    bank: _bank,
                    busy: _busy,
                    error: _error,
                    onBack: () => setState(() {
                      _step = 1;
                      _error = null;
                    }),
                    onPickCard: () => setState(() => _bank = false),
                    onPickBank: () => setState(() => _bank = true),
                    onContinue: _enterPayment,
                  ),
      ),
    );
  }

  String _summary(({BillingAddress? address, bool onFile, String? city, String? state}) loaded) {
    final gate = _gate;
    if (gate?.storedOnFile == true) {
      return billingSummary(billingAccessFor(
        viewer: BillingViewer.coach,
        onFile: true,
        city: loaded.city,
        state: loaded.state,
      ));
    }
    final address = gate?.address;
    if (address == null) return "Not on file";
    return formatBillingAddress(address);
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
