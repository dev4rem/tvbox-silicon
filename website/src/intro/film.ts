// Intro film: every scene's CSS animations are paused and driven from one clock, so the
// seek bar can scrub the whole film. Scenes play in document order: each one's data-len is its
// length in seconds, and data-keys lists its Siri Remote presses ("<second> <key>, …", scene-relative)
// so the remote beside the TV mirrors what happens on screen.
// The film renders in a shadow root so its styles and the host page's never touch.
import type { Lang } from "../i18n/strings";
import css from "./film.css?inline";
import markup from "./film.html?raw";
import { translateFilm, tr } from "./film-i18n";
import { sfSvg } from "../sf-icons";

const FADE = 0.45;
const PRESS = 0.28;

export interface FilmOptions {
  lang: Lang;
  /** Second to open at, paused. */
  startAt?: number;
  /** Space and arrow keys control the film (standalone page only). */
  keys?: boolean;
}

const easeOut = (x: number) => 1 - (1 - x) ** 3;
const clock = (t: number) => {
  const s = Math.floor(t);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

/** Renders the film into `host` and starts it. Returns a function that stops it. */
export function mountFilm(host: HTMLElement, { lang, startAt, keys = false }: FilmOptions): () => void {
  const shadow = host.shadowRoot ?? host.attachShadow({ mode: "open" });
  shadow.innerHTML = `<style>${css}</style>${markup}`;
  const root = shadow.querySelector<HTMLElement>(".film")!;
  root.lang = lang;
  translateFilm(root, lang);
  // SF Symbols: each <i data-sf="name"> becomes the traced symbol, sized like a glyph of the surrounding text.
  for (const icon of root.querySelectorAll<HTMLElement>("[data-sf]")) icon.outerHTML = sfSvg(icon.dataset.sf!);

  const scenes = Array.from(root.querySelectorAll<HTMLElement>(".scene"));
  const times: [number, number][] = [];
  const presses: [number, string][] = [];
  let total = 0;
  for (const el of scenes) {
    for (const press of el.dataset.keys?.split(",") ?? []) {
      const [at, key] = press.trim().split(" ");
      presses.push([total + Number(at), key]);
    }
    times.push([total, (total += Number(el.dataset.len))]);
  }
  const pp = root.querySelector<HTMLButtonElement>("#pp")!;
  const seek = root.querySelector<HTMLInputElement>("#seek")!;
  const out = root.querySelector<HTMLOutputElement>("#clock")!;
  const chap = root.querySelector<HTMLElement>("#chap")!;
  const led = root.querySelector<HTMLElement>("#led")!;
  const remoteKeys = Array.from(root.querySelectorAll<HTMLElement>(".remote [data-k]"));
  seek.max = String(total);

  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  let t = reduced ? 2 : 0;
  let playing = !reduced;
  if (startAt !== undefined) { t = Math.min(total - 0.01, Math.max(0, startAt)); playing = false; }
  let last: number | null = null;
  let visible = true;
  let raf = 0;

  const label = () => { pp.textContent = tr(lang, playing ? "Pause" : t >= total - 0.05 ? "Replay" : "Play"); };

  function render() {
    let chapter = "";
    scenes.forEach((el, i) => {
      const [s, e] = times[i];
      const on = t >= s && t < e;
      el.style.visibility = on ? "visible" : "hidden";
      if (!on) { el.style.opacity = "0"; return; }
      chapter = el.dataset.ch ?? "";
      el.style.opacity = String(Math.max(0, Math.min((t - s) / FADE, (e - t) / FADE, 1)));
      const local = t - s;
      for (const a of el.getAnimations({ subtree: true })) { a.pause(); a.currentTime = local * 1000; }
      el.querySelectorAll<HTMLElement>(".cnt").forEach((c) => {
        const p = Math.max(0, Math.min(1, (local - Number(c.dataset.d)) / Number(c.dataset.dur)));
        c.textContent = String(Math.round(Number(c.dataset.to) * easeOut(p)));
      });
    });
    chap.querySelector("span")!.textContent = chapter;
    chap.classList.toggle("on", chapter !== "");

    const down = new Set(presses.filter(([at]) => t >= at && t < at + PRESS).map(([, k]) => k));
    for (const k of remoteKeys) k.classList.toggle("on", down.has(k.dataset.k!));
    led.classList.toggle("on", down.size > 0);

    seek.value = String(t);
    out.textContent = `${clock(t)} / ${clock(total)}`;
  }

  // Offscreen, the clock stops and nothing renders.
  function frame(now: number) {
    if (visible) {
      if (playing && last !== null) t += Math.min((now - last) / 1000, 0.1);
      if (t >= total) { t = total - 0.01; playing = false; label(); }
      last = now;
      render();
    } else {
      last = null;
    }
    raf = requestAnimationFrame(frame);
  }

  const toggle = () => {
    if (!playing && t >= total - 0.05) t = 0;
    playing = !playing;
    label();
  };
  const onSeek = () => { t = Number(seek.value); render(); };
  const onKey = (e: KeyboardEvent) => {
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLButtonElement || e.target instanceof HTMLSelectElement) return;
    if (e.key === " ") { e.preventDefault(); toggle(); }
    else if (e.key === "ArrowRight") t = Math.min(total - 0.01, t + 5);
    else if (e.key === "ArrowLeft") t = Math.max(0, t - 5);
  };
  pp.addEventListener("click", toggle);
  seek.addEventListener("input", onSeek);
  if (keys) addEventListener("keydown", onKey);
  const io = new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; });
  io.observe(host);

  label();
  render();
  raf = requestAnimationFrame(frame);

  return () => {
    cancelAnimationFrame(raf);
    io.disconnect();
    if (keys) removeEventListener("keydown", onKey);
    pp.removeEventListener("click", toggle);
    seek.removeEventListener("input", onSeek);
  };
}
