import "../../data/models/client_info.dart";
import "../../data/models/client_record.dart";
import "../../data/models/intake_schema.dart";
import "attention_utils.dart";

/// Which program a new filing of [assessmentKey] asks the owner to replace.
/// Null for a form that does not drive a program.
String? programRefreshKind(String assessmentKey) => switch (assessmentKey) {
      "personalTraining" || "physical" => "training",
      "nutritional" => "nutrition",
      _ => null,
    };

/// Owner copy names the program. Everyone else gets a neutral line, with
/// no mention of how the program is drafted.
String programRefreshLabel(String kind, {required bool forOwner}) {
  if (!forOwner) return "Program update pending";
  return kind == "nutrition"
      ? "New nutrition program needed"
      : "New training program needed";
}

/// Shown when an intake save fails. The save is all-or-nothing, so the
/// earlier answers are still on record and trying again is safe.
const intakeSaveFailedMessage =
    "Couldn't save. Nothing was changed, and the earlier answers are still on file. Please try again.";

/// A correction of the filing already on record does not ask for a new
/// program. The first completion does, and so does an explicit resubmit.
bool shouldFlagProgramRefresh({
  required bool keepPrevious,
  required bool alreadyCompleted,
}) =>
    keepPrevious || !alreadyCompleted;

/// The new filing becomes current. A completed filing that was already
/// there moves onto history. A draft that was never finished is replaced.
IntakeRecord archiveOnResubmit(IntakeRecord? current, IntakeRecord next) {
  if (current == null || !current.completed) {
    return next.copyWith(history: current?.history ?? const []);
  }
  return current.supersededBy(next);
}

/// What program generation is allowed to read: the current answers only.
Map<String, dynamic> intakeAnswersForAi(IntakeRecord? record) {
  if (record == null || !record.completed) return const {};
  return record.answers;
}

/// Newest filing that has not been archived. History entries are archived.
IntakeSubmission? primarySubmission(List<IntakeSubmission> rows) {
  final open = rows.where((row) => row.archivedAt == null).toList()
    ..sort((a, b) => (b.at ?? "").compareTo(a.at ?? ""));
  return open.isEmpty ? null : open.first;
}

class IntakeJourneyLine {
  const IntakeJourneyLine({
    required this.at,
    required this.title,
    required this.by,
    required this.archived,
  });

  final String at;
  final String title;
  final String by;
  final bool archived;
}

/// Every filing of every form, current and archived, newest first.
List<IntakeJourneyLine> intakeJourneyLines(
  Map<String, IntakeRecord> intake,
  String Function(String key) titleFor,
) {
  final lines = <IntakeJourneyLine>[];
  for (final entry in intake.entries) {
    final title = titleFor(entry.key);
    final current = entry.value;
    if (current.completed) {
      lines.add(IntakeJourneyLine(
        at: current.at ?? "",
        title: "Updated $title",
        by: current.by ?? "Client",
        archived: false,
      ));
    }
    for (final past in current.history) {
      lines.add(IntakeJourneyLine(
        at: past.at ?? "",
        title: "Updated $title",
        by: past.by ?? "Client",
        archived: true,
      ));
    }
  }
  lines.sort((a, b) => b.at.compareTo(a.at));
  return lines;
}

/// Owner sees which program is needed. A coach sees one neutral line.
List<AttentionItem> programRefreshAttention(
  List<ClientInfo> roster,
  Map<String, ClientRecord> records, {
  required bool forOwner,
}) {
  final out = <AttentionItem>[];
  for (final client in roster) {
    final flags = records[client.id]?.programRefresh ?? const {};
    if (flags.isEmpty) continue;
    if (!forOwner) {
      out.add(AttentionItem(clientId: client.id, key: "program-refresh", label: "Program update pending"));
      continue;
    }
    if (flags.containsKey("training")) {
      out.add(AttentionItem(clientId: client.id, key: "program-refresh-training", label: "New training program needed"));
    }
    if (flags.containsKey("nutrition")) {
      out.add(AttentionItem(clientId: client.id, key: "program-refresh-nutrition", label: "New nutrition program needed"));
    }
  }
  return out;
}
