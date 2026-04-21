import { writable } from "svelte/store";

export interface Metrics {
  chWidth: number;
  cjkWidth: number;
  rowHeight: number;
}

export const metrics = writable<Metrics>({ chWidth: 8, cjkWidth: 16, rowHeight: 20 });

function measureText(text: string, count: number, fontSize: number): number {
  const probe = document.createElement("div");
  probe.style.cssText = `position:absolute;visibility:hidden;white-space:pre;font-family:var(--font-mono);font-size:${fontSize}px;padding:0;margin:0;`;
  probe.textContent = text.repeat(count);
  document.body.appendChild(probe);
  const w = probe.getBoundingClientRect().width / count;
  probe.remove();
  return w;
}

export function measureMetrics(fontSize = 13): Metrics {
  if (typeof document === "undefined") {
    return { chWidth: 8, cjkWidth: 16, rowHeight: 20 };
  }
  const probe = document.createElement("div");
  probe.style.cssText = `position:absolute;visibility:hidden;white-space:pre;font-family:var(--font-mono);font-size:${fontSize}px;padding:0;margin:0;`;
  probe.textContent = "M".repeat(100);
  document.body.appendChild(probe);
  const w = probe.getBoundingClientRect().width / 100;
  const h = probe.getBoundingClientRect().height || fontSize * 1.54;
  probe.remove();
  const cjk = measureText("한", 50, fontSize);
  const m = {
    chWidth: w || fontSize * 0.6,
    cjkWidth: cjk || (w || fontSize * 0.6) * 2,
    rowHeight: Math.max(h, Math.ceil(fontSize * 1.4)),
  };
  metrics.set(m);
  return m;
}
