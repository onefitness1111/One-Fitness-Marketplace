import "../payments/billing_address_rules.dart";
import "../../data/models/billing_address.dart";

/// What a viewer is allowed to learn about a client's phone and billing address.
class ClientContactView {
  const ClientContactView({
    required this.phoneOnFile,
    required this.billingOnFile,
    this.phone,
    this.address,
  });

  final bool phoneOnFile;
  final bool billingOnFile;

  /// Null when this viewer must not see the number. Never a blank that was
  /// copied from a real number.
  final String? phone;
  final BillingAddress? address;

  bool get canRead => phone != null || address != null || (!phoneOnFile && !billingOnFile && phone == null);
}

/// Who is looking at a billing address.
enum BillingViewer { client, owner, coach }

/// What that person may see and change.
///
/// A coach never receives the street, name, apartment, or ZIP. [full] is
/// omitted for a coach even when the caller passed a complete address in.
class BillingAddressAccess {
  const BillingAddressAccess({
    required this.viewer,
    required this.onFile,
    this.full,
    this.city,
    this.state,
  });

  final BillingViewer viewer;
  final bool onFile;
  final BillingAddress? full;
  final String? city;
  final String? state;

  bool get canReadFull => viewer != BillingViewer.coach;

  /// The client and the owner can replace an address that is already saved.
  bool get canEdit => canReadFull && onFile;

  /// Anyone can enter the first address. A coach loses this once one is saved.
  bool get canAdd => !onFile;
}

String? _blankToNull(String? value) {
  final trimmed = value?.trim() ?? "";
  return trimmed.isEmpty ? null : trimmed;
}

/// City and state, like "Burbank, CA". Nothing else.
String? localityLabel(String? city, String? state) {
  final c = city?.trim() ?? "";
  final s = state?.trim() ?? "";
  if (c.isEmpty && s.isEmpty) return null;
  if (c.isEmpty) return s;
  if (s.isEmpty) return c;
  return "$c, $s";
}

/// The lines a client or the owner may read.
String formatBillingAddress(BillingAddress address) {
  final region = [address.state.trim(), address.postalCode.trim()].where((part) => part.isNotEmpty).join(" ");
  final cityLine = [address.city.trim(), region].where((part) => part.isNotEmpty).join(", ");
  final country = address.country.trim();
  return [
    if (address.name.trim().isNotEmpty) address.name.trim(),
    if (address.line1.trim().isNotEmpty) address.line1.trim(),
    if (address.line2.trim().isNotEmpty) address.line2.trim(),
    if (cityLine.isNotEmpty) cityLine,
    if (country.isNotEmpty && country.toUpperCase() != "US") country,
  ].join("\n");
}

BillingAddressAccess billingAccessFor({
  required BillingViewer viewer,
  required bool onFile,
  BillingAddress? full,
  String? city,
  String? state,
}) {
  if (viewer == BillingViewer.coach) {
    return BillingAddressAccess(
      viewer: viewer,
      onFile: onFile,
      city: onFile ? _blankToNull(city ?? full?.city) : null,
      state: onFile ? _blankToNull(state ?? full?.state) : null,
    );
  }
  return BillingAddressAccess(
    viewer: viewer,
    onFile: onFile,
    full: onFile ? full : null,
    city: _blankToNull(full?.city ?? city),
    state: _blankToNull(full?.state ?? state),
  );
}

/// "Not on file", "Burbank, CA", or the full address. A coach summary never
/// includes the name, street, apartment, or ZIP.
String billingSummary(BillingAddressAccess access) {
  if (!access.onFile) return "Not on file";
  if (access.canReadFull && access.full != null && access.full!.line1.trim().isNotEmpty) {
    return formatBillingAddress(access.full!);
  }
  return localityLabel(access.city, access.state) ?? "On file";
}

class AddressCommit {
  const AddressCommit({this.gate, this.error});
  final BillingGate? gate;
  final String? error;
}

class BillingGate {
  const BillingGate({required this.cancelled, this.address, this.storedOnFile = false});

  final bool cancelled;
  final BillingAddress? address;

  /// The address is already saved and this viewer must not receive it.
  final bool storedOnFile;

  bool get proceed => !cancelled && (address != null || storedOnFile);
}

/// Saves a first or replacement address, or lets a coach continue once one
/// is already on file without handing the street back.
Future<AddressCommit> commitAddressStep({
  required BillingViewer viewer,
  required bool onFile,
  BillingAddress? draft,
  required Future<void> Function(BillingAddress address) save,
}) async {
  if (viewer == BillingViewer.coach && onFile) {
    return const AddressCommit(gate: BillingGate(cancelled: false, storedOnFile: true));
  }
  final problem = draft == null ? "Enter the billing address." : billingAddressError(draft);
  if (problem != null) return AddressCommit(error: problem);
  try {
    await save(draft!);
  } catch (error) {
    final message = error.toString();
    if (message.contains("already on file")) {
      return const AddressCommit(error: "A billing address is already on file.");
    }
    return const AddressCommit(error: "Couldn't save that address.");
  }
  return AddressCommit(gate: BillingGate(cancelled: false, address: draft));
}

/// Coaches get the on-file flags only. The client and the owner get the values.
ClientContactView clientContactForViewer({
  required bool viewerIsOwner,
  required bool viewerIsClient,
  required bool phoneOnFile,
  required bool billingOnFile,
  String? phone,
  BillingAddress? address,
}) {
  final canRead = viewerIsOwner || viewerIsClient;
  return ClientContactView(
    phoneOnFile: phoneOnFile,
    billingOnFile: billingOnFile,
    phone: canRead ? phone : null,
    address: canRead ? address : null,
  );
}

/// A coach's save is allowed, and the answer that comes back has no number
/// and no street. The flags say only whether something is now on file.
ClientContactView afterCoachWrite({
  required bool wrotePhone,
  required bool wroteAddress,
  required bool phoneWasOnFile,
  required bool addressWasOnFile,
}) {
  return ClientContactView(
    phoneOnFile: wrotePhone || phoneWasOnFile,
    billingOnFile: wroteAddress || addressWasOnFile,
  );
}

/// True when a payload meant for a coach still contains a phone or a street.
bool leaksPrivateContact(Map<String, dynamic> payload) {
  final phone = payload["phone"]?.toString().trim() ?? "";
  if (phone.isNotEmpty) return true;
  final address = payload["address"] ?? payload["billing_address"] ?? payload["billingAddress"];
  if (address is Map) {
    final name = address["name"]?.toString().trim() ?? "";
    final line = address["line1"]?.toString().trim() ?? "";
    final line2 = address["line2"]?.toString().trim() ?? "";
    final zip = (address["postal_code"] ?? address["postalCode"])?.toString().trim() ?? "";
    if (name.isNotEmpty || line.isNotEmpty || line2.isNotEmpty || zip.isNotEmpty) return true;
  }
  if (address is String && address.trim().isNotEmpty) return true;
  return false;
}

String onFileLabel(bool onFile) => onFile ? "On file" : "Not on file";

/// Broadcast and chat previews for a coach must not carry a client's number,
/// even when the roster row still has one.
String? phoneForViewer({required bool viewerIsOwner, required bool viewerIsClient, String? phone}) {
  if (viewerIsOwner || viewerIsClient) return phone;
  return null;
}
