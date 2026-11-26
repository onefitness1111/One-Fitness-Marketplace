import "dart:io";

import "package:flutter_test/flutter_test.dart";

/// O5: coach assignment is gone. Nothing in the app or the server functions
/// reads, writes, or gates on clients.primary_trainer_id anymore.
void main() {
  Iterable<File> sources(String dir, List<String> exts) => Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => exts.any(f.path.endsWith))
      .where((f) => !f.path.contains(".test."));

  test("app code never mentions primary_trainer_id", () {
    for (final f in sources("lib", const [".dart"])) {
      final src = f.readAsStringSync();
      expect(src.contains("primary_trainer_id"), isFalse, reason: f.path);
      expect(src.contains("primaryTrainerId"), isFalse, reason: f.path);
    }
  });

  test("edge function code never reads primary_trainer_id", () {
    for (final f in sources("supabase/functions", const [".ts", ".mjs", ".js"])) {
      final src = f.readAsStringSync();
      expect(src.contains("primaryTrainerId"), isFalse, reason: f.path);
      final code = src.split("\n").where((l) => !l.trimLeft().startsWith("//") && !l.trimLeft().startsWith("*"));
      expect(code.any((l) => l.contains("primary_trainer_id")), isFalse, reason: f.path);
    }
  });

  test("dashboard_bootstrap no longer returns the field", () {
    final sql = File("supabase/migrations/20261125130000_dashboard_bootstrap_no_primary_trainer.sql").readAsStringSync();
    final body = sql.substring(sql.indexOf("create or replace function public.dashboard_bootstrap"));
    expect(body.contains("primary_trainer_id"), isFalse);
    expect(body, contains("'referred_by_trainer_id', c.referred_by_trainer_id"));
    expect(body, contains("grant execute on function public.dashboard_bootstrap(date, date) to authenticated, service_role;"));
  });

  test("the column drop is kept out of migrations and refuses to run by default", () {
    expect(
      Directory("supabase/migrations").listSync().any((e) => e.path.contains("drop_clients_primary_trainer_id")),
      isFalse,
    );
    final drop = File("supabase/manual/DO_NOT_APPLY_drop_clients_primary_trainer_id.sql").readAsStringSync();
    expect(drop, startsWith("-- ====="));
    expect(drop, contains("DO NOT APPLY WITHOUT THE OWNER'S OKAY AND A FRESH DATABASE BACKUP."));
    expect(drop, contains("current_setting('ofm.allow_drop_primary_trainer_id', true)"));
    expect(drop.indexOf("raise exception"), lessThan(drop.indexOf("drop column")));
  });
}
