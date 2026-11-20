/// Share of a coach's distinct checked-in clients who have come back.
/// Hidden until at least five different clients have a completed visit.
int? rebookPercent({required int distinctClients, required int clientsWithTwoOrMore}) {
  if (distinctClients < 5) return null;
  if (clientsWithTwoOrMore < 0) return null;
  return ((100 * clientsWithTwoOrMore) / distinctClients).round();
}

class CoachReviewSummary {
  const CoachReviewSummary({required this.stars, this.rebookPercent});

  final StarCounts stars;
  final int? rebookPercent;
}

class CoachReviewLine {
  const CoachReviewLine({required this.stars, this.body, this.createdAt});

  final int stars;
  final String? body;
  final DateTime? createdAt;
}

class StarCounts {
  const StarCounts({this.one = 0, this.two = 0, this.three = 0, this.four = 0, this.five = 0});

  final int one;
  final int two;
  final int three;
  final int four;
  final int five;

  int get total => one + two + three + four + five;

  int countFor(int stars) => switch (stars) {
        5 => five,
        4 => four,
        3 => three,
        2 => two,
        1 => one,
        _ => 0,
      };

  double fraction(int stars) {
    if (total == 0) return 0;
    return countFor(stars) / total;
  }

  bool get showStars => total >= 3;

  double? get average {
    if (total == 0) return null;
    return (1 * one + 2 * two + 3 * three + 4 * four + 5 * five) / total;
  }
}
