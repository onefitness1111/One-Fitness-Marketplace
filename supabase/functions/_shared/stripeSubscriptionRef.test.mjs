import assert from "node:assert/strict";
import test from "node:test";
import {
  backfillSubscriptionLink,
  decideTakesSlot,
  invoiceIdFromPaymentIntent,
  resolveSubscriptionId,
  subscriptionIdFromInvoice,
  subscriptionMetadataFromInvoice,
} from "./stripeSubscriptionRef.mjs";

const failIfCalled = () => { throw new Error("should not be called"); };

test("invoice subscription id: 2024-06-20 shape, string or expanded", () => {
  assert.equal(subscriptionIdFromInvoice({ subscription: "sub_old" }), "sub_old");
  assert.equal(subscriptionIdFromInvoice({ subscription: { id: "sub_obj" } }), "sub_obj");
});

test("invoice subscription id: basil shape under parent.subscription_details", () => {
  const inv = { parent: { type: "subscription_details", subscription_details: { subscription: "sub_new", metadata: { plan_id: "p1" } } } };
  assert.equal(subscriptionIdFromInvoice(inv), "sub_new");
  assert.deepEqual(subscriptionMetadataFromInvoice(inv), { plan_id: "p1" });
});

test("invoice subscription id: one-off invoice and junk give null", () => {
  assert.equal(subscriptionIdFromInvoice({ subscription: null, parent: null }), null);
  assert.equal(subscriptionIdFromInvoice(null), null);
  assert.equal(subscriptionIdFromInvoice("in_1"), null);
  assert.deepEqual(subscriptionMetadataFromInvoice({}), {});
  assert.deepEqual(subscriptionMetadataFromInvoice({ subscription_details: { metadata: { a: "1" } } }), { a: "1" });
});

test("payment intent invoice id", () => {
  assert.equal(invoiceIdFromPaymentIntent({ invoice: "in_1" }), "in_1");
  assert.equal(invoiceIdFromPaymentIntent({ invoice: { id: "in_2" } }), "in_2");
  assert.equal(invoiceIdFromPaymentIntent({}), null);
});

test("resolve: metadata wins and makes no Stripe calls", async () => {
  const res = await resolveSubscriptionId(
    { id: "pi_1", metadata: { subscription_id: "sub_meta" }, invoice: "in_1" },
    { retrievePaymentIntent: failIfCalled, retrieveInvoice: failIfCalled },
  );
  assert.deepEqual(res, { subscriptionId: "sub_meta", source: "metadata" });
});

test("resolve: blank metadata falls through to the event's invoice", async () => {
  const calls = [];
  const res = await resolveSubscriptionId(
    { id: "pi_1", metadata: { subscription_id: "  " }, invoice: "in_1" },
    { retrievePaymentIntent: failIfCalled, retrieveInvoice: async (id) => { calls.push(id); return { subscription: "sub_ev" }; } },
  );
  assert.deepEqual(res, { subscriptionId: "sub_ev", source: "event_invoice" });
  assert.deepEqual(calls, ["in_1"]);
});

test("resolve: expanded invoice on the event needs no call", async () => {
  const res = await resolveSubscriptionId(
    { id: "pi_1", metadata: {}, invoice: { id: "in_1", parent: { subscription_details: { subscription: "sub_emb" } } } },
    { retrievePaymentIntent: failIfCalled, retrieveInvoice: failIfCalled },
  );
  assert.deepEqual(res, { subscriptionId: "sub_emb", source: "event_invoice" });
});

test("resolve: basil event with no invoice re-reads the intent, then the invoice", async () => {
  const res = await resolveSubscriptionId(
    { id: "pi_1", metadata: { plan_id: "p1" } },
    {
      retrievePaymentIntent: async (id) => { assert.equal(id, "pi_1"); return { id, invoice: "in_9" }; },
      retrieveInvoice: async (id) => { assert.equal(id, "in_9"); return { parent: { subscription_details: { subscription: "sub_basil" } } }; },
    },
  );
  assert.deepEqual(res, { subscriptionId: "sub_basil", source: "refetched_invoice" });
});

test("resolve: an invoice read failure falls back to the re-read intent", async () => {
  const logs = [];
  let n = 0;
  const res = await resolveSubscriptionId(
    { id: "pi_1", metadata: {}, invoice: "in_bad" },
    {
      log: (m) => logs.push(m),
      retrievePaymentIntent: async () => ({ invoice: "in_good" }),
      retrieveInvoice: async (id) => { n++; if (id === "in_bad") throw new Error("boom"); return { subscription: "sub_ok" }; },
    },
  );
  assert.deepEqual(res, { subscriptionId: "sub_ok", source: "refetched_invoice" });
  assert.equal(n, 2);
  assert.equal(logs.length, 1);
});

