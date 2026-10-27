// Three themes: the signature "Aurora" glass, a light "Daybreak", and a high-contrast theme. The tokens live here
// so the contrast tests read the same values the app applies as CSS custom properties.

export type ThemeId = "aurora" | "daybreak" | "contrast";

export interface Theme {
    id: ThemeId;
    label: string;
    scheme: "dark" | "light";
    /** Solid colors that text sits on, from the darkest to the lightest; text must pass WCAG AA on each. */
    surfaces: string[];
    tokens: Record<string, string>;
}

export const THEMES: Record<ThemeId, Theme> = {
    aurora: {
        id: "aurora",
        label: "Aurora",
        scheme: "dark",
        surfaces: ["#0B0720", "#1A1438", "#2E2257"],
        tokens: {
            "--bg": "#0B0720",
            "--bg-gradient":
                "radial-gradient(70rem 48rem at 8% -6%, rgba(124, 58, 237, 0.42), transparent 62%), radial-gradient(58rem 44rem at 102% 18%, rgba(13, 148, 136, 0.34), transparent 60%), radial-gradient(48rem 40rem at 46% 112%, rgba(219, 39, 119, 0.22), transparent 64%), linear-gradient(160deg, #0d0826 0%, #0b0720 48%, #071a24 100%)",
            "--panel": "rgba(255, 255, 255, 0.065)",
            "--panel-strong": "rgba(255, 255, 255, 0.11)",
            "--panel-solid": "#1A1438",
            "--border": "rgba(255, 255, 255, 0.15)",
            "--border-strong": "rgba(255, 255, 255, 0.3)",
            "--shadow": "0 24px 60px rgba(4, 2, 20, 0.55)",
            "--blur": "18px",
            "--ink": "#F5F3FF",
            "--ink-soft": "#D3CCF7",
            "--ink-faint": "#B9B1E6",
            "--accent": "#A78BFA",
            "--accent-2": "#2DD4BF",
            "--accent-3": "#F472B6",
            "--accent-ink": "#120A3A",
            "--brand-gradient": "linear-gradient(120deg, #8B5CF6 0%, #A78BFA 35%, #2DD4BF 100%)",
            "--focus": "#FDE047",
            "--grid": "rgba(255, 255, 255, 0.09)",
            "--status-fail": "#FF8FA3",
            "--status-manual": "#7DD3FC",
            "--status-warning": "#FCD34D",
            "--status-pass": "#86EFAC",
            "--status-muted": "#BDB6E3",
            "--t1": "#A78BFA",
            "--t2": "#2DD4BF",
            "--t3": "#F472B6",
            "--heat-0": "rgba(167, 139, 250, 0.08)",
            "--heat-1": "#7C3AED",
            "--heat-2": "#2DD4BF",
            "--heat-3": "#FDE047",
        },
    },
    daybreak: {
        id: "daybreak",
        label: "Daybreak",
        scheme: "light",
        surfaces: ["#FFFFFF", "#F6F4FF", "#ECE8FB"],
        tokens: {
            "--bg": "#F6F4FF",
            "--bg-gradient":
                "radial-gradient(64rem 44rem at 6% -8%, rgba(196, 181, 253, 0.55), transparent 60%), radial-gradient(56rem 40rem at 104% 16%, rgba(153, 246, 228, 0.5), transparent 62%), radial-gradient(48rem 36rem at 40% 112%, rgba(251, 207, 232, 0.55), transparent 64%), linear-gradient(170deg, #faf8ff 0%, #f4f1ff 55%, #eefbf8 100%)",
            "--panel": "rgba(255, 255, 255, 0.74)",
            "--panel-strong": "rgba(255, 255, 255, 0.92)",
            "--panel-solid": "#FFFFFF",
            "--border": "rgba(76, 29, 149, 0.14)",
            "--border-strong": "rgba(76, 29, 149, 0.32)",
            "--shadow": "0 20px 50px rgba(76, 29, 149, 0.12)",
            "--blur": "16px",
            "--ink": "#1E1B4B",
            "--ink-soft": "#3B3572",
            "--ink-faint": "#514A86",
            "--accent": "#6D28D9",
            "--accent-2": "#0F766E",
            "--accent-3": "#BE185D",
            "--accent-ink": "#FFFFFF",
            "--brand-gradient": "linear-gradient(120deg, #6D28D9 0%, #7C3AED 40%, #0F766E 100%)",
            "--focus": "#B45309",
            "--grid": "rgba(30, 27, 75, 0.1)",
            "--status-fail": "#B91C3B",
            "--status-manual": "#0369A1",
            "--status-warning": "#92400E",
            "--status-pass": "#047857",
            "--status-muted": "#57527F",
            "--t1": "#6D28D9",
            "--t2": "#0F766E",
            "--t3": "#BE185D",
            "--heat-0": "rgba(109, 40, 217, 0.07)",
            "--heat-1": "#A78BFA",
            "--heat-2": "#0D9488",
            "--heat-3": "#B45309",
        },
    },
    contrast: {
        id: "contrast",
        label: "High contrast",
        scheme: "dark",
        surfaces: ["#000000"],
        tokens: {
            "--bg": "#000000",
            "--bg-gradient": "none",
            "--panel": "#000000",
            "--panel-strong": "#000000",
            "--panel-solid": "#000000",
            "--border": "#FFFFFF",
            "--border-strong": "#FFFFFF",
            "--shadow": "none",
            "--blur": "0px",
            "--ink": "#FFFFFF",
            "--ink-soft": "#F2F2F2",
            "--ink-faint": "#DADADA",
            "--accent": "#FFFF00",
            "--accent-2": "#00FFFF",
            "--accent-3": "#FF99FF",
            "--accent-ink": "#000000",
            "--brand-gradient": "linear-gradient(120deg, #FFFF00, #00FFFF)",
            "--focus": "#FFFF00",
            "--grid": "rgba(255, 255, 255, 0.35)",
            "--status-fail": "#FF7B7B",
            "--status-manual": "#00FFFF",
            "--status-warning": "#FFFF00",
            "--status-pass": "#5CFF9D",
            "--status-muted": "#DADADA",
            "--t1": "#D4B8FF",
            "--t2": "#00FFFF",
            "--t3": "#FF99FF",
            "--heat-0": "rgba(255, 255, 255, 0.12)",
            "--heat-1": "#8A8AFF",
            "--heat-2": "#00FFFF",
            "--heat-3": "#FFFF00",
        },
    },
};

