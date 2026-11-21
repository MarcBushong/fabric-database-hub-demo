import { lazy, Suspense, useCallback, useContext, useEffect, useMemo, useState, type ComponentType } from "react";
import { MessageBar, MessageBarBody, Spinner, Toast, ToastTitle, Toaster, useId, useToastController } from "@fluentui/react-components";

import { AppContext, MANAGE_READ_ONLY, type AppContextValue, type ManageAccess, type NotifyIntent } from "./app-context";
import { manageAccessOf, type ManageApi } from "./lib/manage-client";
import type { DataProvenance } from "./copilot/contract";
import { toMeta } from "./data/model";
import { metaQuery, type Filters } from "./data/queries";
import { QueryClientContext, useQuery } from "./data/use-query";
import { useAuth } from "./hooks/auth.context";
import { sqlTargets } from "./lib/estate";
import { useMediaQuery } from "./lib/hooks";
import type { AppRuntime } from "./lib/runtime-config";
import { isEmbedded, loadSavedView, mergeView, parseHash, replaceAddress, saveView, toHash, windowRange, type PageId, type ViewState } from "./lib/view-state";
import { AppShell } from "./shell/AppShell";

const MissionControlPage = lazy(() => import("./pages/MissionControlPage"));
const OverviewPage = lazy(() => import("./pages/OverviewPage"));
const EstatePage = lazy(() => import("./pages/EstatePage"));
const PerformancePage = lazy(() => import("./pages/PerformancePage"));
const IncidentsPage = lazy(() => import("./pages/IncidentsPage"));
const RcaPage = lazy(() => import("./pages/RcaPage"));
const ScoreboardPage = lazy(() => import("./pages/ScoreboardPage"));
const ReplayPage = lazy(() => import("./pages/ReplayPage"));
const FindingsPage = lazy(() => import("./pages/FindingsPage"));
const ReadinessPage = lazy(() => import("./pages/ReadinessPage"));
const TrendsPage = lazy(() => import("./pages/TrendsPage"));
const ManagePage = lazy(() => import("./pages/ManagePage"));
const LinksPage = lazy(() => import("./pages/LinksPage"));
const KioskPage = lazy(() => import("./pages/KioskPage"));

const PAGE_COMPONENTS: Record<PageId, ComponentType> = {
    mission: MissionControlPage,
    overview: OverviewPage,
    estate: EstatePage,
    performance: PerformancePage,
    incidents: IncidentsPage,
    rca: RcaPage,
    scoreboard: ScoreboardPage,
    replay: ReplayPage,
    findings: FindingsPage,
    readiness: ReadinessPage,
    trends: TrendsPage,
    manage: ManagePage,
    links: LinksPage,
    kiosk: KioskPage,
};

function initialView(): ViewState {
    const fromHash = typeof window !== "undefined" ? parseHash(window.location.hash) : {};
    const saved = typeof window !== "undefined" ? loadSavedView(window.localStorage) : {};
    return mergeView(saved, fromHash);
}

export interface AppProps {
    runtime: AppRuntime;
    provenance?: DataProvenance;
    /** A fixed Manage mode (the preview and the tests); otherwise the app asks manageApi. */
    manage?: ManageAccess;
    /** The app's Manage function: when it answers, actions run from the app (A); when it doesn't, they're copied (C). */
    manageApi?: ManageApi;
}

/** Which way Manage sends actions here, from the Manage function's answer about the signed-in viewer. */
function useManageAccess(fixed: ManageAccess | undefined, api: ManageApi | undefined): ManageAccess {
    const [detected, setDetected] = useState<ManageAccess | null>(null);
    const [refreshing, setRefreshing] = useState(false);
    const fallBack = useCallback((reason: string) => setDetected({ ...MANAGE_READ_ONLY, reason }), []);
    useEffect(() => {
        if (fixed || !api) return;
        let alive = true;
        api.access().then(
            (a) => {
                if (alive) setDetected(manageAccessOf(a, api, fallBack));
            },
            () => {
                if (alive) setDetected(MANAGE_READ_ONLY);
            },
        );
        return () => {
            alive = false;
        };
    }, [fixed, api, fallBack]);
    // The control's run in progress, read again before each action and after a start: the control takes one request at a
    // time, and the function refuses any other while one runs. Copy mode, once a request fell back to it, stays.
    const refresh = useCallback(async () => {
        if (!api) return;
        setRefreshing(true);
        try {
            const a = await api.access();
            setDetected((current) => (current && current.mode === "copy" ? current : manageAccessOf(a, api, fallBack)));
        } catch {
            // What the page had stays; the function checks each request again anyway.
        } finally {
            setRefreshing(false);
        }
    }, [api, fallBack]);
    const live = useMemo(() => (detected && detected.mode === "run" ? { ...detected, refresh, refreshing } : detected), [detected, refresh, refreshing]);
    if (fixed) return fixed;
    if (!api) return MANAGE_READ_ONLY;
    return live ?? { ...MANAGE_READ_ONLY, checking: true, reason: "Checking whether this app can send actions…" };
}

