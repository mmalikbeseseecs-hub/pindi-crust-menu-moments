import type { Order, PaymentMethod } from "./types";

export function unacknowledgedOrders(orders: Order[]): Order[] {
  return orders.filter((order) => order.source === "online" && !order.alarmAcknowledgedAt)
    .sort((a, b) => a.placedAtIso.localeCompare(b.placedAtIso));
}

export function manualPaymentError(payment: PaymentMethod, transactionId?: string, accountName?: string): string | null {
  if (payment === "cod") return null;
  if (!transactionId?.trim()) return "Transaction ID is required";
  if (!accountName?.trim()) return "Online account name or username is required";
  return null;
}

export class OrderRinger {
  private context: AudioContext | null = null;
  private timer: ReturnType<typeof setInterval> | null = null;
  private tones = new Set<OscillatorNode>();

  async enable() {
    this.context ??= new AudioContext();
    await this.context.resume();
    if (this.context.state !== "running") throw new Error("Sound could not be enabled.");
  }

  start() {
    if (this.timer) return;
    const ring = () => {
      const context = this.context;
      if (!context || context.state !== "running") return;
      for (const [offset, frequency] of [[0, 880], [0.3, 1175]] as const) {
        const tone = context.createOscillator();
        const gain = context.createGain();
        tone.frequency.value = frequency;
        tone.type = "sine";
        const start = context.currentTime + offset;
        gain.gain.setValueAtTime(0.001, start);
        gain.gain.exponentialRampToValueAtTime(0.18, start + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.001, start + 0.7);
        tone.connect(gain); gain.connect(context.destination);
        this.tones.add(tone);
        tone.onended = () => { this.tones.delete(tone); tone.disconnect(); gain.disconnect(); };
        tone.start(start); tone.stop(start + 0.75);
      }
    };
    ring();
    this.timer = setInterval(ring, 1600);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    for (const tone of this.tones) { try { tone.stop(); } catch { /* Already ended. */ } }
    this.tones.clear();
  }

  dispose() { this.stop(); void this.context?.close(); this.context = null; }
}