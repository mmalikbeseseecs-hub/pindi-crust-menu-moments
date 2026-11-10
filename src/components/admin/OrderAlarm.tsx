import { useEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { BellRing, Volume2, Check } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { acknowledgeOrderAlarm, errorMessage, fetchUnacknowledgedOrders, subscribeToOrders } from "@/lib/api";
import { OrderRinger, unacknowledgedOrders } from "@/lib/order-alerts";
import { formatPKR } from "@/lib/format";
import { QueryErrorState } from "@/components/shared/BackendNotice";

export function OrderAlarm() {
  const client = useQueryClient();
  const ringer = useRef<OrderRinger | null>(null);
  const [soundEnabled, setSoundEnabled] = useState(false);
  const [saving, setSaving] = useState(false);
  const query = useQuery({ queryKey: ["order-alarms"], queryFn: fetchUnacknowledgedOrders });
  const pending = unacknowledgedOrders(query.data ?? []);
  const order = pending[0];

  useEffect(() => {
    ringer.current = new OrderRinger();
    const unsubscribe = subscribeToOrders(() => {
      void client.invalidateQueries({ queryKey: ["order-alarms"] });
      void client.invalidateQueries({ queryKey: ["orders"] });
    });
    return () => { unsubscribe(); ringer.current?.dispose(); };
  }, [client]);

  useEffect(() => {
    if (order && soundEnabled) ringer.current?.start();
    else ringer.current?.stop();
  }, [order?.id, soundEnabled]);

  async function enableSound() {
    try { await ringer.current?.enable(); setSoundEnabled(true); }
    catch { toast.error("Sound is blocked. Please enable sound in your browser and try again."); }
  }

  async function acknowledge() {
    if (!order || saving) return;
    setSaving(true);
    try {
      await acknowledgeOrderAlarm(order.id);
      ringer.current?.stop();
      await client.invalidateQueries({ queryKey: ["order-alarms"] });
    } catch (error) { toast.error(errorMessage(error, "Could not stop this alert. Try again.")); }
    finally { setSaving(false); }
  }

  return (
    <section className="border-b border-border px-4 py-3 sm:px-6" aria-label="Order notifications">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="flex items-center gap-2 text-sm font-semibold"><BellRing className="size-4 text-primary" />{pending.length} unacknowledged orders</p>
        <Button size="sm" variant="outline" disabled={soundEnabled} onClick={enableSound}><Volume2 className="size-4" />{soundEnabled ? "Sound enabled" : "Enable sound notifications"}</Button>
      </div>
      {query.error && <QueryErrorState error={query.error} onRetry={() => query.refetch()} />}
      {order && (
        <div role="alert" className="mt-3 flex flex-col gap-3 border-l-4 border-primary bg-primary-soft p-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="min-w-0">
            <p className="font-bold">New order · {order.id} · {order.customer}</p>
            <p className="mt-1 break-words text-sm">{order.items.map(item => `${item.qty} × ${item.name}`).join(", ")}</p>
            <p className="mt-1 text-sm font-semibold">{formatPKR(order.total)} · {order.payment === "cod" ? "Cash on delivery" : order.payment}</p>
          </div>
          <Button className="shrink-0" disabled={saving} onClick={acknowledge}><Check className="size-4" />{saving ? "Stopping…" : "Stop alarm & acknowledge"}</Button>
        </div>
      )}
    </section>
  );
}