import { beforeEach, describe, expect, it } from "vitest";
import { sizesError, startingPrice, unitPriceFor } from "@/lib/sizes";
import { useCart } from "@/store/cart";
import type { Product } from "@/lib/types";

const pizza: Product = {
  id: "p1",
  slug: "fajita",
  name: "Fajita Pizza",
  category: "pizza",
  categoryId: "c1",
  price: 900,
  rating: 0,
  reviewCount: 0,
  image: "",
  gallery: [],
  short: "",
  description: "",
  ingredients: [],
  nutrition: [],
  badges: [],
  available: true,
  sizes: [
    { id: "s", name: "Small", price: 900 },
    { id: "m", name: "Medium", price: 1400 },
    { id: "l", name: "Large", price: 1900 },
    { id: "xl", name: "Family", price: 2600 },
  ],
};

describe("menu sizes", () => {
  beforeEach(() => useCart.setState({ lines: [], promo: null }));

  it("allows any number of sizes, each with its own price", () => {
    expect(sizesError(pizza.sizes)).toBeNull();
    expect(startingPrice(pizza)).toBe(900);
  });

  it("rejects a size without a name, a repeated size, or a price of zero", () => {
    expect(sizesError([{ name: " ", price: 500 }])).toBe("Every size needs a name.");
    expect(sizesError([{ name: "Large", price: 1 }, { name: "large", price: 2 }])).toMatch(/twice/);
    expect(sizesError([{ name: "Small", price: 0 }])).toMatch(/greater than zero/);
  });

  it("prices a line by the chosen size plus extras", () => {
    expect(unitPriceFor(pizza, "l", [{ price: 150 }])).toBe(2050);
    expect(unitPriceFor(pizza, null)).toBeNull();
  });

  it("won't add a sized item to the cart until a size is chosen", () => {
    expect(useCart.getState().add(pizza, 1)).toBe(false);
    expect(useCart.getState().lines).toHaveLength(0);
  });

  it("keeps different sizes of the same item as separate cart lines", () => {
    const { add } = useCart.getState();
    add(pizza, 1, [], pizza.sizes[1]);
    add(pizza, 2, [], pizza.sizes[2]);
    add(pizza, 1, [], pizza.sizes[1]);
    const lines = useCart.getState().lines;
    expect(lines).toHaveLength(2);
    expect(lines.find((l) => l.size?.id === "m")).toMatchObject({ qty: 2, unitPrice: 1400 });
    expect(lines.find((l) => l.size?.id === "l")).toMatchObject({ qty: 2, unitPrice: 1900 });
  });
});
