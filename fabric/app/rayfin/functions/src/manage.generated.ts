// Manage's settings (ADR 0028). scripts/configure-fabric-app.ps1 writes the real ones into the deploy stage
// (out/fabric-app): the app's API, NB_DatabaseHub_Control's IDs, and the operators. Git holds this empty placeholder,
// so the function says it isn't set up, and the app copies each request for Run all instead.
import type { ManageSettings } from "./manage-core.js";

export const MANAGE_SETTINGS: ManageSettings = { apiUrl: "", controlWorkspaceId: "", controlNotebookId: "", operators: [] };
