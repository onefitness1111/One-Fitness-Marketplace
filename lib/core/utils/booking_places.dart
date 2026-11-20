import "../../data/models/trainer.dart";
import "../../data/providers/platform_settings_provider.dart";
import "address_utils.dart";
import "booking_utils.dart";

/// One physical place a client can book at.
///
/// Built from coaches' saved training locations and from the location name
/// on a session or availability block. Two coaches at the same street are
/// one option.
class BookablePlace {
  const BookablePlace({
    required this.id,
    required this.label,
    required this.address,
    required this.aliases,
  });

  /// Stable enough to remember on this phone. Same street, or the same
  /// coordinates, keeps the same id.
  final String id;

  /// Gym or location name when one was entered, otherwise "City, ST".
  final String label;

  /// The full address line. Empty when only a name is known.
  final String address;
  final Set<String> aliases;

  bool matches(String raw) {
    final needle = raw.trim().toLowerCase();
    if (needle.isEmpty) return false;
    return aliases.any((alias) => alias.trim().toLowerCase() == needle);
  }
}

const bookingPlaceAll = "all";

String bookingPlacePrefKey(String userId) => "booking_place:$userId";

/// Street-type abbreviations folded to one spelling, after case, spacing,
/// and punctuation are already gone.
const _streetWords = {
  "st": "street",
  "str": "street",
  "ave": "avenue",
  "av": "avenue",
  "blvd": "boulevard",
  "rd": "road",
  "dr": "drive",
  "ln": "lane",
  "ct": "court",
  "hwy": "highway",
  "pkwy": "parkway",
  "pl": "place",
  "ter": "terrace",
  "trl": "trail",
};

String normalizePlaceText(String raw) {
  final cleaned = raw.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), " ");
  return cleaned
      .split(" ")
      .where((word) => word.isNotEmpty)
      .map((word) => _streetWords[word] ?? word)
      .join(" ");
}

String _addressKey(String address) {
  final parts = AddressParts.parse(address);
  final street = normalizePlaceText(parts.street.isEmpty ? address : parts.street);
  final city = normalizePlaceText(parts.city);
  final state = normalizePlaceText(stateCode(parts.state));
  if (street.isEmpty && city.isEmpty) return "";
  return "$street|$city|$state";
}

String _geoKey(double lat, double lng) => "${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}";

class _Draft {
  _Draft({required this.name, required this.address, this.lat, this.lng});

  final String name;
  final String address;
  final double? lat;
  final double? lng;
}

class _Group {
  _Group({required this.id});

  final String id;
  final names = <String>{};
  String address = "";
  String? addrKey;
  String? geoKey;
}

/// Every place a client can filter by, one row per physical location.
List<BookablePlace> bookablePlaces({
  required List<Trainer> trainers,
  List<GymLocation> gymLocations = const [],
}) {
  final gymByName = <String, GymLocation>{
    for (final gym in gymLocations)
      if (gym.name.trim().isNotEmpty) gym.name.trim().toLowerCase(): gym,
  };
  final drafts = <_Draft>[];

  void addDraft(String name, String address, double? lat, double? lng) {
    if (name.trim().isEmpty && address.trim().isEmpty) return;
    drafts.add(_Draft(name: name.trim(), address: address.trim(), lat: lat, lng: lng));
  }

  for (final trainer in trainers) {
    if (trainer.locations.isNotEmpty) {
      for (final loc in trainer.locations) {
        addDraft(loc.name, loc.address ?? "", loc.lat, loc.lng);
      }
    } else {
      addDraft(trainer.locationName ?? "", trainer.locationAddress ?? "", null, null);
    }
    for (final block in trainer.availability) {
      final named = (block.locationName ?? "").trim();
      if (named.isEmpty) continue;
      final gym = gymByName[named.toLowerCase()];
      addDraft(named, gym?.address ?? "", gym?.lat, gym?.lng);
    }
  }

  final groups = <_Group>[];
  for (final draft in drafts) {
    final addrKey = draft.address.isEmpty ? "" : _addressKey(draft.address);
    final geoKey = draft.lat != null && draft.lng != null ? _geoKey(draft.lat!, draft.lng!) : "";
    _Group? group;
    for (final existing in groups) {
      final sameGeo = geoKey.isNotEmpty && existing.geoKey == geoKey;
      final sameAddr = addrKey.isNotEmpty && existing.addrKey == addrKey;
      if (sameGeo || sameAddr) {
        group = existing;
        break;
      }
    }
    group ??= _Group(id: geoKey.isNotEmpty ? "geo:$geoKey" : "addr:${addrKey.isEmpty ? normalizePlaceText(draft.name) : addrKey}");
    if (draft.name.isNotEmpty) group.names.add(draft.name);
    if (draft.address.length > group.address.length) group.address = draft.address;
    if (addrKey.isNotEmpty) group.addrKey = addrKey;
    if (geoKey.isNotEmpty) group.geoKey = geoKey;
    if (!groups.contains(group)) groups.add(group);
  }

  final places = [for (final group in groups) _placeFrom(group)];
  places.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return places;
}

BookablePlace _placeFrom(_Group group) {
  final parts = AddressParts.parse(group.address);
  final streetKey = normalizePlaceText(parts.street);
  String? gymName;
  for (final name in group.names) {
    if (normalizePlaceText(name) == streetKey && streetKey.isNotEmpty) continue;
    gymName = name;
    break;
  }
  final city = parts.city.trim();
  final state = stateCode(parts.state);
  final cityLine = [city, state].where((part) => part.isNotEmpty).join(", ");
  final label = (gymName ?? "").trim().isNotEmpty
      ? gymName!.trim()
      : (cityLine.isNotEmpty ? cityLine : (parts.street.trim().isNotEmpty ? parts.street.trim() : group.names.first));
  return BookablePlace(
    id: group.id,
    label: label,
    address: group.address,
    aliases: {...group.names, if (group.address.isNotEmpty) group.address, label},
  );
}

/// Whether this session is held at [place].
///
/// A session that names a location must match that place. A session with no
/// location of its own is at the coach's saved training location, or at the
/// gym default when the coach never set one.
bool offeringAtPlace(Trainer trainer, Offering offering, BookablePlace place, {String? gymDefaultName}) {
  final named = (offering.locationName ?? "").trim();
  if (named.isNotEmpty) return place.matches(named);
  final own = _coachLocationNames(trainer);
  if (own.any(place.matches)) return true;
  if (own.isEmpty && gymDefaultName != null && place.matches(gymDefaultName)) return true;
  return false;
}

List<String> _coachLocationNames(Trainer trainer) {
  final fromList = [
    for (final loc in trainer.locations)
      if (loc.name.trim().isNotEmpty) loc.name.trim(),
  ];
  if (fromList.isNotEmpty) return fromList;
  final single = (trainer.locationName ?? "").trim();
  return single.isEmpty ? const [] : [single];
}
