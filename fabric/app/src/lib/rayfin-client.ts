import { ConnectorsRayfinClient } from "@microsoft/rayfin-client";
import { fabricSemanticModel } from "@microsoft/rayfin-connector-fabric-semanticmodel";
import { connectorConfig as historyConfig, type HistorySchema } from "../../rayfin/connectors/history/schema";
import type { AppRuntime } from "./runtime-config";

type AppConnectorsSchema = { history: HistorySchema };
export type AppClient = ConnectorsRayfinClient<Record<string, never>, Record<string, never>, AppConnectorsSchema>;

let _client: AppClient | undefined;

/** The one Rayfin client: Fabric sign-in plus the read-only semantic model connector `history`. */
export function createRayfinClient(runtime: AppRuntime): AppClient {
    if (!_client) {
        _client = new ConnectorsRayfinClient<Record<string, never>, Record<string, never>, AppConnectorsSchema>(
            {
                baseUrl: runtime.apiUrl,
                publishableKey: runtime.publishableKey,
                authStorage: true,
                connectors: { history: historyConfig },
            },
            { history: fabricSemanticModel() },
        );
    }
    return _client;
}

export function getRayfinClient(): AppClient {
    if (!_client) throw new Error("The Rayfin client isn't ready yet.");
    return _client;
}