test("resolve: one-time payment gives null and never throws", async () => {
  const logs = [];
  assert.deepEqual(
    await resolveSubscriptionId({ id: "pi_1", metadata: {} }, { retrievePaymentIntent: async () => ({ invoice: null }), retrieveInvoice: failIfCalled }),
    { subscriptionId: null, source: null },
  );
  assert.deepEqual(
    await resolveSubscriptionId({ id: "pi_1" }, { log: (m) => logs.push(m), retrievePaymentIntent: async () => { throw new Error("down"); } }),
    { subscriptionId: null, source: null },
  );
  assert.equal(logs.length, 1);
  assert.deepEqual(await resolveSubscriptionId(null), { subscriptionId: null, source: null });
});

test("backfill: links the active unlinked entry and the slot that holds it", () => {
  const client = {
    membership_plan_id: "p1",
    stripe_subscription_id: null,
    plans: [
      { planId: "p0", status: "cancelled" },
      { planId: "p1", status: "active", startDate: "2026-11-22" },
      { planId: "pkg", status: "active" },
    ],
  };
  const up = backfillSubscriptionLink(client, "p1", "sub_1");
  assert.equal(up.stripe_subscription_id, "sub_1");
  assert.deepEqual(up.plans[1], { planId: "p1", status: "active", startDate: "2026-11-22", subscriptionId: "sub_1" });
  assert.deepEqual(up.plans[0], client.plans[0]);
  assert.equal(client.plans[1].subscriptionId, undefined, "input is not mutated");
});

test("backfill: a second membership gets its entry linked but not the slot", () => {
  const client = { membership_plan_id: "p1", stripe_subscription_id: null, plans: [{ planId: "p1", status: "active" }, { planId: "p2", status: "active" }] };
  const up = backfillSubscriptionLink(client, "p2", "sub_2");
  assert.equal("stripe_subscription_id" in up, false);
  assert.equal(up.plans[1].subscriptionId, "sub_2");
});

test("backfill: never overwrites another subscription and is a no-op when done", () => {
  const linked = { membership_plan_id: "p1", stripe_subscription_id: "sub_a", plans: [{ planId: "p1", status: "active", subscriptionId: "sub_a" }] };
  assert.equal(backfillSubscriptionLink(linked, "p1", "sub_b"), null);
  assert.equal(backfillSubscriptionLink(linked, "p1", "sub_a"), null);
  const slotMissing = { membership_plan_id: "p1", stripe_subscription_id: null, plans: [{ planId: "p1", status: "active", subscriptionId: "sub_a" }] };
  assert.deepEqual(backfillSubscriptionLink(slotMissing, "p1", "sub_a"), { plans: slotMissing.plans, stripe_subscription_id: "sub_a" });
  assert.equal(backfillSubscriptionLink({ plans: [{ planId: "p1", status: "cancelled" }] }, "p1", "sub_a"), null);
  assert.equal(backfillSubscriptionLink(null, "p1", "sub_a"), null);
  assert.equal(backfillSubscriptionLink(linked, "", "sub_a"), null);
});

test("slot: programs never, empty or same plan always", () => {
  assert.equal(decideTakesSlot({ planId: "prog", isProgram: true, isMembership: false, slotPlanId: null }), false);
  assert.equal(decideTakesSlot({ planId: "p1", isProgram: false, isMembership: true, slotPlanId: null }), true);
  assert.equal(decideTakesSlot({ planId: "pkg", isProgram: false, isMembership: false, slotPlanId: null }), true);
  assert.equal(decideTakesSlot({ planId: "p1", isProgram: false, isMembership: true, slotPlanId: "p1", slotSubscriptionId: "sub_a" }), true);
});

test("slot: a membership replaces a free or package slot", () => {
  assert.equal(decideTakesSlot({ planId: "p2", isProgram: false, isMembership: true, slotPlanId: "free", slotSubscriptionId: null, slotPaidInApp: false }), true);
});

test("slot: a paid membership is kept, with or without its subscription id", () => {
  assert.equal(decideTakesSlot({ planId: "p2", isProgram: false, isMembership: true, slotPlanId: "p1", slotSubscriptionId: "sub_a" }), false);
  // Bought earlier the same day; the id never got linked.
  assert.equal(decideTakesSlot({ planId: "p2", isProgram: false, isMembership: true, slotPlanId: "p1", slotSubscriptionId: null, slotPaidInApp: true }), false);
});

test("slot: a package never pushes anything out", () => {
  assert.equal(decideTakesSlot({ planId: "pkg", isProgram: false, isMembership: false, slotPlanId: "free", slotSubscriptionId: null, slotPaidInApp: false }), false);
});
