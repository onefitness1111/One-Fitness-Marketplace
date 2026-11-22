import "package:flutter_test/flutter_test.dart";

import "package:onefitness/core/utils/membership_utils.dart";
import "package:onefitness/core/utils/package_renewal.dart";
import "package:onefitness/data/models/client_info.dart";
import "package:onefitness/data/models/client_plan.dart";
import "package:onefitness/data/models/membership_plan.dart";

/// Who can see a plan, and who can buy one.
///
/// Ghost is the middle state: not on the client storefront, still assignable
/// by staff, and still a normal plan for anyone already on it.
void main() {
  MembershipPlan plan(PlanStatus status, {PlanKind kind = PlanKind.membership, String id = "p"}) =>
      MembershipPlan(id: id, name: id, kind: kind, status: status, priceCents: 22900);

  group("status from older rows", () {
    test("no status and archived false is active", () {
      expect(resolvePlanStatus(null), PlanStatus.active);
      expect(resolvePlanStatus("nope", archived: false), PlanStatus.active);
    });

    test("no status and archived true is archived", () {
      expect(resolvePlanStatus(null, archived: true), PlanStatus.archived);
      final parsed = MembershipPlan(id: "old", name: "Old", kind: PlanKind.package, archived: true);
      expect(parsed.status, PlanStatus.archived);
      expect(parsed.archived, isTrue);
    });

    test("ghost wins even when the payload says archived", () {
      // dashboard_bootstrap marks a held ghost plan archived in the copy
      // sent to app 1.1.3. This app reads status and keeps it ghost.
      expect(resolvePlanStatus("ghost", archived: true), PlanStatus.ghost);
      final parsed = MembershipPlan(
        id: "legacy",
        name: "Legacy 8",
        kind: PlanKind.membership,
        status: PlanStatus.ghost,
      );
      expect(parsed.archived, isFalse);
    });
  });

  group("who the catalog is for", () {
    test("clients see active plans only", () {
      expect(planInClientCatalog(plan(PlanStatus.active)), isTrue);
      expect(planInClientCatalog(plan(PlanStatus.ghost)), isFalse);
      expect(planInClientCatalog(plan(PlanStatus.archived)), isFalse);
    });

    test("staff can assign active and ghost plans", () {
      expect(planAssignableByStaff(plan(PlanStatus.active)), isTrue);
      expect(planAssignableByStaff(plan(PlanStatus.ghost)), isTrue);
      expect(planAssignableByStaff(plan(PlanStatus.archived)), isFalse);
    });
  });

  group("someone already on a ghost plan", () {
    final ghost = plan(PlanStatus.ghost, id: "legacy-8");
    final info = ClientInfo(
      id: "c1",
      name: "Avery",
      membershipPlanId: "legacy-8",
      plans: const [
        ClientPlanEnrollment(planId: "legacy-8", status: "active", startDate: "2024-01-08"),
      ],
    );

    test("their current plan is still the one they hold", () {
      final held = heldAccessPlans(info, [ghost, plan(PlanStatus.active, id: "new")]);
      expect(held.map((p) => p.id), ["legacy-8"]);
    });

    test("a ghost package still offers renewal", () {
      final package = plan(PlanStatus.ghost, kind: PlanKind.package, id: "pack-12");
      final holder = ClientInfo(
        id: "c1",
        name: "Avery",
        plans: const [
          ClientPlanEnrollment(planId: "pack-12", status: "active", startDate: "2026-01-01"),
        ],
      );
      final found = packageEnrollments(holder, [package]);
      expect(found, hasLength(1));
      expect(found.single.plan.id, "pack-12");
    });

    test("an archived package does not offer renewal", () {
      final package = plan(PlanStatus.archived, kind: PlanKind.package, id: "pack-old");
      final holder = ClientInfo(
        id: "c1",
        name: "Avery",
        plans: const [
          ClientPlanEnrollment(planId: "pack-old", status: "active", startDate: "2026-01-01"),
        ],
      );
      expect(packageEnrollments(holder, [package]), isEmpty);
    });
  });

  group("merging held ghost plans back onto a client read", () {
    test("adds a ghost plan the catalog omitted and leaves the rest", () {
      final active = plan(PlanStatus.active, id: "open");
      final ghost = plan(PlanStatus.ghost, id: "legacy");
      final merged = mergeHeldGhostPlans([active], [ghost]);
      expect(merged.map((p) => p.id), ["open", "legacy"]);
    });

    test("does not duplicate a plan already in the catalog", () {
      final ghost = plan(PlanStatus.ghost, id: "legacy");
      expect(mergeHeldGhostPlans([ghost], [ghost]), hasLength(1));
    });

    test("ignores a held plan that is not ghost", () {
      final active = plan(PlanStatus.active, id: "open");
      expect(mergeHeldGhostPlans(const [], [active]), isEmpty);
    });

    test("row merge keeps the catalog row when both have the id", () {
      final catalog = [
        {"id": "open", "data": {"status": "active", "name": "Open"}},
      ];
      final held = [
        {"id": "legacy", "data": {"status": "ghost", "archived": false, "name": "Legacy"}},
        {"id": "open", "data": {"status": "ghost", "name": "should not replace"}},
      ];
      final merged = mergeHeldGhostRows(catalog, held);
      expect(merged.map((r) => r["id"]), ["open", "legacy"]);
      expect((merged.first["data"] as Map)["name"], "Open");
    });
  });
}
