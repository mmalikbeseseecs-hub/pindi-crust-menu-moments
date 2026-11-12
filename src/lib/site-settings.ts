import { queryOptions, useQuery } from "@tanstack/react-query";
import {
  fetchSiteSettings,
  type Branch,
  type MaintenanceSettings,
  type PaymentSettings,
  type SiteSettingsData,
  type StoreSettings,
} from "./api";
import { seasonalThemes, type SeasonalTheme } from "@/store/theme";

/**
 * Published site settings, read by every page.
 *
 * Admins save these from Settings (Store, Payments, Brand, Themes,
 * Maintenance). Brand values fall back to the built-in PINDI CRUST look when
 * nothing has been published; business details (phone, fees, wallets) stay
 * `null` until an admin publishes them — never invented.
 */

export type HomeSectionId =
  | "hero"
  | "categories"
  | "bestsellers"
  | "recommended"
  | "popular"
  | "promo"
  | "reviews"
  | "stores";

export type HomeSection = { id: HomeSectionId; label: string; enabled: boolean };

export const DISPLAY_FONTS = [
  "Playfair Display",
  "Lora",
  "Montserrat",
  "Poppins",
  "Sora",
  "Bebas Neue",
] as const;

export type BrandSettings = {
  brandName: string;
  tagline: string;
  /** Uploaded logo. Empty = built-in flame wordmark. */
  logoUrl: string;
  faviconUrl: string;
  heroImage: string;
  heroHeading: string;
  heroHighlight: string;
  heroSubheading: string;
  heroCta: string;
  announcement: string;
  announcementEnabled: boolean;
  homeSections: HomeSection[];
  primaryColor: string;
  accentColor: string;
  surfaceColor: string;
  font: string;
  radius: string;
  footerText: string;
  copyright: string;
  social: { instagram: string; facebook: string; tiktok: string };
  seoTitle: string;
  seoDescription: string;
  /** Seasonal storefront theme. */
  theme: SeasonalTheme;
  /** Show the homepage advertisement pop-up and promo code box. */
  promotionsEnabled: boolean;
};

export const DEFAULT_HOME_SECTIONS: HomeSection[] = [
  { id: "hero", label: "Hero banner", enabled: true },
  { id: "categories", label: "Categories", enabled: true },
  { id: "bestsellers", label: "Best sellers", enabled: true },
  { id: "recommended", label: "Recommended items", enabled: true },
  { id: "popular", label: "Popular this week", enabled: true },
  { id: "promo", label: "Promotional banner", enabled: true },
  { id: "reviews", label: "Customer reviews", enabled: true },
  { id: "stores", label: "Visit our stores", enabled: true },
];

export const BRAND_DEFAULTS: BrandSettings = {
  brandName: "PINDI CRUST",
  tagline: "Artisanal Crust, Pure Happiness",
  logoUrl: "",
  faviconUrl: "",
  heroImage: "",
  heroHeading: "Artisanal Crust,",
  heroHighlight: "Pure Happiness",
  heroSubheading:
    "Experience the alchemy of ancient flour, fiercely local ingredients and the roaring heat of our stone ovens — delivered to your door.",
  heroCta: "Order Now",
  announcement: "",
  announcementEnabled: false,
  homeSections: DEFAULT_HOME_SECTIONS,
  primaryColor: "#840912",
  accentColor: "#fdba53",
  surfaceColor: "#fbf9f4",
  font: "Playfair Display",
  radius: "1rem",
  footerText:
    "Artisanal excellence in every slice. We believe in the magic of slow-fermented dough and fiercely local ingredients.",
  copyright: "© 2026 PINDI CRUST · Artisanal Excellence",
  social: { instagram: "", facebook: "", tiktok: "" },
  seoTitle: "PINDI CRUST — Artisanal Wood-Fired Pizza in Rawalpindi",
  seoDescription:
    "Slow-fermented dough, wood-fired at 480°C. Order signature pizzas, burgers and dolci from Pindi Crust with live delivery tracking.",
  theme: "default",
  promotionsEnabled: true,
};

const HEX_RE = /^#[0-9a-f]{6}$/i;
const RADIUS_RE = /^\d{1,2}(\.\d+)?(rem|px)$/;