export const THEME_ORDER: ThemeId[] = ["aurora", "daybreak", "contrast"];

/** Tokens used as text on the theme's surfaces; each must reach 4.5:1 (WCAG 2.1 AA, normal text). */
export const TEXT_TOKENS = ["--ink", "--ink-soft", "--ink-faint", "--status-fail", "--status-manual", "--status-warning", "--status-pass", "--status-muted", "--accent", "--t1", "--t2", "--t3"];

export function isThemeId(value: unknown): value is ThemeId {
    return value === "aurora" || value === "daybreak" || value === "contrast";
}

export function applyTheme(id: ThemeId, root: HTMLElement = document.documentElement): void {
    const theme = THEMES[id];
    for (const [name, value] of Object.entries(theme.tokens)) root.style.setProperty(name, value);
    root.dataset.theme = id;
    root.style.colorScheme = theme.scheme;
}

const THEME_KEY = "dbhub-insights.theme.v1";

export function loadTheme(storage: Pick<Storage, "getItem"> | undefined, prefersContrast: boolean, prefersLight: boolean): ThemeId {
    try {
        const saved = storage?.getItem(THEME_KEY);
        if (isThemeId(saved)) return saved;
    } catch {
        // Ignore unavailable storage.
    }
    if (prefersContrast) return "contrast";
    return prefersLight ? "daybreak" : "aurora";
}

export function saveTheme(storage: Pick<Storage, "setItem"> | undefined, id: ThemeId): void {
    try {
        storage?.setItem(THEME_KEY, id);
    } catch {
        // Ignore unavailable storage.
    }
}

/** WCAG relative luminance of #RRGGBB. */
export function luminance(hex: string): number {
    const value = hex.replace("#", "");
    const channel = (i: number) => {
        const c = parseInt(value.slice(i, i + 2), 16) / 255;
        return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    };
    return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
}

export function contrastRatio(a: string, b: string): number {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
}
