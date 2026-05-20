import { writable, derived } from "svelte/store";

export interface ThemeColors {
  bg0: string;
  bg1: string;
  bg2: string;
  bg3: string;
  fg0: string;
  fg1: string;
  fg2: string;
  accent: string;
  accentDim: string;
  dirty: string;
  danger: string;
}

export interface ThemePreset {
  id: string;
  name: string;
  colors: ThemeColors;
}

export const PRESETS: ThemePreset[] = [
  {
    id: "dark",
    name: "Dark",
    colors: {
      bg0: "#1e2227",
      bg1: "#272b31",
      bg2: "#2d3138",
      bg3: "#353a42",
      fg0: "#e6e6e6",
      fg1: "#b9bcc1",
      fg2: "#7c828a",
      accent: "#7aa2f7",
      accentDim: "#3d5a8a",
      dirty: "#e0af68",
      danger: "#f7768e",
    },
  },
  {
    id: "light",
    name: "Light",
    colors: {
      bg0: "#f5f5f4",
      bg1: "#e8e8e7",
      bg2: "#d9d9d8",
      bg3: "#c8c8c6",
      fg0: "#1a1a1a",
      fg1: "#3d3d3d",
      fg2: "#737373",
      accent: "#2563eb",
      accentDim: "#bfdbfe",
      dirty: "#d97706",
      danger: "#dc2626",
    },
  },
  {
    id: "nord",
    name: "Nord",
    colors: {
      bg0: "#2e3440",
      bg1: "#3b4252",
      bg2: "#434c5e",
      bg3: "#4c566a",
      fg0: "#eceff4",
      fg1: "#d8dee9",
      fg2: "#81a1c1",
      accent: "#88c0d0",
      accentDim: "#5e81ac",
      dirty: "#ebcb8b",
      danger: "#bf616a",
    },
  },
  {
    id: "solarized",
    name: "Solarized",
    colors: {
      bg0: "#002b36",
      bg1: "#073642",
      bg2: "#0a4555",
      bg3: "#0e5061",
      fg0: "#eee8d5",
      fg1: "#93a1a1",
      fg2: "#657b83",
      accent: "#268bd2",
      accentDim: "#1a5d8a",
      dirty: "#b58900",
      danger: "#dc322f",
    },
  },
  {
    id: "monokai",
    name: "Monokai",
    colors: {
      bg0: "#1e1e1e",
      bg1: "#272822",
      bg2: "#3e3d32",
      bg3: "#49483e",
      fg0: "#f8f8f2",
      fg1: "#cfcfc2",
      fg2: "#75715e",
      accent: "#a6e22e",
      accentDim: "#3d5a1a",
      dirty: "#e6db74",
      danger: "#f92672",
    },
  },
];

const STORAGE_KEY = "nova:theme";

function loadTheme(): ThemeColors {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) return JSON.parse(raw) as ThemeColors;
  } catch {}
  return PRESETS[0].colors;
}

function saveTheme(colors: ThemeColors): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(colors));
  } catch {}
}

export const themeColors = writable<ThemeColors>(loadTheme());

themeColors.subscribe((colors) => {
  saveTheme(colors);
});

export const activePresetId = derived(themeColors, ($colors) => {
  const preset = PRESETS.find(
    (p) =>
      p.colors.bg0 === $colors.bg0 &&
      p.colors.accent === $colors.accent &&
      p.colors.fg0 === $colors.fg0
  );
  return preset?.id ?? "custom";
});

export function applyTheme(colors: ThemeColors): void {
  const root = document.documentElement;
  root.style.setProperty("--bg-0", colors.bg0);
  root.style.setProperty("--bg-1", colors.bg1);
  root.style.setProperty("--bg-2", colors.bg2);
  root.style.setProperty("--bg-3", colors.bg3);
  root.style.setProperty("--fg-0", colors.fg0);
  root.style.setProperty("--fg-1", colors.fg1);
  root.style.setProperty("--fg-2", colors.fg2);
  root.style.setProperty("--accent", colors.accent);
  root.style.setProperty("--accent-dim", colors.accentDim);
  root.style.setProperty("--dirty", colors.dirty);
  root.style.setProperty("--danger", colors.danger);
}

export const themePanelOpen = writable(false);
