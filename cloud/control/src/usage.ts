import type { MachineEvent } from "./services";

/** Whether an event leaves the machine running. */
function running(event: MachineEvent): boolean | null {
  if (event.type === "start" || event.type === "launch") return event.status === "started" || event.type === "start";
  if (event.type === "exit" || event.type === "stop" || event.type === "destroy") return false;
  return null;
}

/**
 * Seconds the machine ran between `from` and `to` (unix seconds), from Fly's machine events
 * (timestamps in milliseconds). The state at `from` is the last event before it says; with
 * none, the machine was stopped.
 */
export function runningSeconds(events: MachineEvent[], from: number, to: number): number {
  const sorted = [...events].sort((a, b) => a.timestamp - b.timestamp);
  let up = false;
  let since = from;
  let total = 0;
  for (const event of sorted) {
    const at = event.timestamp / 1000;
    const next = running(event);
    if (next === null) continue;
    if (at <= from) {
      up = next;
      continue;
    }
    if (at >= to) break;
    if (up && !next) total += at - since;
    if (!up && next) since = at;
    up = next;
  }
  if (up) total += to - since;
  return Math.max(0, Math.round(total));
}
