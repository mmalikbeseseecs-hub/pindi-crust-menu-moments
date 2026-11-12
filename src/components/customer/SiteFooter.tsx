import { Link } from "@tanstack/react-router";
import { useState, type FormEvent } from "react";
import { Mail, MapPin, Phone } from "lucide-react";
import { toast } from "sonner";
import { errorMessage, subscribeNewsletter } from "@/lib/api";
import { isBackendConfigured } from "@/lib/supabaseClient";
import { Logo } from "@/components/brand/Logo";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useSiteSettings } from "@/lib/site-settings";

const explore = [
  { to: "/menu", label: "Menu" },
  { to: "/categories", label: "Categories" },
  { to: "/favorites", label: "Favorites" },
  { to: "/track", label: "Track Order" },
] as const;

const support = [
  { to: "/contact", label: "Contact Us" },
  { to: "/about", label: "About Us" },
  { to: "/privacy", label: "Privacy Policy" },
  { to: "/terms", label: "Terms & Conditions" },
] as const;

export function SiteFooter() {
  const { brand, storeInfo } = useSiteSettings();
  const socials = [
    brand.social.instagram && {
      label: "Instagram",
      href: `https://instagram.com/${brand.social.instagram.replace(/^@/, "")}`,
    },
    brand.social.facebook && {
      label: "Facebook",
      href: `https://facebook.com/${brand.social.facebook.replace(/^@/, "")}`,
    },
    brand.social.tiktok && {
      label: "TikTok",
      href: `https://tiktok.com/@${brand.social.tiktok.replace(/^@/, "")}`,
    },
  ].filter(Boolean) as { label: string; href: string }[];
  return (
    <footer className="mt-16 border-t border-border bg-surface-container">
      <div className="mx-auto grid max-w-7xl gap-10 px-4 py-12 sm:px-6 lg:grid-cols-4">
        <div className="lg:col-span-1">
          <Logo />
          <p className="mt-4 max-w-xs text-sm leading-relaxed text-muted-foreground text-pretty">
            {brand.footerText}
          </p>
          {socials.length > 0 && (
            <ul className="mt-4 flex flex-wrap gap-2">
              {socials.map((s) => (
                <li key={s.label}>
                  <a
                    href={s.href}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="rounded-full border border-border bg-card px-3 py-1.5 text-xs font-semibold text-muted-foreground transition-colors hover:border-primary/40 hover:text-primary"
                  >
                    {s.label}
                  </a>
                </li>
              ))}
            </ul>
          )}
        </div>

        <FooterCol title="Explore" links={explore} />
        <FooterCol title="Support" links={support} />

        <div>
          <h3 className="font-display text-base font-bold">Join the Crust Circle</h3>
          <p className="mt-2 text-sm text-muted-foreground">
            Fresh drops, secret menus and members-only deals.
          </p>
          <NewsletterForm />
          <ul className="mt-6 space-y-2 text-sm text-muted-foreground">
            <li className="flex items-start gap-2">
              <MapPin className="mt-0.5 size-4 shrink-0 text-primary" />{" "}
              {storeInfo.address ?? "Address not published yet"}
            </li>
            <li className="flex items-center gap-2">
              <Phone className="size-4 shrink-0 text-primary" />{" "}
              {storeInfo.phone ?? "Phone not published yet"}
            </li>
            <li className="flex items-center gap-2">
              <Mail className="size-4 shrink-0 text-primary" />{" "}
              {storeInfo.email ?? "Email not published yet"}
            </li>
          </ul>
        </div>
      </div>

      <div className="border-t border-border">
        <div className="mx-auto flex max-w-7xl flex-col items-center justify-between gap-2 px-4 py-5 text-xs text-muted-foreground sm:flex-row sm:px-6">
          <p>{brand.copyright}</p>
          {storeInfo.hours && <p>{storeInfo.hours}</p>}
        </div>
      </div>
    </footer>
  );
}

function FooterCol({
  title,
  links,
}: {
  title: string;
  links: readonly { to: string; label: string }[];
}) {
  return (
    <div>
      <h3 className="text-[11px] font-bold tracking-[0.18em] text-primary uppercase">{title}</h3>
      <ul className="mt-4 space-y-2.5">
        {links.map((l) => (
          <li key={l.to}>
            <Link
              to={l.to}
              className="text-sm text-muted-foreground transition-colors hover:text-primary"
            >
              {l.label}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function NewsletterForm() {
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!EMAIL_RE.test(email.trim())) {
      setError("Enter a valid email address");
      return;
    }
    setError(null);
    setBusy(true);
    try {
      await subscribeNewsletter(email);
      toast.success("You're on the list!");
      setEmail("");
    } catch (err) {
      toast.error(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="mt-4" onSubmit={onSubmit} noValidate>
      <div className="flex gap-2">
        <Input
          type="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="Email address"
          aria-label="Email address"
          aria-invalid={!!error}
        />
        <Button type="submit" variant="hero" disabled={busy}>
          Join
        </Button>
      </div>
      {error && <p className="mt-1.5 text-xs text-destructive">{error}</p>}
      {!isBackendConfigured && (
        <p className="mt-1.5 text-[11px] text-muted-foreground">
          Sign-ups open once the backend is connected.
        </p>
      )}
    </form>
  );
}
