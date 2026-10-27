# Configuration

`config/demo.config.json` holds your settings. Git ignores it, and it holds no secrets. Start from `config/demo.config.example.json`; `config/environment.schema.json` is the source of truth for every setting, its default, and its rules, and every script validates the file against it before it does anything.

This page explains the settings whose behavior needs more than the schema's description. Each section belongs to the feature it configures.

## Fabric

The demo's Fabric items live in one workspace and its lakehouse, which you configure **by name**. The scripts resolve their IDs at run time and create them when they're missing ([ADR 0021](adr/0021-fabric-resources-by-name.md)); you never look up or store a Fabric ID.

```json
"fabric": {
  "workspaceName": "Database Hub Demo",
  "lakehouseName": "LH_DatabaseHub",
  "capacityName": "your-fabric-capacity",
  "createIfMissing": true,
  "importNotebooks": false
}
```

| Setting | Default | What it does |
|---|---|---|
| `workspaceName` | `Database Hub Demo` | The workspace that holds the notebooks, the lakehouse, the Real-Time Dashboard, the history model and report, and the Insights app. The scripts find the one workspace with this name among those you can access (personal workspaces are skipped) |
| `lakehouseName` | `LH_DatabaseHub` | The lakehouse the notebooks write their history tables to, and the history model reads, in that workspace |
| `capacityName` | empty | The Fabric capacity to create the workspace on, or to assign it to when it has none. It must be an F or Trial capacity that you administer or contribute to, and it must be running. Not used when the workspace exists and has a capacity |
| `createIfMissing` | `true` | Create the workspace (on `capacityName`) and the lakehouse when they're missing |
| `importNotebooks` | `false` | Whether `deploy.ps1` also updates the notebooks when they're already in the workspace. With `false`, it imports only the notebooks that are missing, so a new workspace or lakehouse gets them without asking, and edits you made in Fabric are kept. Running `configure-fabric.ps1` yourself always creates or updates them |
| `workspaceId`, `lakehouseId` | not set | Optional overrides, not needed: an ID here is used as it is, and the name isn't looked up. They're kept for configurations written before ADR 0021; the all-zero ID counts as not set |

**What happens on a deploy** (`deploy.ps1`'s Fabric track, or `configure-fabric.ps1`):

1. The workspace is found by name. When it's missing and `createIfMissing` is true, it's created on `capacityName`; a workspace without a capacity is assigned to it.
2. The lakehouse is found by name in that workspace, or created with lakehouse schemas: the history model reads its tables from the `dbo` schema.
3. The notebooks are imported, bound to that lakehouse. The repository's notebooks hold no IDs: the import puts the resolved ones in the uploaded copy, and every scripted run passes them as parameters. When `github.repository` is set, and isn't the example's placeholder, the uploaded copies' `GITHUB_REPOSITORY` and `GITHUB_ENVIRONMENT` come from `github.repository` and `github.environment`, so the live-activity notebook triggers your repository's workflow; otherwise they keep their defaults, the public repository and `demo`.
4. When the live-activity notebook was just created, or the lakehouse was, the notebook runs once, so the history tables exist before the model's refresh. It writes only the lakehouse's tables.
5. The Real-Time Dashboard, the model and report, and the app go into the same workspace.

**What the scripts never do:** create, resume, pause, or scale a capacity. A paused capacity is **Manual action required**, and its administrator resumes it. Scripts that only read (`preflight.ps1`, `status.ps1`, `validate.ps1`) never create anything; when the workspace or lakehouse doesn't exist yet, they report a **Warning** that names the step that creates it.

**What creating needs:** the Fabric tenant setting "Create workspaces" for you, and a contributor or administrator role on the capacity ([prerequisites](prerequisites.md), P5). Without them, the script reports **Manual action required** with the exact steps, and a workspace administrator can create the workspace and add you as Contributor or higher instead. Using an existing workspace needs only Contributor on it.

**Checks** (ADR 0012): `FABRIC.RESOLVE.WORKSPACE`, `FABRIC.RESOLVE.LAKEHOUSE`, and, when a capacity is assigned, `FABRIC.RESOLVE.CAPACITY`, in `configure-fabric.ps1`, `configure-powerbi.ps1`, `configure-fabric-app.ps1`, and `validate.ps1`; `PREFLIGHT.P5.WORKSPACE` in `preflight.ps1`; and `STATUS.FABRIC` in `status.ps1`. Messages name the workspace, the lakehouse, and the capacity, never their IDs.
