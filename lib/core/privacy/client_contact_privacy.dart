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
    final line = address["line1"]?.toString().trim() ?? "";
    final zip = (address["postal_code"] ?? address["postalCode"])?.toString().trim() ?? "";
    if (line.isNotEmpty || zip.isNotEmpty) return true;
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