/** Only https links (uploaded images) or site-relative paths are allowed for images. */
export function safeImageUrl(v: unknown): string {
  if (typeof v !== "string") return "";
  const url = v.trim();
  if (/^https:\/\/[^\s"'<>]+$/i.test(url)) return url;
  if (/^\/[^\s"'<>/][^\s"'<>]*$/.test(url)) return url;
  return "";
}

const text = (v: unknown, fallback: string, max = 500) =>
  typeof v === "string" ? v.slice(0, max) : fallback;

/** Reads the published brand JSON safely, filling gaps with the defaults. */
export function resolveBrand(raw: Record<string, unknown> | null | undefined): BrandSettings {
  const r = raw ?? {};
  const d = BRAND_DEFAULTS;
  const social = (r["social"] && typeof r["social"] === "object" ? r["social"] : {}) as Record<
    string,
    unknown
  >;
  const savedSections = Array.isArray(r["homeSections"]) ? r["homeSections"] : [];
  const known = new Map(DEFAULT_HOME_SECTIONS.map((s) => [s.id, s]));
  const ordered: HomeSection[] = [];
  for (const s of savedSections) {
    const id = (s as { id?: unknown })?.id;
    const base = typeof id === "string" ? known.get(id as HomeSectionId) : undefined;
    if (!base || ordered.some((o) => o.id === base.id)) continue;
    ordered.push({ ...base, enabled: (s as { enabled?: unknown }).enabled !== false });
  }
  for (const s of DEFAULT_HOME_SECTIONS) if (!ordered.some((o) => o.id === s.id)) ordered.push(s);
  const theme = seasonalThemes.some((t) => t.id === r["theme"]) ? (r["theme"] as SeasonalTheme) : d.theme;
  const color = (v: unknown, fb: string) => (typeof v === "string" && HEX_RE.test(v) ? v : fb);
  return {
    brandName: text(r["brandName"], d.brandName, 60).trim() || d.brandName,
    tagline: text(r["tagline"], d.tagline, 120),
    logoUrl: safeImageUrl(r["logoUrl"]),
    faviconUrl: safeImageUrl(r["faviconUrl"]),
    heroImage: safeImageUrl(r["heroImage"]),
    heroHeading: text(r["heroHeading"], d.heroHeading, 120),
    heroHighlight: text(r["heroHighlight"], d.heroHighlight, 120),
    heroSubheading: text(r["heroSubheading"], d.heroSubheading, 400),
    heroCta: text(r["heroCta"], d.heroCta, 40).trim() || d.heroCta,
    announcement: text(r["announcement"], d.announcement, 200),
    announcementEnabled: r["announcementEnabled"] === true,
    homeSections: ordered,
    primaryColor: color(r["primaryColor"], d.primaryColor),
    accentColor: color(r["accentColor"], d.accentColor),
    surfaceColor: color(r["surfaceColor"], d.surfaceColor),
    font: DISPLAY_FONTS.includes(r["font"] as (typeof DISPLAY_FONTS)[number])
      ? (r["font"] as string)
      : d.font,
    radius: typeof r["radius"] === "string" && RADIUS_RE.test(r["radius"]) ? r["radius"] : d.radius,
    footerText: text(r["footerText"], d.footerText, 400),
    copyright: text(r["copyright"], d.copyright, 120),
    social: {
      instagram: text(social["instagram"], "", 80),
      facebook: text(social["facebook"], "", 80),
      tiktok: text(social["tiktok"], "", 80),
    },
    seoTitle: text(r["seoTitle"], d.seoTitle, 70).trim() || d.seoTitle,
    seoDescription: text(r["seoDescription"], d.seoDescription, 200).trim() || d.seoDescription,
    theme,
    promotionsEnabled: r["promotionsEnabled"] !== false,
  };
}

/** Contact + business details the shop shows. `null` = not published yet. */
export type StoreInfo = {
  brand: string;
  tagline: string;
  phone: string | null;
  /** International format without "+", e.g. 923001234567. */
  whatsapp: string | null;
  email: string | null;
  merchantEasypaisa: string | null;
  merchantJazzcash: string | null;
  hours: string | null;
  address: string | null;
  deliveryRadius: string | null;
  mapsUrl: string | null;
};

const orNull = (v: string | null | undefined) => (v && v.trim() ? v.trim() : null);

export function toStoreInfo(
  brand: BrandSettings,
  store: StoreSettings | null,
  payments: PaymentSettings | null,
): StoreInfo {
  const whatsappDigits = (store?.whatsapp ?? "").replace(/\D/g, "");
  return {
    brand: orNull(store?.storeName) ?? brand.brandName,
    tagline: brand.tagline,
    phone: orNull(store?.phone),
    whatsapp: whatsappDigits.length >= 10 ? whatsappDigits : null,
    email: orNull(store?.email),
    merchantEasypaisa: payments?.easypaisaEnabled ? orNull(payments.easypaisaNumber) : null,
    merchantJazzcash: payments?.jazzcashEnabled ? orNull(payments.jazzcashNumber) : null,
    hours: orNull(store?.hours),
    address: orNull(store?.address),
    deliveryRadius: store?.deliveryRadiusKm ? `${store.deliveryRadiusKm} km` : null,
    mapsUrl: store?.mapsUrl && /^https:\/\//i.test(store.mapsUrl) ? store.mapsUrl : null,
  };
}

export type PricingConfig = {
  deliveryFee: number | null;
  taxRate: number | null;
  minOrder: number | null;
  freeDeliveryAbove: number | null;
};

export function toPricing(store: StoreSettings | null): PricingConfig {
  return {
    deliveryFee: store?.deliveryFee ?? null,
    taxRate: store?.taxRate ?? null,
    minOrder: store?.minOrder ?? null,
    freeDeliveryAbove: store?.freeDeliveryAbove ?? null,
  };
}

export const siteSettingsQuery = queryOptions({
  queryKey: ["site-settings"],
  queryFn: fetchSiteSettings,
  staleTime: 60_000,
});

export type SiteSettings = {
  brand: BrandSettings;
  storeInfo: StoreInfo;
  pricing: PricingConfig;
  payments: PaymentSettings | null;
  maintenance: MaintenanceSettings | null;
  branches: Branch[];
  acceptingOrders: boolean;
  isLoading: boolean;
};

export function resolveSiteSettings(data: SiteSettingsData | undefined): Omit<SiteSettings, "isLoading"> {
  const brand = resolveBrand(data?.brand);
  return {
    brand,
    storeInfo: toStoreInfo(brand, data?.store ?? null, data?.payments ?? null),
    pricing: toPricing(data?.store ?? null),
    payments: data?.payments ?? null,
    maintenance: data?.maintenance ?? null,
    branches: data?.branches ?? [],
    acceptingOrders: data?.store?.acceptingOrders ?? true,
  };
}

/** Published settings with safe defaults while loading or when nothing is published. */
export function useSiteSettings(): SiteSettings {
  const { data, isLoading } = useQuery(siteSettingsQuery);
  return { ...resolveSiteSettings(data), isLoading };
}

export const useStoreInfo = () => useSiteSettings().storeInfo;
export const useBrand = () => useSiteSettings().brand;
