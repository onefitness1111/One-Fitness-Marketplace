import "package:flutter_test/flutter_test.dart";
import "package:onefitness/core/live_log/live_log_sync.dart";

Map<String, dynamic> setOp({
  required int set,
  required String field,
  required Object? value,
  String at = "2026-11-18T12:00:00Z",
}) =>
    {
      "t": "set",
      "by": "client-1",
      "client": "client-1",
      "date": "2026-11-18",
      "day": "day",
      "program": "program",
      "exercise": "Squat",
      "set": set,
      "field": field,
      "value": value,
      "at": at,
    };

void main() {
  test("typing the same set again replaces the waiting value, it does not add another", () {
    final first = queueLiveLogOp(const [], setOp(set: 1, field: "weight", value: 135, at: "2026-11-18T12:00:00Z"));
    final second = queueLiveLogOp(first, setOp(set: 1, field: "weight", value: 185, at: "2026-11-18T12:01:00Z"));
    expect(second, hasLength(1));
    expect(second.single["value"], 185);
  });

  test("other sets and the other field are kept", () {
    var ops = queueLiveLogOp(const [], setOp(set: 1, field: "weight", value: 135));
    ops = queueLiveLogOp(ops, setOp(set: 1, field: "reps", value: 8));
    ops = queueLiveLogOp(ops, setOp(set: 2, field: "weight", value: 135));
    ops = queueLiveLogOp(ops, setOp(set: 1, field: "weight", value: 145));
    expect(ops, hasLength(3));
    expect(ops.where((op) => op["set"] == 1 && op["field"] == "weight").single["value"], 145);
    expect(ops.where((op) => op["field"] == "reps"), hasLength(1));
    expect(ops.where((op) => op["set"] == 2), hasLength(1));
  });

  test("a note is not collapsed into a set", () {
    final ops = queueLiveLogOp(
      [setOp(set: 1, field: "reps", value: 5)],
      {"t": "note", "id": "n1", "client": "client-1", "exercise": "Squat"},
    );
    expect(ops, hasLength(2));
  });
}
