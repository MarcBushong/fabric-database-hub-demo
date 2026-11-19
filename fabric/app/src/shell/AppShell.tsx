// The app's frame: the top bar, the left navigation, the page, and the Copilot dock on the right.

import { useState, type ComponentType, type ReactNode } from "react";
import { Button, Menu, MenuItemRadio, MenuList, MenuPopover, MenuTrigger, Tooltip, type MenuProps } from "@fluentui/react-components";
import {
    ArrowTrending20Filled,
    ArrowTrending20Regular,
    ClipboardTaskListLtr20Filled,
    ClipboardTaskListLtr20Regular,
    Database20Filled,
    Database20Regular,
    DarkTheme20Regular,
    Home20Filled,
    Home20Regular,
    Navigation20Regular,
    Open20Filled,
    Open20Regular,
    ShieldCheckmark20Filled,
    ShieldCheckmark20Regular,
    Sparkle20Filled,
    Toolbox20Filled,
    Toolbox20Regular,
    TopSpeed20Filled,
    TopSpeed20Regular,
    Warning20Filled,
    Warning20Regular,
    bundleIcon,
} from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { useCopilotDock } from "@/copilot/use-copilot";
import { useMediaQuery } from "@/lib/hooks";
import { PAGES, type PageId } from "@/lib/view-state";
import { THEME_LABELS, type ThemeChoice } from "@/theme/fluent";
import { useTheme } from "@/theme/theme-context";
import { AccountChips } from "./AccountChips";
import { DockRegion } from "./DockRegion";

const ICONS: Record<PageId, ComponentType<{ className?: string }>> = {
    overview: bundleIcon(Home20Filled, Home20Regular),
    estate: bundleIcon(Database20Filled, Database20Regular),
    performance: bundleIcon(TopSpeed20Filled, TopSpeed20Regular),
    incidents: bundleIcon(Warning20Filled, Warning20Regular),
    findings: bundleIcon(ShieldCheckmark20Filled, ShieldCheckmark20Regular),
    readiness: bundleIcon(ClipboardTaskListLtr20Filled, ClipboardTaskListLtr20Regular),
    trends: bundleIcon(ArrowTrending20Filled, ArrowTrending20Regular),
    manage: bundleIcon(Toolbox20Filled, Toolbox20Regular),
    links: bundleIcon(Open20Filled, Open20Regular),
};

const NAV_KEY = "dbhub-insights.nav.v1";

function loadNav(): boolean | null {
    try {
        const saved = window.localStorage.getItem(NAV_KEY);
        return saved === "open" ? true : saved === "rail" ? false : null;
    } catch {
        return null;
    }
}

function ThemeMenu() {
    const { choice, setChoice } = useTheme();
    const onChange: MenuProps["onCheckedValueChange"] = (_, data) => {
        const next = data.checkedItems[0] as ThemeChoice | undefined;
        if (next) setChoice(next);
    };
    return (
        <Menu checkedValues={{ theme: [choice] }} onCheckedValueChange={onChange}>
            <MenuTrigger disableButtonEnhancement>
                <Tooltip content={`Theme: ${THEME_LABELS[choice]}`} relationship="label">
                    <Button appearance="subtle" icon={<DarkTheme20Regular />} />
                </Tooltip>
            </MenuTrigger>
            <MenuPopover>
                <MenuList>
                    {(Object.keys(THEME_LABELS) as ThemeChoice[]).map((id) => (
                        <MenuItemRadio key={id} name="theme" value={id}>
                            {THEME_LABELS[id]}
                        </MenuItemRadio>
                    ))}
                </MenuList>
            </MenuPopover>
        </Menu>
    );
}

export function AppShell({ email, onSignOut, banner, children }: { email: string | null; onSignOut: () => void; banner?: ReactNode; children: ReactNode }) {
    const { view, navigate, runtime } = useApp();
    const dock = useCopilotDock();
    const wide = useMediaQuery("(min-width: 1180px)");
    const [navPref, setNavPref] = useState<boolean | null>(loadNav);
    const navOpen = navPref ?? wide;

    const toggleNav = () => {
        const next = !navOpen;
        setNavPref(next);
        try {
            window.localStorage.setItem(NAV_KEY, next ? "open" : "rail");
        } catch {
            // The choice still applies to this session.
        }
    };

    return (
        <div className={`shell${navOpen ? " nav-open" : " nav-rail"}${dock.isOpen ? " dock-open" : ""}`}>
            <a className="skip-link" href="#main">
                Skip to the content
            </a>
            <header className="topbar">
                <Tooltip content={navOpen ? "Collapse the navigation" : "Expand the navigation"} relationship="label">
                    <Button appearance="subtle" icon={<Navigation20Regular />} onClick={toggleNav} aria-expanded={navOpen} aria-controls="app-nav" />
                </Tooltip>
                <div className="brand">
                    <span className="brand-mark" aria-hidden="true">
                        <Database20Filled />
                    </span>
                    <span className="brand-name">Database Hub Insights</span>
                    {runtime.resourceGroup ? <span className="brand-env">{runtime.resourceGroup}</span> : null}
                </div>
                <span className="topbar-spacer" />
                <Button className="copilot-toggle" appearance={dock.isOpen ? "primary" : "outline"} icon={<Sparkle20Filled />} aria-pressed={dock.isOpen} onClick={() => dock.setOpen(!dock.isOpen)}>
                    Copilot
                </Button>
                <ThemeMenu />
                <AccountChips email={email} onSignOut={onSignOut} />
            </header>

            <nav id="app-nav" className="nav" aria-label="Pages">
                <ul>
                    {PAGES.map((p) => {
                        const Icon = ICONS[p.id];
                        const current = view.page === p.id;
                        const button = (
                            <button type="button" className="nav-item" aria-current={current ? "page" : undefined} onClick={() => navigate(p.id)} aria-label={navOpen ? undefined : p.label}>
                                <Icon className={current ? "nav-icon filled" : "nav-icon"} />
                                {navOpen ? <span className="nav-label">{p.label}</span> : null}
                            </button>
                        );
                        return (
                            <li key={p.id} className={p.id === "manage" ? "nav-gap" : undefined}>
                                {navOpen ? (
                                    button
                                ) : (
                                    <Tooltip content={`${p.label}: ${p.description}`} relationship="description" positioning="after">
                                        {button}
                                    </Tooltip>
                                )}
                            </li>
                        );
                    })}
                </ul>
                {navOpen ? <p className="nav-foot">Fabric Apps (preview) · History of the demo's estate</p> : null}
            </nav>

            <main id="main" className="main" tabIndex={-1}>
                {banner}
                {children}
            </main>

            <DockRegion />
        </div>
    );
}
