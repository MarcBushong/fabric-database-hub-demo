// The navigation's icons for the app's own pages (ADR 0030), loaded with them rather than in the main chunk.

import { bundleIcon, Replay20Filled, Replay20Regular, HeartPulse20Filled, HeartPulse20Regular, Trophy20Filled, Trophy20Regular } from "@fluentui/react-icons";

const ICONS = {
    mission: bundleIcon(HeartPulse20Filled, HeartPulse20Regular),
    scoreboard: bundleIcon(Trophy20Filled, Trophy20Regular),
    replay: bundleIcon(Replay20Filled, Replay20Regular),
};

export type WavePage = keyof typeof ICONS;

export default function WaveIcon({ page, className }: { page: WavePage; className?: string }) {
    const Icon = ICONS[page];
    return <Icon className={className} />;
}
