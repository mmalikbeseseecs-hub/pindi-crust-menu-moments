import { afterEach, describe, expect, it, vi } from "vitest";
import { manualPaymentError, OrderRinger, unacknowledgedOrders } from "@/lib/order-alerts";
import type { Order } from "@/lib/types";

const order: Order = { id: "PC-001", customer: "Customer", phone: "", items: [], total: 100, status: "pending", source: "online", payment: "cod", placedAt: "now", placedAtIso: "2026-11-09T06:00:00Z", address: "" };
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });

describe("required order notifications and payment details", () => {
  it("requires a transaction ID for online payment", () => {
    expect(manualPaymentError("easypaisa", "", "payer")).toBe("Transaction ID is required");
  });
  it("requires the online account name or username", () => {
    expect(manualPaymentError("jazzcash", "TXN123", " ")).toBe("Online account name or username is required");
  });
  it("does not require online payment details for cash", () => {
    expect(manualPaymentError("cod")).toBeNull();
  });
  it("keeps online orders ringing until acknowledged, not merely prepared", () => {
    expect(unacknowledgedOrders([{ ...order, status: "preparing" }]).map(o => o.id)).toEqual(["PC-001"]);
    expect(unacknowledgedOrders([{ ...order, alarmAcknowledgedAt: "2026-11-09T06:01:00Z" }])).toEqual([]);
  });
  it("does not ring for counter orders", () => {
    expect(unacknowledgedOrders([{ ...order, source: "pos" }])).toEqual([]);
  });
  it("repeats audio until explicitly stopped, then cancels scheduled tones", async () => {
    vi.useFakeTimers();
    const start = vi.fn(); const stop = vi.fn(); const create = vi.fn(() => ({ frequency: { value: 0 }, connect: vi.fn(), disconnect: vi.fn(), start, stop, onended: null }));
    const gain = () => ({ gain: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() }, connect: vi.fn(), disconnect: vi.fn() });
    vi.stubGlobal("AudioContext", class { state = "running"; currentTime = 0; destination = {}; resume = async () => {}; createOscillator = create; createGain = gain; close = async () => {}; });
    const ringer = new OrderRinger();
    await ringer.enable(); ringer.start(); ringer.start();
    expect(start).toHaveBeenCalledTimes(2);
    vi.advanceTimersByTime(1600); expect(start).toHaveBeenCalledTimes(4);
    ringer.stop(); const stopped = stop.mock.calls.length;
    vi.advanceTimersByTime(10000); expect(start).toHaveBeenCalledTimes(4);
    expect(stopped).toBe(8);
    ringer.dispose();
  });
});