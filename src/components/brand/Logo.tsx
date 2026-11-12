import { Link } from "@tanstack/react-router";
import { Flame } from "lucide-react";
import { cn } from "@/lib/utils";
import { useBrand } from "@/lib/site-settings";

/** Published logo (Admin → Settings → Brand) or the built-in flame wordmark. */
export function Logo({ className, compact = false }: { className?: string; compact?: boolean }) {
  const { brandName, logoUrl } = useBrand();
  const [first, ...rest] = brandName.split(" ");
  return (
    <Link
      to="/"
      className={cn("group flex min-w-0 items-center gap-2.5", className)}
      aria-label={`${brandName} home`}
    >
      {logoUrl ? (
        <img
          src={logoUrl}
          alt={brandName}
          className={cn("h-9 w-auto shrink-0 object-contain", compact ? "max-w-28" : "max-w-40")}
        />
      ) : (
        <span className="bg-ember-gradient grid size-9 shrink-0 place-items-center rounded-xl shadow-soft transition-transform group-hover:rotate-6">
          <Flame className="size-5 text-primary-foreground" strokeWidth={1.75} />
        </span>
      )}
      {!compact && !logoUrl && (
        <span className="font-display truncate text-lg leading-none font-bold tracking-tight text-primary sm:text-xl">
          {first} {rest.length > 0 && <span className="text-foreground">{rest.join(" ")}</span>}
        </span>
      )}
    </Link>
  );
}
