import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:lucide_flutter/lucide_flutter.dart";
import "../../../core/navigation/local_back_stack.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/utils/package_renewal.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/coupon.dart";
import "../../../core/payments/coupon_duration.dart";
import "../../../data/providers/platform_settings_provider.dart";
import "../../../data/providers/trainer_providers.dart";

/// Owner-managed coupon-code catalog, reached from Customize Platform's
/// "Coupons" tab. Applied on every purchase surface: Membership Hub
/// self-checkout, and the coach/owner Purchase for Client flow (see
/// profile_tab.dart's "Purchase for client" entry point).
class ManageCouponsScreen extends ConsumerStatefulWidget {
  const ManageCouponsScreen({super.key});

  @override
  ConsumerState<ManageCouponsScreen> createState() => _ManageCouponsScreenState();
}

class _ManageCouponsScreenState extends ConsumerState<ManageCouponsScreen> {
  Coupon? _editing;
  bool _creating = false;

  Future<void> _delete(Coupon c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text('Delete "${c.code}"?'),
        content: const Text("This removes the code from every purchase surface immediately. Past purchases that already used it are unaffected."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Yes, delete it")),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await SupabaseService.deleteCoupon(c.id);
      ref.read(couponsProvider.notifier).remove(c.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't delete — check your connection and try again.")),
        );
      }
      return;
    }
    if (mounted) setState(() => _editing = null);
  }

  @override
  Widget build(BuildContext context) {
    final coupons = ref.watch(couponsProvider);

    if (_editing != null || _creating) {
      final editing = _editing;
      return LocalBackScope(
        isOpen: true,
        onBack: () => setState(() {
          _editing = null;
          _creating = false;
        }),
        child: _CouponEditForm(
          initial: editing,
          existingCodes: coupons.where((c) => c.id != editing?.id).map((c) => c.code.toUpperCase()).toSet(),
          onCancel: () => setState(() {
            _editing = null;
            _creating = false;
          }),
          onSave: (c) async {
            try {
              await SupabaseService.upsertCoupon(c);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Couldn't save — check your connection and try again.")),
                );
              }
              return;
            }
            ref.read(couponsProvider.notifier).upsert(c);
            setState(() {
              _editing = null;
              _creating = false;
            });
          },
          onDelete: editing == null ? null : () => _delete(editing),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel("Coupons"),
          const SizedBox(height: 8),
          const HintBox(
            text: "Reusable discount codes a client can enter at checkout, or a coach/owner can apply when purchasing a plan on a client's behalf.",
          ),
          const SizedBox(height: 10),
          if (coupons.isEmpty) const HintBox(text: "No coupon codes yet — add one below."),
          ...coupons.map((c) {
            return AppCard(
              onTap: () => setState(() => _editing = c),
              child: Opacity(
                opacity: c.archived ? 0.55 : 1,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  c.code,
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, letterSpacing: 0.5),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (c.archived) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: AppColors.line, borderRadius: BorderRadius.circular(5)),
                                  child: Text("Inactive", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.mute)),
                                ),
                              ],
                            ],
                          ),
                          Text(c.durationLabel, style: TextStyle(fontSize: 11, color: AppColors.mute)),
                        ],
                      ),
                    ),
                    Icon(LucideIcons.chevronRight, size: 15, color: AppColors.mute),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 6),
          BtnGold(
            full: true,
            onPressed: () => setState(() => _creating = true),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.plus, size: 15),
                SizedBox(width: 6),
                Text("Add New Coupon"),
              ],
            ),
          ),
          if (ref.watch(trainerAuthProvider) == "owner") ...[
            const SizedBox(height: 28),
            const _PackageRenewalOffer(),
          ],
        ],
      ),
    );
  }
}

class _CouponEditForm extends StatefulWidget {
  const _CouponEditForm({
    required this.initial,
    required this.existingCodes,
    required this.onCancel,
    required this.onSave,
    required this.onDelete,
  });
  final Coupon? initial;
  final Set<String> existingCodes;
  final VoidCallback onCancel;
  final ValueChanged<Coupon> onSave;
  final VoidCallback? onDelete;

  @override
  State<_CouponEditForm> createState() => _CouponEditFormState();
}

class _CouponEditFormState extends State<_CouponEditForm> {
  late final _code = TextEditingController(text: widget.initial?.code ?? "");
  late String _type = widget.initial?.type ?? "percent";
  late final _percent = TextEditingController(text: "${widget.initial?.percentOff ?? 10}");
  late final _flat = TextEditingController(text: widget.initial != null ? (widget.initial!.flatOffCents / 100).toStringAsFixed(2) : "");
  late bool _archived = widget.initial?.archived ?? false;
  late String _duration = widget.initial?.duration ?? couponDurationOnce;
  late final _months = TextEditingController(text: "${widget.initial?.durationInMonths ?? 3}");

