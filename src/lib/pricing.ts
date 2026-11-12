/**
 * Checkout maths, in ONE place.
 *
 * This file only produces the *preview* the customer sees in the cart and
 * checkout. The authoritative numbers are recomputed by the database
 * (`place_order`) from live prices and the published store settings.
 *
 * Delivery fee, tax rate and the free-delivery threshold come from
 * Admin → Settings → Store (see useSiteSettings().pricing). While a value
 * is unset (null) it counts as 0 and the UI labels it "Not configured".
 */

export type AppliedPromo = {
  code: string;
  discountType: "percent" | "flat";
  discountValue: number;
};

export type Totals = {
  subtotal: number;
  discount: number;
  tax: number;
  deliveryFee: number;
  total: number;
};

export type PricingInput = {
  deliveryFee: number | null;
  taxRate: number | null;
  freeDeliveryAbove?: number | null | undefined;
};

export function promoDiscount(subtotal: number, promo: AppliedPromo | null): number {
  if (!promo || subtotal <= 0) return 0;
  const raw =
    promo.discountType === "percent" ? (subtotal * promo.discountValue) / 100 : promo.discountValue;
  return Math.min(Math.round(raw), subtotal);
}

/** Human label for a promo, e.g. "20% off" or "Rs 500 off". */
export function promoLabel(promo: AppliedPromo): string {
  return promo.discountType === "percent"
    ? `${promo.discountValue}% off`
    : `Rs ${promo.discountValue.toLocaleString("en-PK")} off`;
}

/** Label for the tax row, e.g. "Tax (5%)" or "Tax (not configured)". */
export function taxLabel(rate: number | null): string {
  if (rate === null) return "Tax (not configured)";
  const pct = Math.round(rate * 10000) / 100;
  return `Tax (${pct}%)`;
}

/**
 * Online orders pay delivery + tax; POS (walk-in) orders don't. Unset values
 * count as 0. Delivery is free once the items total reaches
 * `freeDeliveryAbove` (same rule as the database).
 */
export function computeTotals(
  subtotal: number,
  promo: AppliedPromo | null,
  source: "online" | "pos",
  config: PricingInput,
): Totals {
  const discount = promoDiscount(subtotal, promo);
  const taxable = subtotal - discount;
  const online = source === "online" && subtotal > 0;
  const tax = online && config.taxRate !== null ? Math.round(taxable * config.taxRate) : 0;
  const freeDelivery =
    config.freeDeliveryAbove !== null &&
    config.freeDeliveryAbove !== undefined &&
    subtotal >= config.freeDeliveryAbove;
  const deliveryFee =
    online && config.deliveryFee !== null && !freeDelivery ? config.deliveryFee : 0;
  return { subtotal, discount, tax, deliveryFee, total: taxable + tax + deliveryFee };
}
