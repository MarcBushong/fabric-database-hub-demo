import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { LogOut, Sparkles, Wind } from "lucide-react";

import { AppContext, type AppContextValue, type MotionPreference } from "./app-context";
import { useAuth } from "./hooks/auth.context";
import { toMeta } from "./data/model";
import { metaQuery, type Filters } from "./data/queries";
import { useQuery } from "./data/use-query";
import { SQL_TARGETS, type TargetKey } from "./lib/dax";
import { formatAgo } from "./lib/format";
import { useMediaQuery } from "./lib/hooks";
import type { AppRuntime } from "./lib/runtime-config";
import { isEmbedded, loadSavedView, mergeView, PAGES, parseHash, saveView, toHash, windowRange, WINDOWS, type ViewState } from "./lib/view-state";
import { applyTheme, loadTheme, saveTheme, THEME_ORDER, THEMES, type ThemeId } from "./theme/themes";

const EstatePage = lazy(() => import("./pages/EstatePage"));
const IncidentsPage = lazy(() => import("./pages/IncidentsPage"));
const ReadinessPage = lazy(() => import("./pages/ReadinessPage"));
const LinksPage = lazy(() => import("./pages/LinksPage"));

const TARGET_LABEL: Record<TargetKey, string> = { T1: "T1 · Azure VM", T2: "T2 · Arc", T3: "T3 · Azure SQL DB" };
const MOTION_KEY = "dbhub-insights.motion.v1";

function initialView(): ViewState {
    const fromHash = typeof window !== "undefined" ? parseHash(window.location.hash) : {};
    const saved = typeof window !== "undefined" ? loadSavedView(window.localStorage) : {};
    return mergeView(saved, fromHash);
}

function initialMotion(): MotionPreference {
    try {
        const saved = window.localStorage.getItem(MOTION_KEY);
        return saved === "reduced" || saved === "full" ? saved : "system";
    } catch {
        return "system";
    }
}