export default function App({ runtime, provenance = "history", manage: fixedManage, manageApi }: AppProps) {
    const manage = useManageAccess(fixedManage, manageApi);
    const { session, signOut } = useAuth();
    const reducedMotion = useMediaQuery("(prefers-reduced-motion: reduce)");
    const [view, setViewState] = useState<ViewState>(initialView);
    const toasterId = useId("toaster");
    const { dispatchToast } = useToastController(toasterId);
    const embedded = useMemo(() => isEmbedded(), []);

    const metaSpec = useMemo(() => metaQuery(), []);
    const metaState = useQuery(metaSpec);
    const meta = useMemo(() => toMeta(metaState.data?.rows ?? []), [metaState.data]);

    // Whether the history model has the Incident RCA's tables (ADR 0031): without them the app behaves as the release
    // before it did, with no Root cause view or links. A check that fails, after the retries a throttled or failed read
    // gets, says nothing about the model (live, 2026-11-21): rca stays unknown, and Root cause says why, with Try again,
    // never that no capture is recorded. Its code loads only when it's asked.
    const queryClient = useContext(QueryClientContext);
    const [rca, setRca] = useState<boolean | null>(null);
    const [rcaError, setRcaError] = useState<string | null>(null);
    const [rcaAsked, setRcaAsked] = useState(0);
    const [rcaRetrying, setRcaRetrying] = useState(false);
    useEffect(() => {
        if (!queryClient) return;
        let alive = true;
        import("./rca/client")
            .then((m) => m.checkRcaTables(queryClient))
            .then(
                (check) => {
                    if (!alive) return;
                    setRca(check.state === "failed" ? null : check.state === "present");
                    setRcaError(check.state === "failed" ? check.error : null);
                    setRcaRetrying(false);
                },
                (err: unknown) => {
                    if (!alive) return;
                    setRca(null);
                    setRcaError(err instanceof Error ? err.message : String(err));
                    setRcaRetrying(false);
                },
            );
        return () => {
            alive = false;
        };
    }, [queryClient, rcaAsked]);
    // Try again keeps the failure, and Root cause in the navigation, until the new check answers.
    const retryRca = useCallback(() => {
        setRcaRetrying(true);
        setRcaAsked((n) => n + 1);
    }, []);

    useEffect(() => {
        document.documentElement.dataset.motion = reducedMotion ? "reduced" : "full";
    }, [reducedMotion]);
    useEffect(() => {
        // Keep the view in the frame's hash (it survives a reload) and remember it per browser; never add history
        // entries, because inside the portal the frame shares the portal's back button.
        replaceAddress(toHash(view));
        saveView(window.localStorage, view);
    }, [view]);

    const setView = useCallback((patch: Partial<ViewState>) => setViewState((v) => ({ ...v, ...patch })), []);
    const navigate = useCallback(
        (page: PageId, patch: Partial<ViewState> = {}) => {
            setViewState((v) => ({ ...v, page, target: null, incident: null, replay: null, category: null, ...patch }));
            document.getElementById("main")?.scrollTo?.({ top: 0 });
        },
        [],
    );
    const notify = useCallback(
        (message: string, intent: NotifyIntent = "info") =>
            dispatchToast(
                <Toast>
                    <ToastTitle>{message}</ToastTitle>
                </Toast>,
                { intent, timeout: 2600 },
            ),
        [dispatchToast],
    );

    const filters: Filters = useMemo(() => ({ targets: sqlTargets(view.targets), window: windowRange(view.window, meta?.latestDay ?? null) }), [view.targets, view.window, meta]);

    const context: AppContextValue = useMemo(
        () => ({
            runtime,
            embedded,
            view,
            setView,
            navigate,
            filters,
            meta,
            metaLoading: metaState.loading,
            metaError: metaState.error ?? null,
            provenance,
            reducedMotion,
            notify,
            manage,
            rca,
            rcaError,
            rcaRetrying,
            retryRca,
        }),
        [runtime, embedded, view, setView, navigate, filters, meta, metaState.loading, metaState.error, provenance, reducedMotion, notify, manage, rca, rcaError, rcaRetrying, retryRca],
    );

    const Page = PAGE_COMPONENTS[view.page];
    const email = session?.user?.email && session.user.email !== "unknown" ? session.user.email : null;
    const wrongAccount = Boolean(runtime.expectedAccount && email && email.toLowerCase() !== runtime.expectedAccount.toLowerCase());

    const banner = wrongAccount ? (
        <MessageBar intent="warning" className="shell-banner">
            <MessageBarBody>
                You're signed in as {email}, not the demo's account ({runtime.expectedAccount}). If data doesn't load, sign out, open an InPrivate window, sign in to Fabric as {runtime.expectedAccount}, and open the app from its
                workspace item.
            </MessageBarBody>
        </MessageBar>
    ) : null;

    const loading = (
        <div className="page-loading">
            <Spinner size="small" label="Loading the page" />
        </div>
    );

    // The kiosk runs without the app's frame: no top bar, no navigation, no dock.
    if (view.page === "kiosk") {
        return (
            <AppContext.Provider value={context}>
                <Suspense fallback={loading}>
                    <Page />
                </Suspense>
                <Toaster toasterId={toasterId} position="bottom-end" />
            </AppContext.Provider>
        );
    }

    return (
        <AppContext.Provider value={context}>
            <AppShell email={email} onSignOut={signOut} banner={banner}>
                <Suspense fallback={loading}>
                    <Page />
                </Suspense>
            </AppShell>
            <Toaster toasterId={toasterId} position="bottom-end" />
        </AppContext.Provider>
    );
}
