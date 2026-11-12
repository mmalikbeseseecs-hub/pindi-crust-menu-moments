/**
 * Store / business details now come from the published settings
 * (Admin → Settings). Read them with `useStoreInfo()` / `useSiteSettings()`
 * from "@/lib/site-settings". Anything not published yet is `null` and the
 * UI shows NOT_CONFIGURED instead of an invented value.
 */
export type { StoreInfo } from "./site-settings";

export const NOT_CONFIGURED = "Not configured yet";
