## Project rules

- All data access goes through `src/lib/api.ts` / `src/lib/auth-api.ts`, which call `db()` from `src/lib/supabaseClient.ts`; without env config `db()` throws `BackendNotConfiguredError`. Why: the app must run with no backend and never fake data or success.
- Show missing-backend states with `src/components/shared/BackendNotice.tsx` (`QueryErrorState`, `DraftNotice`, `BackendPreviewBanner`) rather than ad-hoc messages. Why: one consistent honest message.
- Business details (contact, branches, wallet numbers, delivery fee, tax) live in `src/lib/store-config.ts` / `src/lib/pricing.ts` as `null` until published by the backend; UI must handle `null`. Why: no invented business values.
- Success toasts fire only after a real backend call resolves. Why: no fake save/send confirmations.
- Admin "local layout preview" (`src/lib/preview.ts`) is dev-only, sessionStorage-scoped and never touches `useAuth`. Why: inspect admin UI without fabricating auth.
- Backend contract and remaining work are documented in `docs/frontend-completion/`. Why: starting point for the backend phase.
- Homepage advertisements use validated product slugs or HTTPS external destinations; user-authored draft previews are development-only, one-use sessionStorage values separate from published offers. Why: exercise the real display without fabricated records or backend saves.
- The API boundary reuses the generated auth client, including for managed Google sign-in, so all pages share the same session.
- Auth signup must invoke the app-owned profile creation trigger; it creates customer profiles only, while staff grants remain in protected user_roles.
- Order alarm acknowledgement and manual payment verification are durable database operations; the admin shell owns sound and realtime refresh so alerts survive page changes and synchronize across devices.
- Hosting is Vercel + the owner's own Supabase project; there are no Lovable packages. Why: the app must build and run with plain Vite/TanStack Start and standard Supabase Auth (Google via `supabase.auth.signInWithOAuth`, PKCE).
