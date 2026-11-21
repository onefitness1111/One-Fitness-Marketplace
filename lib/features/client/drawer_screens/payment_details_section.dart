import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/privacy/client_contact_privacy.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/billing_address_form.dart";
import "../../../data/providers/client_providers.dart" show clientInfoProvider;
import "../../../data/models/saved_payment_method.dart";
import "payment_method_views.dart";

/// Profile Settings → Payment Details. Cards, bank accounts, and the billing
/// address live in one payment method. Adding one asks for the address first,
/// then opens Stripe for the card or bank account.
class PaymentDetailsSection extends ConsumerStatefulWidget {
  const PaymentDetailsSection({
    super.key,
    required this.onBack,
    this.clientId,
    this.clientName,
    this.viewer = BillingViewer.client,
  });
  final VoidCallback onBack;

  /// Set when a coach or owner is managing a client's payment methods; null
  /// for a client looking at their own.
  final String? clientId;
  final String? clientName;

  /// The client sees and edits the full address. The owner does too. A coach
  /// can enter one only when none is on file, and otherwise sees city and state.
  final BillingViewer viewer;

  @override
  ConsumerState<PaymentDetailsSection> createState() => _PaymentDetailsSectionState();
}

class _PaymentDetailsSectionState extends ConsumerState<PaymentDetailsSection> {
  late Future<List<SavedPaymentMethod>> _future = SupabaseService.loadPaymentMethods(clientId: widget.clientId);
  String? _removing;
  bool _adding = false;
  BillingAddressAccess? _access;
  bool _addressLoading = true;

  /// Whose address and cards these are: the client being managed by staff,
  /// or the signed-in client themselves.
  String get _targetId => widget.clientId ?? ref.read(clientInfoProvider).id;

  BillingViewer get _viewer => widget.clientId == null ? BillingViewer.client : widget.viewer;

  @override
  void initState() {
    super.initState();
    _loadAddress();
  }

  Future<void> _loadAddress() async {
    final loaded = await loadBillingForViewer(_targetId, _viewer);
    if (!mounted) return;
    setState(() {
      _access = billingAccessFor(
        viewer: _viewer,
        onFile: loaded.onFile,
        full: loaded.address,
        city: loaded.city,
        state: loaded.state,
      );
      _addressLoading = false;
    });
  }

  Future<void> _editAddress() async {
    final gate = await collectBillingAddress(
      context,
      clientId: _targetId,
      clientName: widget.clientName,
      viewer: _viewer,
      saveOnly: true,
    );
    if (!mounted || !gate.proceed) return;
    await _loadAddress();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Billing address saved.")));
    }
  }

  Future<void> _addPaymentMethod() async {
    setState(() => _adding = true);
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddPaymentMethodPage(
          clientId: _targetId,
          clientName: widget.clientName,
          viewer: _viewer,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _adding = false);
    if (saved == true) {
      setState(() => _future = SupabaseService.loadPaymentMethods(clientId: widget.clientId));
      await _loadAddress();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Payment method saved.")));
      }
    }
  }

  Future<void> _remove(SavedPaymentMethod method) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text("Remove payment method?"),
        content: Text(widget.clientId == null
            ? "${method.label} will be removed from your account. You can add it again at your next purchase."
            : "${method.label} will be removed from ${widget.clientName ?? "this client"}'s account."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Keep")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text("Remove", style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _removing = method.id);
    try {
      final next = await SupabaseService.loadPaymentMethods(removeId: method.id, clientId: widget.clientId);
      if (mounted) setState(() => _future = Future.value(next));
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst("Exception: ", "");
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg.contains("renews on") ? msg : "Couldn't remove it — check your connection and try again.")));
      }
    } finally {
      if (mounted) setState(() => _removing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<SavedPaymentMethod>>(
      future: _future,
      builder: (context, snap) {
        return RefreshIndicator(
          color: AppColors.gold,
          onRefresh: () async {
            final next = SupabaseService.loadPaymentMethods(clientId: widget.clientId);
            setState(() => _future = next);
            await Future.wait([next, _loadAddress()]);
          },
          child: PaymentMethodScreenView(
            title: widget.clientName == null ? "Payment Details" : "${widget.clientName}'s Payment Details",
            onBack: widget.onBack,
            access: _access,
            addressLoading: _addressLoading,
            methods: snap.data ?? const [],
            methodsLoading: snap.connectionState != ConnectionState.done,
            methodsError: snap.hasError,
            adding: _adding,
            removingId: _removing,
            onAdd: _addPaymentMethod,
            onEditAddress: _editAddress,
            onRemove: _remove,
          ),
        );
      },
    );
  }
}
