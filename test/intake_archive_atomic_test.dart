import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:onefitness/data/intake_forms.dart";
import "package:onefitness/data/models/intake_form_template.dart";
import "package:onefitness/data/models/intake_schema.dart";
import "package:onefitness/features/client/intake/intake_answers_screen.dart";

void main() {
  group("L5: intake save is one all-or-nothing call", () {
    final service = File("lib/core/supabase/supabase_service.dart").readAsStringSync();
    final start = service.indexOf("static Future<IntakeRecord> updateClientIntake(");
    final body = service.substring(start, service.indexOf("static Future<void> flagProgramRefresh(", start));

    test("calls submit_client_intake and never falls back to a whole-record write", () {
      expect(start, greaterThan(0));
      expect(body, contains('client.rpc("submit_client_intake"'));
      expect(body.contains("client_records"), isFalse);
      expect(body.contains("catch"), isFalse);
      expect(body.contains("history"), isFalse, reason: "history is owned by the server");
    });

    test("attachment updates no longer overwrite the record on failure", () {
      final a = service.indexOf("static Future<void> updateClientIntakeAttachments(");
      final b = service.indexOf("static Future<IntakeRecord> updateClientIntake(");
      final attach = service.substring(a, b);
      expect(attach.contains('.from("client_records").upsert'), isFalse);
    });

    test("the RPC archives, writes, and mirrors in one function", () {
      final sql = File("supabase/migrations/20261125140000_submit_client_intake_atomic.sql").readAsStringSync();
      expect(sql, contains("create or replace function public.submit_client_intake("));
      expect(sql, contains("for update"));
      expect(sql, contains("jsonb_build_array(v_archived) || v_history"));
      expect(sql, contains("'templateVersion', v_prior -> 'templateVersion'"));
      expect(sql, contains("insert into public.intake_submissions"));
      expect(sql.contains("limit 20"), isFalse);
      expect(sql, contains("raise exception 'Not allowed.'"));
    });
  });

  group("L3: every resubmission keeps the earlier filing", () {
    test("the form filler has no overwrite mode", () {
      final filler = File("lib/features/client/intake/form_filler_screen.dart").readAsStringSync();
      expect(filler.contains("keepPrevious"), isFalse);
      final area = File("lib/features/client/intake/intake_area_screen.dart").readAsStringSync();
      expect(area.contains("keepPrevious"), isFalse);
    });

    test("entries round-trip with their form version; history is never sent", () {
      const rec = IntakeRecord(
        answers: {"goal": "Strength"},
        completed: true,
        at: "Nov 25, 6:24 PM",
        by: "Client",
        templateVersion: 3,
        history: [IntakeSubmission(answers: {"goal": "Lose fat"}, at: "May 14", templateVersion: 2)],
        extra: {"scores": {"x": 1}},
      );
      final entry = rec.toEntry();
      expect(entry.containsKey("history"), isFalse);
      expect(entry["templateVersion"], 3);
      expect(entry["scores"], {"x": 1});
      final back = IntakeRecord.fromEntry({
        ...entry,
        "history": [rec.history.first.toJson()],
      });
      expect(back.templateVersion, 3);
      expect(back.history.single.templateVersion, 2);
      expect(back.extra, {"scores": {"x": 1}});
    });

    test("the edit hint says a copy is kept", () {
      expect(kEditKeepsCopyHint, contains("stay saved"));
    });
  });

  group("U1: retired questions and forms stay readable", () {
    const v2 = IntakeSchema(title: "Gym form", sections: [
      IntakeSection(title: "Q", questions: [IntakeQuestion(id: "sleep", label: "Sleep", type: "text")]),
    ]);

    test("an answer to a question no longer on the form is still listed", () {
      final other = answersNotOnForm(v2, {"sleep": "7h", "caffeine": "2 cups", "blank": ""});
      expect(other, {"caffeine": "2 cups"});
      expect(readableAnswerKey("caffeine_per_day"), "Caffeine per day");
      expect(readableAnswerKey("mainGoal"), "Main goal");
    });

    test("retired forms are included when reading what is on file", () {
      const live = IntakeFormTemplate(key: "a", version: 2, title: "A", sections: []);
      const old = IntakeFormTemplate(key: "a", version: 1, title: "A", sections: []);
      const retired = IntakeFormTemplate(key: "b", version: 1, title: "B", sections: [], archived: true);
      final every = newestOfEachTemplate(const [old, live, retired]);
      expect(every.map((t) => "${t.key}${t.version}").toSet(), {"a2", "b1"});
    });
  });
}
