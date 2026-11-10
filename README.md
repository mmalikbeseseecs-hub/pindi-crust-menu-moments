# PINDI CRUST — run it on Vercel + Supabase

This copy of the app has **no Lovable code or packages**. It is a standard
TanStack Start (React) app that:

- is hosted on **Vercel** (it builds in Vercel's format automatically), and
- uses **your own Supabase project** for the database, sign-in and Google sign-up.

Follow the steps in order. Each one takes a few minutes.

---

## Step 1 — Create your Supabase project

1. Go to https://supabase.com → **New project**. Pick a region close to your customers (e.g. Mumbai / Singapore for Pakistan).
2. Save the database password somewhere safe.
3. Open **Project Settings → API** (or **API Keys**) and copy:
   - **Project URL** → `https://abcd1234.supabase.co`
   - **anon / publishable key**
   - **Reference ID** (the `abcd1234` part)

## Step 2 — Install the database design

1. In Supabase open **SQL Editor → New query**.
2. Open `supabase/schema.sql` from this folder, copy **everything**, paste, click **Run**.
   You should see "Success. No rows returned". (Running it again later is safe.)
3. Check **Table Editor** — you should see 23 tables (`profiles`, `products`, `orders`, …).

This creates all tables, security rules, ordering/pricing logic, payment
verification, notifications, analytics, reports, the activity log, live order
updates, and automatic profile creation for email and Google sign-ups.

**Existing data (menu, orders) from Lovable:** in the original Lovable project
export each table as CSV, then in Supabase **Table Editor → (table) → Insert →
Import data from CSV**. Import parent tables first (categories → products →
add_ons → orders → order_items).

**Existing user accounts:** passwords cannot be copied between systems. People
simply sign up again (or tap "Continue with Google").

### Make yourself the admin

1. Sign up once on the live site (email or Google).
2. **SQL Editor → New query** → paste `supabase/make-admin.sql` → change the
   email (and role if needed) on the two lines marked `<-- CHANGE` → **Run**.
3. The result table at the bottom should show your email with `admin` twice.
4. Sign out and back in on the site → you'll land on `/admin`.

Roles: `developer` (full access, manages admins) · `admin` (owner) ·
`manager` (staff: orders, POS, kitchen, menu) · `customer`.
After that, you can add staff from the app's **Users** page.

## Step 3 — Supabase sign-in settings (prevents most login errors)

**Authentication → URL Configuration**

| Field | Value |
|---|---|
| Site URL | `https://your-app.vercel.app` (later: your real domain) |
| Redirect URLs | `https://your-app.vercel.app/**` |
| | `https://*-your-vercel-team.vercel.app/**` (Vercel preview links) |
| | `http://localhost:8080/**` (your computer) |
| | `https://yourdomain.com/**` (once you add a domain) |

**Authentication → Providers → Email**: enabled. "Confirm email" ON is safer;
OFF lets people order immediately after sign-up.

**Authentication → Emails → SMTP Settings** — important: Supabase's built-in
email only sends a few emails per hour and only to your own team addresses.
Real customers will NOT get confirmation / reset emails until you add a custom
SMTP provider (e.g. Resend, Brevo, Postmark — free tiers are fine).

## Step 4 — Google sign-up

**A. Google Cloud Console** (https://console.cloud.google.com)

1. Create a project → **APIs & Services → OAuth consent screen**: app name
   "PINDI CRUST", support email, your domain. Add scopes `email`, `profile`, `openid`.
   **Publish the app (status: In production)** — while it's in "Testing", only
   test users you list can sign in and everyone else sees an error.
2. **Credentials → Create credentials → OAuth client ID → Web application**
   - **Authorized JavaScript origins**: `https://your-app.vercel.app`, `http://localhost:8080`, your custom domain
   - **Authorized redirect URIs**: `https://YOUR-REF.supabase.co/auth/v1/callback`
     (exactly this — it is Supabase's address, not your site's)
3. Copy the **Client ID** and **Client secret**.

**B. Supabase → Authentication → Providers → Google** → enable → paste Client ID
and Client secret → Save.

How it works in the app: "Continue with Google" → Google → Supabase → back to
`/login` on your site → signed in → customers go to the shop, staff go to `/admin`.

## Step 5 — Put the code on GitHub

1. Create an empty **private** repository on https://github.com/new.
2. Upload this folder's contents (GitHub → "uploading an existing file", or `git push`).
   Never upload a `.env` file — it is ignored on purpose.

## Step 6 — Deploy on Vercel

1. https://vercel.com → **Add New → Project** → import the GitHub repo.
2. Framework preset: leave what Vercel detects (or "Other"). Build command:
   `npm run build` (default). Leave Output Directory empty.
3. **Environment Variables** (tick Production **and** Preview):

   | Name | Value |
   |---|---|
   | `VITE_SUPABASE_URL` | your Project URL |
   | `VITE_SUPABASE_PUBLISHABLE_KEY` | your anon / publishable key |
   | `VITE_SUPABASE_PROJECT_ID` | your Reference ID |
   | `SUPABASE_URL` | your Project URL |
   | `SUPABASE_PUBLISHABLE_KEY` | your anon / publishable key |

4. **Deploy**. Copy the final address (e.g. `https://pindi-crust.vercel.app`)
   and make sure it is in Supabase Redirect URLs and Google origins (Steps 3–4).

> `VITE_` values are baked in at build time. After changing any variable,
> go to **Deployments → ⋯ → Redeploy**.

## Step 7 — Your own domain (optional)

Vercel → Project → **Settings → Domains** → add `pindicrust.com` → follow the DNS
instructions. Then add the domain to Supabase **Site URL / Redirect URLs** and
Google **Authorized JavaScript origins**.

## Step 8 — Test it like a customer

1. Sign up with email → confirm email → sign in.
2. Sign out → "Continue with Google".
3. Forgot password → email link → choose a new password.
4. Place a test order → it appears live in `/admin/orders` and the kitchen screen.

---

## Fixing common errors

| What you see | Cause → fix |
|---|---|
| `redirect_uri_mismatch` (Google page) | Google redirect URI must be exactly `https://YOUR-REF.supabase.co/auth/v1/callback`. |
| `Unsupported provider: provider is not enabled` | Turn on Google in Supabase → Auth → Providers. |
| After Google you land on `localhost:3000` or the wrong site | Site URL / Redirect URLs in Supabase don't include your Vercel URL with `/**`. |
| "Access blocked: app has not completed verification" / only some people can log in | Google consent screen is still in "Testing" → Publish app. |
| "Email not confirmed" when signing in | User hasn't clicked the email link; or turn off "Confirm email". |
| Confirmation / reset email never arrives | Add custom SMTP (Step 3). |
| Reset link says invalid/expired | Open the link on the same phone/browser that requested it; links work once. |
| "Missing Supabase environment variable(s)" | Add the variables in Vercel, then **Redeploy**. |
| Signed in but admin pages say forbidden | Run `supabase/make-admin.sql` with your email (Step 2), then sign out and in. |
| "new row violates row-level security" / empty menu | `supabase/schema.sql` (Step 2) wasn't run, or you're not signed in as staff. |
| Orders don't appear live in admin | Run: `alter publication supabase_realtime add table public.orders;` |

## Run on your computer

```bash
cp .env.example .env      # fill in your Supabase values
npm install               # or: bun install
npm run dev               # http://localhost:8080
npm test
```
