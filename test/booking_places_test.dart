import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/utils/booking_places.dart";
import "package:onefitness/core/utils/booking_utils.dart";
import "package:onefitness/data/models/availability_block.dart";
import "package:onefitness/data/models/trainer.dart";
import "package:onefitness/data/providers/platform_settings_provider.dart";

Trainer _coach({
  required String id,
  String legal = "Legal Name",
  String coach = "Coach Chris",
  List<TrainerLocation> locations = const [],
  String? locationName,
  String? locationAddress,
  List<AvailabilityBlock> availability = const [],
}) {
  return Trainer(
    id: id,
    name: legal,
    coachName: coach,
    locationName: locationName,
    locationAddress: locationAddress,
    locations: locations,
    availability: availability,
  );
}

void main() {
  test("the same street is one location even when the abbreviation differs", () {
    final places = bookablePlaces(trainers: [
      _coach(
        id: "a",
        locations: const [
          TrainerLocation(id: "1", name: "Burbank Gym", address: "123 Main St, Burbank, CA 91502", lat: 34.1808, lng: -118.3090),
        ],
      ),
      _coach(
        id: "b",
        legal: "Other Person",
        coach: "Coach Sam",
        locations: const [
          TrainerLocation(id: "2", name: "Main Street Gym", address: "123 main street, burbank, ca", lat: 34.1808, lng: -118.3090),
        ],
      ),
    ]);

    expect(places, hasLength(1));
    expect(places.single.label, "Burbank Gym");
    expect(places.single.address, contains("123 Main St"));
    expect(places.single.label.contains("Legal"), isFalse);
    expect(places.single.address.contains("Legal"), isFalse);
  });

  test("two streets stay separate, and a name-only session location is included", () {
    final places = bookablePlaces(
      trainers: [
        _coach(
          id: "a",
          locations: const [TrainerLocation(id: "1", name: "North", address: "10 Oak Ave, Glendale, CA 91201")],
          availability: const [
            AvailabilityBlock(sessionType: "one-on-one", discipline: "personal-training", byDay: {}, locationName: "ONE Fitness"),
          ],
        ),
      ],
      gymLocations: const [GymLocation(name: "ONE Fitness", address: "500 Beach Rd, Santa Monica, CA 90401")],
    );

    expect(places, hasLength(2));
    expect(places.map((place) => place.label), containsAll(["North", "ONE Fitness"]));
    final santa = places.firstWhere((place) => place.label == "ONE Fitness");
    expect(santa.address, "500 Beach Rd, Santa Monica, CA 90401");
  });

  test("a chosen place keeps sessions and coaches at that location only", () {
    final trainers = [
      _coach(id: "here", locations: const [TrainerLocation(id: "1", name: "Burbank Gym", address: "123 Main St, Burbank, CA 91502")]),
      _coach(
        id: "away",
        coach: "Coach Sam",
        locations: const [TrainerLocation(id: "2", name: "Beach", address: "9 Ocean Blvd, Santa Monica, CA 90401")],
        availability: const [
          AvailabilityBlock(sessionType: "semi-private", discipline: "personal-training", byDay: {1: [600]}, locationName: "Beach"),
        ],
      ),
    ];
    final places = bookablePlaces(trainers: trainers);
    final burbank = places.firstWhere((place) => place.matches("Burbank Gym"));
    final here = Offering(sessionType: "semi-private", discipline: "personal-training", slot: 600, locationName: null);
    final tagged = Offering(sessionType: "semi-private", discipline: "personal-training", slot: 660, locationName: "Beach");
    final untaggedAway = Offering(sessionType: "semi-private", discipline: "personal-training", slot: 720);

    expect(offeringAtPlace(trainers[0], here, burbank), isTrue);
    expect(offeringAtPlace(trainers[1], tagged, burbank), isFalse);
    expect(offeringAtPlace(trainers[1], untaggedAway, burbank), isFalse);
  });

  test("a coach with no saved place still shows at the gym default", () {
    final trainer = _coach(id: "none");
    final places = bookablePlaces(
      trainers: [trainer],
      gymLocations: const [GymLocation(name: "ONE Fitness", address: "1 Gym Way, Burbank, CA 91502")],
    );
    expect(places, isEmpty);
    final fallback = const BookablePlace(id: "gym", label: "ONE Fitness", address: "1 Gym Way", aliases: {"ONE Fitness"});
    final open = Offering(sessionType: "semi-private", discipline: "personal-training", slot: 600);
    expect(offeringAtPlace(trainer, open, fallback, gymDefaultName: "ONE Fitness"), isTrue);
  });
}
