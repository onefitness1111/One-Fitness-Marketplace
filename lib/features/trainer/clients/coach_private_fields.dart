import "package:flutter/material.dart";
import "../../../core/payments/billing_address_rules.dart";
import "../../../core/privacy/client_contact_privacy.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/widgets.dart";
import "../../../data/models/billing_address.dart";

/// Phone for a coach: on file or not, and an empty box to replace it.
/// The saved number is never put back into the field.
class CoachPrivatePhone extends StatefulWidget {
  const CoachPrivatePhone({super.key, required this.clientId});
  final String clientId;

  @override
  State<CoachPrivatePhone> createState() => _CoachPrivatePhoneState();
}

class _CoachPrivatePhoneState extends State<CoachPrivatePhone> {
  bool? _onFile;
  bool _editing = false;
  bool _busy = false;
  final _phone = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final flags = await SupabaseService.clientFileFlags(widget.clientId);
    if (mounted) setState(() => _onFile = flags?.phoneOnFile ?? false);
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SupabaseService.setClientPhone(widget.clientId, _phone.text.trim());
      _phone.clear();
      if (mounted) {
        setState(() {
          _editing = false;
          _onFile = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't save that phone number.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Phone", style: TextStyle(color: AppColors.mute, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(onFileLabel(_onFile ?? false), style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        if (!_editing)
          BtnGhost(
            onPressed: () => setState(() => _editing = true),
            child: Text(_onFile == true ? "Update" : "Add"),
          )
        else ...[
          AppField(controller: _phone, kind: FieldKind.phone, placeholder: "New phone number"),
          const SizedBox(height: 6),
          BtnGold(onPressed: _busy ? null : _save, child: Text(_busy ? "Saving…" : "Save phone")),
        ],
        if (_error != null) Text(_error!, style: TextStyle(color: AppColors.txt, fontSize: 12)),
      ],
    );
  }
}

class CoachPrivateAddress extends StatefulWidget {
  const CoachPrivateAddress({super.key, required this.clientId});
  final String clientId;

  @override
  State<CoachPrivateAddress> createState() => _CoachPrivateAddressState();
}

class _CoachPrivateAddressState extends State<CoachPrivateAddress> {
  bool? _onFile;
  bool _editing = false;
  bool _busy = false;
  String? _error;
  final _name = TextEditingController();
  final _line1 = TextEditingController();
  final _line2 = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _zip = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _line1.dispose();
    _line2.dispose();
    _city.dispose();
    _state.dispose();
    _zip.dispose();
    super.dispose();
  }

  BillingAddress get _draft => BillingAddress(
        name: _name.text,
        line1: _line1.text,
        line2: _line2.text,
        city: _city.text,
        state: _state.text,
        postalCode: _zip.text,
      );

  Future<void> _load() async {
    final flags = await SupabaseService.clientFileFlags(widget.clientId);
    if (mounted) setState(() => _onFile = flags?.billingOnFile ?? false);
  }

  Future<void> _save() async {
    final problem = billingAddressError(_draft);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SupabaseService.saveBillingAddress(widget.clientId, _draft);
      _name.clear();
      _line1.clear();
      _line2.clear();
      _city.clear();
      _state.clear();
      _zip.clear();
      if (mounted) {
        setState(() {
          _editing = false;
          _onFile = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't save that address.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Billing address", style: TextStyle(color: AppColors.mute, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(onFileLabel(_onFile ?? false), style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        if (!_editing)
          BtnGhost(
            onPressed: () => setState(() => _editing = true),
            child: Text(_onFile == true ? "Update" : "Add"),
          )
        else ...[
          AppField(controller: _name, kind: FieldKind.name, placeholder: "Name"),
          const SizedBox(height: 6),
          AppField(controller: _line1, kind: FieldKind.text, placeholder: "Street address"),
          const SizedBox(height: 6),
          AppField(controller: _line2, kind: FieldKind.text, placeholder: "Apt or suite (optional)"),
          const SizedBox(height: 6),
          AppField(controller: _city, kind: FieldKind.name, placeholder: "City"),
          const SizedBox(height: 6),
          AppField(controller: _state, kind: FieldKind.text, placeholder: "State"),
          const SizedBox(height: 6),
          AppField(controller: _zip, kind: FieldKind.text, placeholder: "ZIP code"),
          const SizedBox(height: 6),
          BtnGold(onPressed: _busy ? null : _save, child: Text(_busy ? "Saving…" : "Save address")),
        ],
        if (_error != null) Text(_error!, style: TextStyle(color: AppColors.txt, fontSize: 12)),
      ],
    );
  }
}
