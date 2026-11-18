import "../../data/models/billing_address.dart";

const usStateCodes = {
  "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "DC", "FL",
  "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME",
  "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH",
  "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI",
  "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
};

/// What is wrong with [address], or null when it can be saved and sent to Stripe.
String? billingAddressError(BillingAddress address) {
  if (address.name.trim().isEmpty) return "Enter the name on the billing address.";
  if (address.line1.trim().isEmpty) return "Enter the street address.";
  if (address.city.trim().isEmpty) return "Enter the city.";
  final country = address.country.trim().toUpperCase();
  if (country.isEmpty) return "Enter the country.";
  if (country == "US") {
    final state = address.state.trim().toUpperCase();
    if (!usStateCodes.contains(state)) return "Enter a two-letter US state, like CA.";
    final zip = address.postalCode.trim();
    if (!RegExp(r"^\d{5}(-\d{4})?$").hasMatch(zip)) {
      return "Enter a 5-digit ZIP code, or 9 digits with a dash.";
    }
  } else if (address.state.trim().isEmpty || address.postalCode.trim().isEmpty) {
    return "Enter the state and postal code.";
  }
  return null;
}

/// Fills a billing form from the saved address, or from the older city and state.
BillingAddress billingAddressPrefill({
  BillingAddress? saved,
  String? city,
  String? state,
  String? name,
}) {
  if (saved != null) {
    return BillingAddress(
      name: saved.name.trim().isEmpty ? (name ?? "") : saved.name,
      line1: saved.line1,
      line2: saved.line2,
      city: saved.city.trim().isEmpty ? (city ?? "") : saved.city,
      state: saved.state.trim().isEmpty ? (state ?? "") : saved.state,
      postalCode: saved.postalCode,
      country: saved.country.trim().isEmpty ? "US" : saved.country,
    );
  }
  return BillingAddress(
    name: name ?? "",
    line1: "",
    city: city ?? "",
    state: state ?? "",
    postalCode: "",
    country: "US",
  );
}
