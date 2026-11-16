// Unchanged copy of the live helper, needed by create-setup-intent.
import type Stripe from "https://esm.sh/stripe@17.4.0?target=deno";

export async function customerIsUsable(stripe: Stripe, customerId: string): Promise<boolean> {
  try {
    const c = await stripe.customers.retrieve(customerId);
    return !(c as { deleted?: boolean }).deleted;
  } catch (e) {
    const err = e as { code?: string; statusCode?: number };
    if (err.code === "resource_missing" || err.statusCode === 404) return false;
    throw e;
  }
}
