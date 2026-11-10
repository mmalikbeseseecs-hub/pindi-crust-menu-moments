/**
 * Central place to report unexpected UI errors.
 * Logs to the browser console today; plug in Sentry, LogRocket, etc. here later.
 */
export function reportError(error: unknown, context: Record<string, unknown> = {}) {
  if (typeof window === "undefined") return;
  console.error("[app-error]", error, context);
}
