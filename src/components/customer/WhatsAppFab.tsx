import { useStoreInfo } from "@/lib/site-settings";
import { MessageCircle } from "lucide-react";

export function WhatsAppFab() {
  const storeInfo = useStoreInfo();
  // No WhatsApp number is configured yet — hide the button rather than link to an invented number.
  if (!storeInfo.whatsapp) return null;
  const href = `https://wa.me/${storeInfo.whatsapp}?text=${encodeURIComponent(
    `Assalam-o-Alaikum ${storeInfo.brand}! I'd like to place an order.`,
  )}`;

  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={`Chat with ${storeInfo.brand} on WhatsApp`}
      className="animate-pulse-ring fixed right-4 bottom-24 z-50 grid size-13 place-items-center rounded-full bg-success text-success-foreground shadow-lift transition-transform hover:scale-110 sm:bottom-6 sm:size-14"
    >
      <MessageCircle className="size-6" strokeWidth={2} />
    </a>
  );
}
