import "package:flutter/material.dart";
import "../../../core/session/login_prompts.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "../../../core/payments/payment_sheet_service.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/package_renewal.dart";
import "../../../core/widgets/app_buttons.dart";
import "../../../core/widgets/app_card.dart";
import "../../../core/widgets/billing_address_form.dart";
import "../../../data/providers/client_providers.dart";
import "../../../data/providers/platform_settings_provider.dart";

class _Offer {
  const _Offer({
    required this.planId,
    required this.planName,
    required this.enrollmentStart,
    required this.offer,
    required this.remaining,
    required this.priceCents,
    required this.chargeCents,
    required this.discountPercent,
  });

  final String planId;
  final String planName;
  final String enrollmentStart;
  final RenewalOffer offer;
  final int remaining;
  final int priceCents;
  final int chargeCents;

  /// The percent the server used for [chargeCents]. Ignored for a full-price offer.
  final int discountPercent;

  String get kind => offer == RenewalOffer.discount ? "package_discount" : "package_full";
}

int _discountPercent(Map<String, dynamic> row) {
  final sent = (row["discountPercent"] as num?)?.toInt();
  if (sent != null && sent >= kRenewDiscountPercentMin && sent <= kRenewDiscountPercentMax) return sent;
  return kRenewDiscountPercent;
}

/// The in-app half of the package renewal reminder. The phone notification
/// is sent by the same server check.
class PackageRenewalCard extends ConsumerStatefulWidget {
  const PackageRenewalCard({super.key});

  @override
  ConsumerState<PackageRenewalCard> createState() => _PackageRenewalCardState();
}

class _PackageRenewalCardState extends ConsumerState<PackageRenewalCard> {
  List<_Offer> _offers = const [];
  bool _loaded = false;
  String? _busyId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await SupabaseService.syncPackageRenewals();
      final next = <_Offer>[];
      for (final row in rows) {
        final name = row["offer"]?.toString();
        final offer = name == "discount"
            ? RenewalOffer.discount
            : name == "full"
                ? RenewalOffer.fullPrice
                : RenewalOffer.none;
        if (offer == RenewalOffer.none) continue;
        next.add(_Offer(
          planId: row["planId"]?.toString() ?? "",
          planName: row["planName"]?.toString() ?? "package",
          enrollmentStart: row["enrollmentStart"]?.toString() ?? "",
          offer: offer,
          remaining: (row["remaining"] as num?)?.toInt() ?? 0,
          priceCents: (row["priceCents"] as num?)?.toInt() ?? 0,
          chargeCents: (row["chargeCents"] as num?)?.toInt() ?? 0,
          discountPercent: _discountPercent(row),
        ));
      }
      if (mounted) setState(() { _offers = next; _loaded = true; _error = null; });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _dismiss(_Offer offer) async {
    setState(() => _busyId = offer.planId);
    try {
      await SupabaseService.dismissPackageRenewal(
        planId: offer.planId,
        enrollmentStart: offer.enrollmentStart,
        kind: offer.kind,
      );
      if (mounted) {
        setState(() => _offers = _offers.where((o) => o.planId != offer.planId).toList());
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = offer.offer == RenewalOffer.discount
            ? renewalDiscountStillThere(offer.discountPercent)
            : "Couldn't close that reminder.");
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _renew(_Offer offer) async {
    final price = offer.offer == RenewalOffer.discount
        ? renewalDiscountQuestion(
            planName: offer.planName,
            percent: offer.discountPercent,
            chargeCents: offer.chargeCents,
            priceCents: offer.priceCents,
          )
        : "Renew ${offer.planName} for ${renewalMoney(offer.chargeCents)}?";
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(offer.offer == RenewalOffer.discount ? renewalDiscountTitle(offer.discountPercent) : "Renew now"),
        content: Text(
          "$price You'll confirm the charge on the card you have on file before anything is taken. The next screen shows the total, including any card fee.",
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Not now")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Continue")),
        ],
      ),
    );
    if (go != true) {
      if (go == false) await _dismiss(offer);
      return;
    }
    if (!mounted) return;
    final info = ref.read(clientInfoProvider);
    final billing = await ensureBillingAddress(context, clientId: info.id, clientName: info.name);
    if (billing == null || !mounted) return;
    setState(() { _busyId = offer.planId; _error = null; });
    final (result, paymentId) = await PaymentSheetService.purchasePackageRenewal(
      planId: offer.planId,
      enrollmentStart: offer.enrollmentStart,
      businessName: ref.read(platformSettingsProvider).businessName,
      billing: billing,
    );
    if (!mounted) return;
    if (result.cancelled) {
      setState(() => _busyId = null);
      return;
    }
    if (!result.ok) {
      setState(() { _busyId = null; _error = result.error; });
      return;
    }
    if (paymentId != null && paymentId.isNotEmpty) {
      try {
        await SupabaseService.confirmPackageRenewal(paymentId);
      } catch (_) {
        // The charge already went through. The sheet is the receipt if the
        // message doesn't arrive.
      }
    }
    if (!mounted) return;
    setState(() {
      _busyId = null;
      _offers = _offers.where((o) => o.planId != offer.planId).toList();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Renewal confirmed. ${renewalMoney(offer.chargeCents)} was charged to the card on file, plus any card fee shown on the payment screen.")),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _offers.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final offer in _offers)
          AppCard(
            borderColor: AppColors.goldDim,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  offer.offer == RenewalOffer.discount ? renewalDiscountBanner(offer.discountPercent) : "RENEW NOW",
                  style: TextStyle(fontSize: 12, color: AppColors.gold, fontWeight: FontWeight.w700, letterSpacing: 0.6),
                ),
                const SizedBox(height: 6),
                Text(
                  offer.offer == RenewalOffer.discount
                      ? renewalDiscountBody(planName: offer.planName, remaining: offer.remaining, percent: offer.discountPercent)
                      : "Your ${offer.planName} has ${offer.remaining} sessions left. Renew now to keep your sessions going.",
                  style: const TextStyle(fontSize: 14, height: 1.35),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
                ],
                const SizedBox(height: 12),
                BtnGold(
                  onPressed: _busyId == null ? () => _renew(offer) : null,
                  full: true,
                  child: Text(_busyId == offer.planId ? "Working…" : "Renew now"),
                ),
                Align(
                  alignment: Alignment.center,
                  child: TextButton(
                    onPressed: _busyId == null ? gateLoginTap(() => _dismiss(offer)) : null,
                    child: Text("Not now", style: TextStyle(color: AppColors.mute, fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
