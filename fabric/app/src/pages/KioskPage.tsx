// The kiosk (ADR 0030): Mission Control, the scoreboard, and the replay, round and round, without the app's frame, for a
// booth or NOC screen. Space pauses, the arrows switch scenes, and Esc leaves for Mission Control.

import { useCallback, useEffect, useMemo, useReducer, useState } from "react";
import { Button } from "@fluentui/react-components";
import { ArrowExit16Regular, FullScreenMaximize16Regular, Pause16Filled, Play16Filled } from "@fluentui/react-icons";

import { useApp } from "@/app-context";
import { serviceOf } from "@/lib/business";
import { formatDayUtc, formatTimeUtc } from "@/lib/format";
import { minutesText, summarize } from "@/lib/scoreboard";
import { CinematicReplay, type CinematicReplayProps } from "@/mission/CinematicReplay";
import { enterFullscreen, exitFullscreen, fullscreenAllowed, KIOSK_SCENES, KIOSK_START, kioskReducer, RETRY_SECONDS, SCENE_LABEL, SCENE_SECONDS } from "@/mission/kiosk";
import { mapNodes } from "@/mission/nodes";
import { BigStat } from "@/mission/parts";
import { ServiceMap } from "@/mission/ServiceMap";
import { SessionRibbon } from "@/mission/SessionRibbon";
import { Stage } from "@/mission/Stage";
import { useMission } from "@/mission/use-mission";

import "@/mission/mission.css";

