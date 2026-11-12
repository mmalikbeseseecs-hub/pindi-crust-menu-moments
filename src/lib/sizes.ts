import type { Product, ProductSize } from "./types";

/**
 * Menu-item sizes (Small / Medium / Large …).
 *
 * The database is the authority: it cleans the size list when an item is
 * saved and prices every order line from the chosen size. These helpers only
 * mirror those rules so the admin form and the shop can show the same result
 * before anything is sent.
 */

export const MAX_SIZES = 30;

/** Reads the `sizes` column into typed sizes, dropping anything malformed. */
export function parseSizes(raw: unknown): ProductSize[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((s) => {
    if (!s || typeof s !== "object") return [];
    const { id, name, price } = s as Record<string, unknown>;
    const n = Number(price);
    if (typeof id !== "string" || typeof name !== "string" || !Number.isFinite(n)) return [];
    return [{ id, name, price: n }];
  });
}

export function hasSizes(p: Pick<Product, "sizes">): boolean {
  return p.sizes.length > 0;
}

/** Same checks the database runs when an item is saved. Returns a message, or null when valid. */
export function sizesError(sizes: { name: string; price: number | string }[]): string | null {
  if (sizes.length > MAX_SIZES) return `A menu item can have at most ${MAX_SIZES} sizes.`;
  const seen = new Set<string>();
  for (const s of sizes) {
    const name = s.name.trim();
    if (!name) return "Every size needs a name.";
    if (name.length > 40) return "Size names must be 40 characters or fewer.";
    const key = name.toLowerCase();
    if (seen.has(key)) return `The size "${name}" is listed twice.`;
    seen.add(key);
    const price = typeof s.price === "number" ? s.price : Number(String(s.price).trim() || NaN);
    if (!Number.isFinite(price) || price <= 0) return `The size "${name}" needs a price greater than zero.`;
  }
  return null;
}

/** Cheapest size price, or the single price when the item has no sizes. */
export function startingPrice(p: Pick<Product, "price" | "sizes">): number {
  if (p.sizes.length === 0) return p.price;
  return Math.min(...p.sizes.map((s) => s.price));
}

export function findSize(p: Pick<Product, "sizes">, sizeId: string | null | undefined) {
  if (!sizeId) return undefined;
  return p.sizes.find((s) => s.id === sizeId);
}

/** Price of one unit: chosen size (or base price) plus add-ons. Null when a required size is missing. */
export function unitPriceFor(
  p: Pick<Product, "price" | "sizes">,
  sizeId: string | null | undefined,
  addOns: { price: number }[] = [],
): number | null {
  const extras = addOns.reduce((sum, a) => sum + a.price, 0);
  if (p.sizes.length === 0) return p.price + extras;
  const size = findSize(p, sizeId);
  return size ? size.price + extras : null;
}
