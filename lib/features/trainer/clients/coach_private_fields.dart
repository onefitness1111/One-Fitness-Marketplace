import "package:flutter/material.dart";
import "../../../core/payments/billing_address_rules.dart";
import "../../../core/privacy/client_contact_privacy.dart";
import "../../../core/supabase/supabase_service.dart";
import "../../../core/theme/app_colors.dart";
import "../../../core/widgets/billing_address_form.dart";
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
  const CoachPrivateAddress({super.key, required this.clientId, this.clientName});
  final String clientId;
  final String? clientName;

  @override
  State<CoachPrivateAddress> createState() => _CoachPrivateAddressState();
}

class _CoachPrivateAddressState extends State<CoachPrivateAddress> {
  bool? _onFile;
  String? _city;
  String? _state;
  bool _editing = false;
  bool _busy = false;
  String? _error;
  BillingAddress? _draft;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final flags = await SupabaseService.clientFileFlags(widget.clientId);
    final onFile = flags?.billingOnFile ?? false;
    String? city;
    String? state;
    if (onFile) {
      final locality = await SupabaseService.loadBillingLocality(widget.clientId);
      city = locality?.city;
      state = locality?.state;
    }
    if (mounted) {
      setState(() {
        _onFile = onFile;
        _city = city;
        _state = state;
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await commitAddressStep(
      viewer: BillingViewer.coach,
      onFile: _onFile ?? false,
      draft: _draft,
      save: (address) => SupabaseService.saveBillingAddress(widget.clientId, address),
    );
    if (!mounted) return;
    if (result.error != null) {
      setState(() {
        _busy = false;
        // The server's sentence, such as "Only the owner can change an
        // address that's already on file."
        _error = result.error;
      });
      return;
    }
    setState(() {
      _busy = false;
      _editing = false;
      _onFile = true;
      _city = _draft?.city;
      _state = _draft?.state;
      _draft = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final access = billingAccessFor(
      viewer: BillingViewer.coach,
      onFile: _onFile ?? false,
      city: _city,
      state: _state,
    );
    return BillingAddressPanel(
      access: access,
      loading: _onFile == null,
      editing: _editing,
      busy: _busy,
      error: _error,
      initial: BillingAddress(name: widget.clientName ?? "", line1: "", city: "", state: "", postalCode: ""),
      onAdd: access.canAdd ? () => setState(() => _editing = true) : null,
      onChanged: (address) => _draft = address,
      onSave: _save,
    );
  }
}

/// Full billing address on the owner's Edit Profile. Prefilled when one is saved.
class OwnerBillingAddress extends StatefulWidget {
  const OwnerBillingAddress({super.key, required this.clientId, this.clientName});
  final String clientId;
  final String? clientName;

  @override
  State<OwnerBillingAddress> createState() => _OwnerBillingAddressState();
}

class _OwnerBillingAddressState extends State<OwnerBillingAddress> {
  BillingAddress? _saved;
  bool _loading = true;
  bool _editing = false;
  bool _busy = false;
  String? _error;
  BillingAddress? _draft;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await SupabaseService.loadBillingAddress(widget.clientId);
    if (!mounted) return;
    setState(() {
      _saved = saved;
      _loading = false;
    });
  }

  bool get _onFile => _saved != null && _saved!.line1.trim().isNotEmpty;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await commitAddressStep(
      viewer: BillingViewer.owner,
      onFile: _onFile,
      draft: _draft ?? _saved,
      save: (address) => SupabaseService.saveBillingAddress(widget.clientId, address),
    );
    if (!mounted) return;
    if (result.error != null || result.gate?.address == null) {
      setState(() {
        _busy = false;
        _error = result.error ?? "Enter the billing address.";
      });
      return;
    }
    setState(() {
      _busy = false;
      _editing = false;
      _saved = result.gate!.address;
      _draft = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final access = billingAccessFor(
      viewer: BillingViewer.owner,
      onFile: _onFile,
      full: _saved,
    );
    return BillingAddressPanel(
      access: access,
      loading: _loading,
      editing: _editing,
      busy: _busy,
      error: _error,
      initial: billingAddressPrefill(saved: _saved, name: widget.clientName),
      onAdd: () => setState(() => _editing = true),
      onEdit: () => setState(() => _editing = true),
      onChanged: (address) => _draft = address,
      onSave: _save,
    );
  }
}

/// The billing block on Edit Profile. Coaches get city and state, or Add
/// when nothing is saved. The owner gets the full address and Edit.
class BillingAddressPanel extends StatelessWidget {
  const BillingAddressPanel({
    super.key,
    required this.access,
    this.loading = false,
    this.editing = false,
    this.busy = false,
    this.error,
    this.initial,
    this.onAdd,
    this.onEdit,
    this.onChanged,
    this.onSave,
  });

  final BillingAddressAccess access;
  final bool loading;
  final bool editing;
  final bool busy;
  final String? error;
  final BillingAddress? initial;
  final VoidCallback? onAdd;
  final VoidCallback? onEdit;
  final ValueChanged<BillingAddress>? onChanged;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final summary = loading ? "Loading…" : billingSummary(access);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Billing address", style: TextStyle(color: AppColors.mute, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        if (!editing)
          Text(summary, style: TextStyle(color: AppColors.txt, fontWeight: FontWeight.w700, height: 1.35))
        else
          BillingAddressFields(initial: initial, onChanged: onChanged ?? (_) {}),
        const SizedBox(height: 6),
        if (!loading && !editing && access.canAdd && onAdd != null)
          BtnGhost(onPressed: onAdd, child: const Text("Add"))
        else if (!loading && !editing && access.canEdit && onEdit != null)
          BtnGhost(onPressed: onEdit, child: const Text("Edit")),
        if (editing) ...[
          const SizedBox(height: 6),
          BtnGold(onPressed: busy ? null : onSave, child: Text(busy ? "Saving…" : "Save address")),
        ],
        if (error != null) Text(error!, style: TextStyle(color: AppColors.errorText, fontSize: 12)),
      ],
    );
  }
}