  @override
  void dispose() {
    _code.dispose();
    _percent.dispose();
    _flat.dispose();
    _months.dispose();
    super.dispose();
  }

  String? get _codeError {
    final code = _code.text.trim();
    if (code.isEmpty) return null;
    if (widget.existingCodes.contains(code.toUpperCase())) return "That code already exists.";
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final codeError = _codeError;
    final canSave = _code.text.trim().isNotEmpty && codeError == null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BackBar(onBack: widget.onCancel, title: widget.initial != null ? "Edit Coupon" : "New Coupon"),
          const SizedBox(height: 12),
          FieldLabeled(
            label: "Code",
            child: AppField(kind: FieldKind.code,
              controller: _code,
              placeholder: "e.g. SUMMER10",
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (codeError != null) ...[
            const SizedBox(height: 6),
            Text(codeError, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
          ],
          const SizedBox(height: 10),
          Text("Discount type", style: TextStyle(color: AppColors.mute, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in const [("percent", "Percent off"), ("flat", "Flat amount off")])
                TapHighlight(
                  onTap: () => setState(() => _type = t.$1),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _type == t.$1 ? AppColors.gold : AppColors.line),
                      color: _type == t.$1 ? AppColors.gold : AppColors.bg,
                    ),
                    child: Text(t.$2, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _type == t.$1 ? AppColors.onGold : AppColors.txt)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_type == "percent")
            FieldLabeled(
              label: "Percent off",
              child: AppField(controller: _percent, keyboardType: TextInputType.number),
            )
          else
            FieldLabeled(
              label: "Flat amount off (\$)",
              child: AppField(controller: _flat, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
            ),
          const SizedBox(height: 10),
          Text("Duration", style: TextStyle(color: AppColors.mute, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            "One time is the first membership payment. Every month keeps the discount on each bill. For N months stops after that many bills. A package takes the discount once.",
            style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in const [
                (couponDurationOnce, "One time"),
                (couponDurationForever, "Every month"),
                (couponDurationRepeating, "For N months"),
              ])
                TapHighlight(
                  onTap: () => setState(() => _duration = t.$1),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _duration == t.$1 ? AppColors.txt : AppColors.line),
                      color: _duration == t.$1 ? AppColors.txt : AppColors.bg,
                    ),
                    child: Text(
                      t.$2,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _duration == t.$1 ? AppColors.bg : AppColors.txt,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (_duration == couponDurationRepeating) ...[
            const SizedBox(height: 10),
            FieldLabeled(
              label: "Months",
              child: AppField(controller: _months, keyboardType: TextInputType.number, onChanged: (_) => setState(() {})),
            ),
          ],
          const SizedBox(height: 10),
          AppCard(
            child: TapHighlight(
              onTap: () => setState(() => _archived = !_archived),
              child: Row(
                children: [
                  const Expanded(child: Text("Active", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                  Icon(!_archived ? LucideIcons.toggleRight : LucideIcons.toggleLeft, size: 30, color: !_archived ? AppColors.gold : AppColors.mute),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: BtnGold(
                  onPressed: !canSave
                      ? null
                      : () => widget.onSave(
                          Coupon(
                            id: widget.initial?.id ?? "coupon-${DateTime.now().microsecondsSinceEpoch}",
                            code: _code.text.trim().toUpperCase(),
                            type: _type,
                            percentOff: (int.tryParse(_percent.text.trim()) ?? 0).clamp(0, 100),
                            flatOffCents: (((double.tryParse(_flat.text.trim()) ?? 0) * 100).round()).clamp(0, 1 << 31),
                            archived: _archived,
                            duration: _duration,
                            durationInMonths: (int.tryParse(_months.text.trim()) ?? 1).clamp(1, 36),
                          ),
                        ),
                  child: const Text("Save"),
                ),
              ),
              const SizedBox(width: 8),
              BtnGhost(onPressed: widget.onCancel, child: const Text("Cancel")),
            ],
          ),
          if (widget.onDelete != null) ...[
            const SizedBox(height: 10),
            TextButton(
              onPressed: widget.onDelete,
              style: TextButton.styleFrom(foregroundColor: AppColors.errorText),
              child: const Text("Delete coupon"),
            ),
          ],
        ],
      ),
    );
  }
}

/// Owner-only block under Coupons. Coaches never reach Customize Platform,
/// and this block is also omitted unless the signed-in person is the owner.
class _PackageRenewalOffer extends ConsumerStatefulWidget {
  const _PackageRenewalOffer();

  @override
  ConsumerState<_PackageRenewalOffer> createState() => _PackageRenewalOfferState();
}

class _PackageRenewalOfferState extends ConsumerState<_PackageRenewalOffer> {
  late bool _enabled;
  final _percent = TextEditingController();
  final _sessions = TextEditingController();
  bool _dirty = false;
  bool _saving = false;
  bool _saved = false;
  bool _applying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(platformSettingsProvider);
    _enabled = settings.renewalDiscountEnabled;
    _percent.text = "${settings.renewalDiscountPercent}";
    _sessions.text = "${settings.renewalDiscountSessions}";
  }

  @override
  void dispose() {
    _percent.dispose();
    _sessions.dispose();
    super.dispose();
  }

  void _apply(PlatformSettings settings) {
    _applying = true;
    _enabled = settings.renewalDiscountEnabled;
    _percent.text = "${settings.renewalDiscountPercent}";
    _sessions.text = "${settings.renewalDiscountSessions}";
    _dirty = false;
    _error = null;
    _applying = false;
  }

  void _touch() {
    if (_applying) return;
    setState(() {
      _dirty = true;
      _saved = false;
      _error = null;
    });
  }

  String? _validationError() {
    final percent = int.tryParse(_percent.text.trim());
    if (percent == null || percent < kRenewDiscountPercentMin || percent > kRenewDiscountPercentMax) {
      return "Enter a percent from $kRenewDiscountPercentMin to $kRenewDiscountPercentMax.";
    }
    final sessions = int.tryParse(_sessions.text.trim());
    if (sessions == null || sessions < kRenewDiscountSessionsMin || sessions > kRenewDiscountSessionsMax) {
      return "Enter sessions left from $kRenewDiscountSessionsMin to $kRenewDiscountSessionsMax. At 2 left, the reminder is full price.";
    }
    return null;
  }

  Future<void> _save() async {
    final problem = _validationError();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final percent = int.parse(_percent.text.trim());
    final sessions = int.parse(_sessions.text.trim());
    setState(() {
      _saving = true;
      _error = null;
    });
    final prev = ref.read(platformSettingsProvider);
    final next = prev.copyWith(
      renewalDiscountEnabled: _enabled,
      renewalDiscountPercent: percent,
      renewalDiscountSessions: sessions,
    );
    try {
      await SupabaseService.savePlatformSettings(prev, next);
      ref.read(platformSettingsProvider.notifier).update((_) => next);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _saved = true;
      });
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't save — check your connection and try again.");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PlatformSettings>(platformSettingsProvider, (prev, next) {
      if (!_dirty && !_saving) setState(() => _apply(next));
    });
    final problem = _validationError();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel("Package renewal offer"),
        const HintBox(
          text: "When a session package is running low, the client can renew it at this discount. Turn it off and they are not offered a discount. The reminder at 2 sessions left stays full price either way. If they tap Not now, that package does not get the discount later.",
        ),
        const SizedBox(height: 10),
        AppCard(
          child: TapHighlight(
            onTap: () => setState(() {
              _enabled = !_enabled;
              _dirty = true;
              _saved = false;
              _error = null;
            }),
            child: Row(
              children: [
                const Expanded(child: Text("Discount on package renewal", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                Icon(_enabled ? LucideIcons.toggleRight : LucideIcons.toggleLeft, size: 30, color: _enabled ? AppColors.gold : AppColors.mute),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        FieldLabeled(
          label: "Discount percent",
          child: AppField(
            controller: _percent,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => _touch(),
          ),
        ),
        const SizedBox(height: 4),
        Text("A whole number from $kRenewDiscountPercentMin to $kRenewDiscountPercentMax.", style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4)),
        const SizedBox(height: 10),
        FieldLabeled(
          label: "Sessions left when the discount starts",
          child: AppField(
            controller: _sessions,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => _touch(),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          "The discount shows from this many sessions left, down to 3. At 2 sessions left the reminder is full price.",
          style: TextStyle(fontSize: 11, color: AppColors.mute, height: 1.4),
        ),
        if (problem != null && _dirty) ...[
          const SizedBox(height: 8),
          Text(problem, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
        ],
        if (_error != null && _error != problem) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
        ],
        if (_saved && !_dirty) ...[
          const SizedBox(height: 8),
          Text("Saved. This is the offer clients see from now on.", style: TextStyle(color: AppColors.success, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
        const SizedBox(height: 12),
        BtnGold(
          full: true,
          onPressed: _saving || problem != null ? null : _save,
          child: Text(_saving ? "Saving…" : "Save"),
        ),
      ],
    );
  }
}