export default function KioskPage() {
    const { navigate, reducedMotion, view } = useApp();
    const data = useMission();
    const [state, dispatch] = useReducer(kioskReducer, KIOSK_START);
    const [fullscreen, setFullscreen] = useState(() => typeof document !== "undefined" && Boolean(document.fullscreenElement));
    const { plan, scores, episodes, health } = data;
    const summary = useMemo(() => summarize(scores), [scores]);
    const nodes = useMemo(() => mapNodes(health, scores, episodes, data.postgres), [health, scores, episodes, data.postgres]);

    useEffect(() => {
        const timer = window.setInterval(() => dispatch({ type: "tick", seconds: 1 }), 1000);
        return () => window.clearInterval(timer);
    }, []);
    useEffect(() => {
        const onKey = (event: KeyboardEvent) => {
            if (["Escape", " ", "Spacebar", "ArrowLeft", "ArrowRight"].includes(event.key)) {
                event.preventDefault();
                dispatch({ type: "key", key: event.key });
            }
        };
        const onFullscreen = () => setFullscreen(Boolean(document.fullscreenElement));
        window.addEventListener("keydown", onKey);
        document.addEventListener("fullscreenchange", onFullscreen);
        return () => {
            window.removeEventListener("keydown", onKey);
            document.removeEventListener("fullscreenchange", onFullscreen);
        };
    }, []);
    // A booth screen runs unattended: when any of its history fails to load or refresh, it keeps what it shows and asks again.
    const failing = Boolean(data.error || data.loadError || data.scoreError);
    const { refetch } = data;
    useEffect(() => {
        if (!failing) return;
        const timer = window.setInterval(refetch, RETRY_SECONDS * 1000);
        return () => window.clearInterval(timer);
    }, [failing, refetch]);
    useEffect(() => {
        if (!state.exit) return;
        exitFullscreen();
        navigate("mission", { session: view.session });
    }, [state.exit, navigate, view.session]);
    const scene = state.scene;

    const left = Math.max(0, SCENE_SECONDS[scene] - state.elapsed);
    return (
        <Stage className="kiosk" label="Kiosk">
            <div className="kiosk-bar">
                <span className="kiosk-brand">ContosoCare · Mission Control</span>
                <ol className="kiosk-scenes" aria-label="Scenes">
                    {KIOSK_SCENES.map((s) => (
                        <li key={s}>
                            <button type="button" aria-current={s === scene ? "step" : undefined} onClick={() => dispatch({ type: "go", scene: s })}>
                                {SCENE_LABEL[s]}
                            </button>
                        </li>
                    ))}
                </ol>
                <span className="kiosk-status">{state.paused ? "Paused" : `Next scene in ${left} s`}</span>
                {/* What a screen reader hears: the scene, and whether the kiosk is paused; never the countdown. */}
                <span className="sr-only" aria-live="polite">
                    {`${SCENE_LABEL[scene]}${state.paused ? ", paused" : ""}`}
                </span>
                {failing && plan ? <span className="kiosk-hint">{`Some of the history didn't load: trying again every ${RETRY_SECONDS} s`}</span> : null}
                <Button size="small" appearance="subtle" icon={state.paused ? <Play16Filled /> : <Pause16Filled />} aria-pressed={state.paused} onClick={() => dispatch({ type: "toggle" })}>
                    {state.paused ? "Play" : "Pause"}
                </Button>
                {fullscreen ? null : fullscreenAllowed() ? (
                    <Button size="small" appearance="subtle" icon={<FullScreenMaximize16Regular />} onClick={() => enterFullscreen(document.documentElement)}>
                        Full screen
                    </Button>
                ) : (
                    <span className="kiosk-hint">Press F11 for full screen</span>
                )}
                <Button size="small" appearance="subtle" icon={<ArrowExit16Regular />} onClick={() => dispatch({ type: "key", key: "Escape" })}>
                    Exit (Esc)
                </Button>
            </div>
            <div className="kiosk-progress" aria-hidden="true">
                <span style={{ width: `${Math.min(100, (state.elapsed / SCENE_SECONDS[scene]) * 100)}%` }} />
            </div>
            <main className={`kiosk-scene kiosk-scene-${scene}`} aria-label={SCENE_LABEL[scene]}>
                {!plan && !data.loading ? (
                    <p className="kiosk-empty">
                        {data.missingSession
                            ? "The session this kiosk was opened for isn't in this period: Esc goes back to Mission Control."
                            : data.error
                              ? `The history didn't load (${data.error.message.replace(/\.$/, "")}): the kiosk tries again every ${RETRY_SECONDS} s.`
                              : "No session in this period yet: Run all in NB_DatabaseHub_Control runs one."}
                    </p>
                ) : null}
                {scene === "mission" ? (
                    <div className="kiosk-mission">
                        <ServiceMap nodes={nodes} lens="business" motion={!reducedMotion} title="ContosoCare's services, in business words" hubLine={plan ? `${plan.label}` : "care network"} />
                        <div className="kiosk-stats">
                            <BigStat label="Faults injected" value={plan ? String(summary.faults) : "–"} sub={plan ? `${formatDayUtc(plan.start)} ${formatTimeUtc(plan.start)}–${formatTimeUtc(plan.end)} UTC` : undefined} />
                            <BigStat label="Seen in telemetry" value={summary.faults ? `${summary.visible} of ${summary.faults}` : "–"} tone={summary.notVisible ? "alert" : "good"} />
                            <BigStat label="Median time to detect" value={minutesText(summary.ttdMedian)} />
                            <BigStat label="Median time to recover" value={minutesText(summary.ttrMedian)} />
                        </div>
                    </div>
                ) : null}
                {scene === "scoreboard" && plan ? (
                    <div className="kiosk-score">
                        <h2>{`Did we catch it? ${summary.visible} of ${summary.faults}`}</h2>
                        <SessionRibbon plan={plan} scores={scores} episodes={episodes} />
                        <ul className="kiosk-impacts">
                            {[...scores.filter((s) => s.impact).map((s) => s.impact!), ...episodes.map((e) => e.impact)].slice(0, 6).map((impact, i) => (
                                <li key={i}>
                                    <strong>{impact.headline}</strong>
                                    <span>{impact.evidence}</span>
                                </li>
                            ))}
                        </ul>
                        <p className="kiosk-foot">{`The app knows what was injected: ${serviceOf("T3")?.service} on T3, and every other service, measured from the history.`}</p>
                    </div>
                ) : null}
                {scene === "replay" && plan ? (
                    <KioskReplay
                        plan={plan}
                        scores={scores}
                        episodes={episodes}
                        bins={data.bins}
                        cosmos={data.cosmos}
                        postgres={data.postgres}
                        health={health}
                        motion={!reducedMotion}
                        paused={state.paused}
                    />
                ) : null}
            </main>
        </Stage>
    );
}

/** The replay scene: the session from its start each time the kiosk comes back to it, playing until paused. */
function KioskReplay(props: Omit<CinematicReplayProps, "minute" | "onMinute" | "lens" | "autoplay" | "loop" | "compact">) {
    const [minute, setMinute] = useState(0);
    const onMinute = useCallback((m: number) => setMinute(m), []);
    return <CinematicReplay {...props} minute={minute} onMinute={onMinute} lens="business" autoplay loop compact />;
}
