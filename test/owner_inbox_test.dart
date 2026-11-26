import "dart:io";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/chat/owner_inbox.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_record.dart";
import "package:onefitness/data/models/comm_message.dart";
import "package:onefitness/data/models/trainer.dart";
import "package:onefitness/data/providers/trainer_providers.dart";

void main() {
  final chris = DateTime(2026, 11, 21, 15, 40);
  final business = DateTime(2026, 11, 21, 14, 15);
  final avery = DateTime(2026, 11, 20, 9);

  const roster = [
    ClientInfo(id: "alex", name: "Alex Rivera"),
    ClientInfo(id: "jordan", name: "Jordan Lee"),
    ClientInfo(id: "sam", name: "Sam Patel"),
    ClientInfo(id: "quiet", name: "Quiet Client"),
  ];
  const coaches = [
    Trainer(id: "chris", name: "Christina Legal", coachName: "Coach Chris"),
    Trainer(id: "avery", name: "Avery Legal", coachName: "Coach Avery"),
  ];

  Map<String, List<CommMessage>> comms() => {
        "alex": [
          CommMessage(id: "1", who: "client", text: "See you at 6.", at: "", trainerId: "chris", createdAt: chris),
          CommMessage(
            id: "2",
            who: "trainer",
            text: "Bring shoes.",
            at: "",
            trainerId: "chris",
            createdAt: chris.subtract(const Duration(hours: 1)),
          ),
        ],
        "jordan": [
          CommMessage(
            id: "3",
            who: "client",
            text: "Got your text about tomorrow.",
            at: "",
            trainerId: "chris",
            routedTo: "business",
            createdAt: business,
            readByCoach: true,
          ),
        ],
        "sam": [
          CommMessage(
            id: "4",
            who: "trainer",
            text: "Your new program is in.",
            at: "",
            trainerId: "avery",
            createdAt: avery,
            readByCoach: true,
          ),
        ],
      };

  List<OwnerInboxRow> inbox({Set<String> unread = const {}}) => ownerClientThreads(
        roster: roster,
        commsByClient: comms(),
        coaches: coaches,
        ownerIds: {"owner-1"},
        unreadKeys: unread,
      );

  test("the owner sees every thread, newest first, with coach names", () {
    final rows = inbox();

    expect(rows.map((row) => row.title).toList(), ["Alex Rivera", "Jordan Lee", "Sam Patel"]);
    expect(rows.map((row) => row.coachLabel).toList(), ["Coach Chris", kOneFitnessLabel, "Coach Avery"]);
    expect(rows.first.preview, "See you at 6.");
    expect(rows.first.unread, isTrue);
    expect(rows[1].unread, isFalse);
    expect(rows.any((row) => row.coachLabel.contains("Legal")), isFalse);
    expect(rows.any((row) => row.title == "Quiet Client"), isFalse);
  });

  test("a text routed to the business stays with ONE Fitness", () {
    final jordan = inbox().firstWhere((row) => row.clientId == "jordan");
    expect(jordan.coachKey, kOwnerBusinessKey);
    expect(jordan.coachLabel, kOneFitnessLabel);
    final thread = messagesForOwnerThread(
      comms()["jordan"]!,
      coachKey: kOwnerBusinessKey,
      ownerIds: {"owner-1"},
    );
    expect(thread, hasLength(1));
    expect(
      messagesForOwnerThread(comms()["jordan"]!, coachKey: "chris", ownerIds: {"owner-1"}),
      isEmpty,
    );
  });

  test("the coach filter and client search narrow the list", () {
    final rows = inbox();
    final team = OwnerInboxRow(
      id: "pair:chris:avery",
      clientId: null,
      coachKey: "pair:chris:avery",
      title: "Coach Chris ↔ Coach Avery",
      coachLabel: kTeamChatLabel,
      preview: "Can you cover my 5?",
      at: DateTime(2026, 11, 16, 11),
      unread: false,
      team: true,
      participantIds: {"chris", "avery"},
    );
    final all = [...rows, team]..sort((a, b) => b.at.compareTo(a.at));

    expect(filterOwnerInbox(all, coachKey: "chris").map((row) => row.title), ["Alex Rivera", "Coach Chris ↔ Coach Avery"]);
    expect(filterOwnerInbox(all, coachKey: kOwnerBusinessKey).map((row) => row.clientId), ["jordan"]);
    expect(filterOwnerInbox(all, coachKey: kOwnerFilterAll, query: "jor").single.clientId, "jordan");
    expect(filterOwnerInbox(all, coachKey: kOwnerCoachChatsKey).map((row) => row.title), ["Coach Chris ↔ Coach Avery"]);
    expect(ownerCoachFilters(coaches).map((option) => option.label), [
      "All coaches",
      "Coach Chats",
      "Coach Avery",
      "Coach Chris",
      kOneFitnessBusinessLabel,
    ]);
  });

  test("opening one thread does not pull in the other coach", () {
    final alex = [
      ...comms()["alex"]!,
      CommMessage(id: "9", who: "client", text: "Question for the gym.", at: "", routedTo: "business", createdAt: business),
    ];
    final coachThread = messagesForOwnerThread(alex, coachKey: "chris", ownerIds: {"owner-1"});
    expect(coachThread.map((m) => m.id), ["2", "1"]);
  });

  test("the migration lets the owner read every message and ignores assignment", () {
    final sql = File("supabase/migrations/20261121200000_owner_reads_all_messages.sql").readAsStringSync();
    final code = sql.split("\n").where((line) => !line.trimLeft().startsWith("--")).join("\n");
    expect(code.contains("primary_trainer_id"), isFalse);
    expect(sql, contains("current_user_role()) in ('coach', 'owner')"));
    expect(sql, contains("'owner:' || m.client_id::text"));
    expect(sql, contains("m.routed_to = 'business'"));
    expect(sql, contains("is_owner()"));
  });

  test("a later record refresh keeps the messages already loaded", () {
    clearLoadedComms();
    final container = ProviderContainer();
    addTearDown(() {
      clearLoadedComms();
      container.dispose();
    });
    final notifier = container.read(trainerClientRecordsProvider.notifier);
    notifier.setAll(const {"alex": ClientRecord(id: "alex")});
    notifier.mergeComms({
      "alex": [
        CommMessage(id: "1", who: "client", text: "Hello", at: "", trainerId: "chris", createdAt: chris),
      ],
    });
    notifier.setAll(const {"alex": ClientRecord(id: "alex")});
    expect(container.read(trainerClientRecordsProvider)["alex"]!.comms.single.text, "Hello");
  });
}