export default function App({ runtime }: { runtime: AppRuntime }) {
    const { session, signOut } = useAuth();
    const prefersContrast = useMediaQuery("(prefers-contrast: more)");
    const prefersLight = useMediaQuery("(prefers-color-scheme: light)");
    const osReduced = useMediaQuery("(prefers-reduced-motion: reduce)");
    const [theme, setThemeState] = useState<ThemeId>(() => loadTheme(window.localStorage, prefersContrast, prefersLight));
    const [motionPref, setMotionPref] = useState<MotionPreference>(initialMotion);
    const [view, setViewState] = useState<ViewState>(initialView);
    const [toast, setToast] = useState<string | null>(null);
    const embedded = useMemo(() => isEmbedded(), []);
    const reducedMotion = motionPref === "reduced" || (motionPref === "system" && osReduced);

    const metaSpec = useMemo(() => metaQuery(), []);
    const metaState = useQuery(metaSpec);
    const meta = useMemo(() => toMeta(metaState.data?.rows ?? []), [metaState.data]);

    useEffect(() => applyTheme(theme), [theme]);
    useEffect(() => {
        document.documentElement.dataset.motion = reducedMotion ? "reduced" : "full";
    }, [reducedMotion]);
    useEffect(() => {
        // Keep the view in the frame's hash (it survives a reload) and remember it per browser; never add history
        // entries, because inside the portal the frame shares the portal's back button.
        const hash = toHash(view);
        if (window.location.hash !== hash) window.history.replaceState(null, "", hash);
        saveView(window.localStorage, view);
    }, [view]);
    useEffect(() => {
        if (!toast) return;
        const timer = window.setTimeout(() => setToast(null), 2600);
        return () => window.clearTimeout(timer);
    }, [toast]);

    const setView = useCallback((patch: Partial<ViewState>) => setViewState((v) => ({ ...v, ...patch })), []);
    const setTheme = useCallback((id: ThemeId) => {
        setThemeState(id);
        saveTheme(window.localStorage, id);
    }, []);
    const setMotion = useCallback((value: MotionPreference) => {
        setMotionPref(value);
        try {
            window.localStorage.setItem(MOTION_KEY, value);
        } catch {
            // Storage can be unavailable; the choice still applies to this session.
        }
    }, []);

    const filters: Filters = useMemo(() => ({ targets: view.targets, window: windowRange(view.window, meta?.latestDay ?? null) }), [view.targets, view.window, meta]);

    const context: AppContextValue = useMemo(
        () => ({ runtime, embedded, view, setView, filters, meta, theme, setTheme, motion: motionPref, setMotion, reducedMotion, notify: setToast }),
        [runtime, embedded, view, setView, filters, meta, theme, setTheme, motionPref, setMotion, reducedMotion],
    );

    const toggleTarget = (t: TargetKey) => {
        const next = view.targets.includes(t) ? view.targets.filter((x) => x !== t) : SQL_TARGETS.filter((x) => x === t || view.targets.includes(x));
        if (next.length > 0) setView({ targets: next, replay: null });
    };

    const Page = { estate: EstatePage, incidents: IncidentsPage, readiness: ReadinessPage, links: LinksPage }[view.page];
    const email = session?.user?.email && session.user.email !== "unknown" ? session.user.email : null;
    const wrongAccount = Boolean(runtime.expectedAccount && email && email.toLowerCase() !== runtime.expectedAccount.toLowerCase());

    return (
        <AppContext.Provider value={context}>
            <a className="skip-link" href="#main">
                Skip to the content
            </a>
            <div className="shell">
                <header className="topbar glass">
                    <div className="brand">
                        <span className="brand-orb" aria-hidden="true" />
                        <div>
                            <h1>Database Hub Insights</h1>
                            <small>History of the hybrid SQL demo, from the lakehouse</small>
                        </div>
                        <span className="pill pill-preview">Preview</span>
                    </div>
                    <nav className="tabs" aria-label="Pages">
                        {PAGES.map((p) => (
                            <button key={p.id} type="button" className="tab" aria-current={view.page === p.id ? "page" : undefined} onClick={() => setView({ page: p.id })}>
                                {view.page === p.id ? <motion.span layoutId="tab-glow" className="tab-glow" transition={reducedMotion ? { duration: 0 } : { type: "spring", bounce: 0.25, duration: 0.5 }} /> : null}
                                <span>{p.label}</span>
                            </button>
                        ))}
                    </nav>
                    <div className="topbar-end">
                        <div className="swatches" role="group" aria-label="Theme">
                            {THEME_ORDER.map((id) => (
                                <button key={id} type="button" className={`swatch swatch-${id}`} aria-pressed={theme === id} aria-label={`${THEMES[id].label} theme`} title={`${THEMES[id].label} theme`} onClick={() => setTheme(id)} />
                            ))}
                        </div>
                        <button
                            type="button"
                            className="icon-btn"
                            aria-pressed={reducedMotion}
                            title={reducedMotion ? "Motion is off. Select to turn it on." : "Motion is on. Select to turn it off."}
                            aria-label="Reduce motion"
                            onClick={() => setMotion(reducedMotion ? "full" : "reduced")}
                        >
                            {reducedMotion ? <Wind aria-hidden="true" /> : <Sparkles aria-hidden="true" />}
                        </button>
                        <button type="button" className="icon-btn" onClick={signOut} title={email ? `Signed in as ${email}. Select to sign out.` : "Sign out"} aria-label="Sign out">
                            <LogOut aria-hidden="true" />
                        </button>
                    </div>
                </header>

                {wrongAccount ? (
                    <p className="glass banner" role="alert">
                        ▲ You're signed in as {email}, not the demo's account ({runtime.expectedAccount}). If data doesn't load, sign out, open an InPrivate window, sign in to Fabric as {runtime.expectedAccount}, and
                        open the app from its workspace item.
                    </p>
                ) : null}

                {view.page !== "links" ? (
                    <section className="filterbar glass" aria-label="Filters">
                        <span className="label">Targets</span>
                        {SQL_TARGETS.map((t) => (
                            <button key={t} type="button" className="chip" aria-pressed={view.targets.includes(t)} onClick={() => toggleTarget(t)}>
                                <span className="dot" style={{ background: `var(--${t.toLowerCase()})` }} aria-hidden="true" />
                                {TARGET_LABEL[t]}
                            </button>
                        ))}
                        <span className="label">Period</span>
                        <div className="segmented" role="group" aria-label="Period, ending on the newest telemetry day">
                            {WINDOWS.map((w) => (
                                <button key={w.id} type="button" aria-pressed={view.window === w.id} onClick={() => setView({ window: w.id, replay: null })}>
                                    {w.label}
                                </button>
                            ))}
                        </div>
                        <span className="history-note">
                            {meta?.latestCapture ? `History, not live · newest snapshot ${formatAgo(meta.latestCapture)} · all times UTC` : metaState.error ? metaState.error.message : "History, not live · all times UTC"}
                        </span>
                    </section>
                ) : null}

                <main id="main" tabIndex={-1}>
                    <Suspense fallback={<div className="skeleton" aria-busy="true" />}>
                        <AnimatePresence mode="wait">
                            <motion.div
                                key={view.page}
                                initial={reducedMotion ? false : { opacity: 0, y: 18, filter: "blur(6px)" }}
                                animate={{ opacity: 1, y: 0, filter: "blur(0px)" }}
                                exit={reducedMotion ? undefined : { opacity: 0, y: -10, filter: "blur(4px)" }}
                                transition={{ duration: reducedMotion ? 0 : 0.45, ease: [0.16, 1, 0.3, 1] }}
                            >
                                <Page />
                            </motion.div>
                        </AnimatePresence>
                    </Suspense>
                </main>

                <footer className="foot">
                    <span>Fabric Apps (preview) · read-only · data: SM_DatabaseHub_History through the semantic model connector, as you</span>
                    <span>{email ? `Signed in as ${email}` : ""}</span>
                </footer>
            </div>
            <AnimatePresence>
                {toast ? (
                    <motion.div className="toast" role="status" initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: 12 }}>
                        {toast}
                    </motion.div>
                ) : null}
            </AnimatePresence>
        </AppContext.Provider>
    );
}
