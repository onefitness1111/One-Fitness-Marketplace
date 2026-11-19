/// A client's billing address, stored on `clients.billing_address`.
class BillingAddress {
  const BillingAddress({
    this.name = "",
    required this.line1,
    this.line2 = "",
    required this.city,
    required this.state,
    required this.postalCode,
    this.country = "US",
  });

  final String name;
  final String line1;
  final String line2;
  final String city;
  final String state;
  final String postalCode;
  final String country;

  /// Enough for Stripe to accept it as a billing address.
  bool get isComplete =>
      line1.trim().isNotEmpty && city.trim().isNotEmpty && state.trim().isNotEmpty && postalCode.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        "name": name.trim(),
        "line1": line1.trim(),
        "line2": line2.trim(),
        "city": city.trim(),
        "state": state.trim(),
        "postal_code": postalCode.trim(),
        "country": country.trim().isEmpty ? "US" : country.trim().toUpperCase(),
      };

  /// A stored row, even when the street is still blank. City and state from
  /// the older profile fields are enough to prefill the form.
  static BillingAddress? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final country = raw["country"]?.toString().trim() ?? "";
    return BillingAddress(
      name: raw["name"]?.toString() ?? "",
      line1: raw["line1"]?.toString() ?? "",
      line2: raw["line2"]?.toString() ?? "",
      city: raw["city"]?.toString() ?? "",
      state: raw["state"]?.toString() ?? "",
      postalCode: raw["postal_code"]?.toString() ?? raw["postalCode"]?.toString() ?? "",
      country: country.isEmpty ? "US" : country.toUpperCase(),
    );
  }

  static BillingAddress? fromJson(Object? raw) {
    final a = tryParse(raw);
    return a != null && a.isComplete ? a : null;
  }
}
