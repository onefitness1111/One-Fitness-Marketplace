import "../../data/models/program_day.dart";

DateTime dateOnly(DateTime day) => DateTime(day.year, day.month, day.day);

/// Monday of the week that contains [day].
DateTime weekStart(DateTime day) {
  final d = dateOnly(day);
  return d.subtract(Duration(days: d.weekday - 1));
}

/// Program days are not tied to a calendar date, so they repeat across the
/// week in order, starting Monday.
ProgramDay? programDayOn(List<ProgramDay> days, DateTime date) {
  if (days.isEmpty) return null;
  return days[(date.weekday - 1) % days.length];
}
