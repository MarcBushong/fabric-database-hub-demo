// The global filter: which targets and which period every page shows, and where the data comes from.

import { Button, Menu, MenuItemCheckbox, MenuList, MenuPopover, MenuTrigger, ToggleButton, type MenuProps } from "@fluentui/react-components";
import { Filter16Regular } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { ProvenanceBadge } from "@/components/ProvenanceBadge";
import { TARGETS } from "@/lib/estate";
import { FILTER_TARGETS, WINDOWS, type FilterTarget } from "@/lib/view-state";

export function GlobalFilter() {
    const { view, setView, meta, provenance } = useApp();
    const all = view.targets.length === FILTER_TARGETS.length;
    const label = all ? "All targets" : view.targets.join(", ");

    const onChange: MenuProps["onCheckedValueChange"] = (_, data) => {
        const picked = data.checkedItems.filter((t): t is FilterTarget => (FILTER_TARGETS as readonly string[]).includes(t));
        if (picked.length > 0) setView({ targets: FILTER_TARGETS.filter((t) => picked.includes(t)), replay: null });
    };

    return (
        <div className="global-filter" role="group" aria-label="Filter every page">
            <Menu checkedValues={{ targets: view.targets }} onCheckedValueChange={onChange}>
                <MenuTrigger disableButtonEnhancement>
                    <Button size="small" appearance="outline" icon={<Filter16Regular />} aria-label={`Targets: ${label}`}>
                        {label}
                    </Button>
                </MenuTrigger>
                <MenuPopover>
                    <MenuList>
                        {FILTER_TARGETS.map((t) => (
                            <MenuItemCheckbox key={t} name="targets" value={t} disabled={view.targets.length === 1 && view.targets[0] === t}>
                                <span className="target-chip">
                                    <i style={{ background: TARGETS[t].color }} aria-hidden="true" />
                                    {`${t} · ${TARGETS[t].name}`}
                                </span>
                            </MenuItemCheckbox>
                        ))}
                    </MenuList>
                </MenuPopover>
            </Menu>
            <div className="period" role="group" aria-label="Period, ending on the newest telemetry day">
                {WINDOWS.map((w) => (
                    <ToggleButton key={w.id} size="small" appearance="subtle" checked={view.window === w.id} onClick={() => setView({ window: w.id, replay: null })}>
                        {w.label}
                    </ToggleButton>
                ))}
            </div>
            <ProvenanceBadge provenance={provenance} asOf={meta?.latestCapture} />
            <span className="utc-note">All times UTC</span>
        </div>
    );
}
