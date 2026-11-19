// Unchanged copy of the live helper used by create-payment-intent.
import Stripe from "https://esm.sh/stripe@17.4.0?target=deno";

export async function ensureProduct(stripe: Stripe, key: string, name: string): Promise<string> {
  const id = `onefit_${key}`.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 100);
  const label = name.trim() || "ONE Fitness";
  try {
    const existing = await stripe.products.retrieve(id);
    if (existing.name !== label || !existing.active) {
      await stripe.products.update(id, { name: label, active: true });
    }
    return id;
  } catch (e) {
    if ((e as { code?: string })?.code !== "resource_missing") throw e;
    await stripe.products.create({ id, name: label });
    return id;
  }
}
