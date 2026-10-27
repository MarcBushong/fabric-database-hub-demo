# Azure Automation runbooks

The optional on-demand activity control's runbooks ([ADR 0020](../docs/adr/0020-on-demand-activity-control.md)). `scripts/setup-activity-control.ps1` publishes them to `aa-<prefix>-control` in `rg-<prefix>-control`; nothing here runs on your machine.

| File | What it is |
|---|---|
| `runbooks/DbHub-Control.ps1` | Started only by its webhook, from the notebook `NB_DatabaseHub_Control`: validates the request, then runs, stops (Stop now), or resets the activity |
| `runbooks/DbHub-Stop.ps1` | Started only by schedules: `-Scope All`, the per-run auto-stop, and `-Scope T4`, the daily T4 safety stop. It never starts anything and never uses Run Command |
| `runbooks/DbHubControl.Common.ps1` | The code both share; setup puts it, and the settings, in place of each runbook's markers (`__DBHUB_SETTINGS__` and `# __DBHUB_COMMON__`), so a published runbook is self-contained |

- **Windows PowerShell 5.1,** which Learn recommends for webhooks, because a PowerShell 7 runbook receives the webhook's input as invalid JSON ([webhooks](https://learn.microsoft.com/azure/automation/automation-webhooks)). The static checks use the Windows PowerShell 5.1 rules for this folder, and a test runs the request validation in Windows PowerShell 5.1 too.
- **Azure Resource Manager REST only,** with the user-assigned identity `id-<prefix>-automation`'s token from the sandbox's identity endpoint ([user-assigned identity](https://learn.microsoft.com/azure/automation/add-user-assigned-identity)); no Az module, no secret, and every request stays in the configured subscription. Its one custom role is assigned at the demo resource group (A1) and at the control account (A2).
- **The settings** baked in at publish hold the names, the bounds, the scenario catalog's allow-lists, the pinned API versions, and the VM-side workload-control template (`Get-DemoWorkloadControlTemplate`), so a run sets each profile with the same request as `demo-control.ps1`. Run setup again after a scenario changes.
- **Nothing secret** is in the job output: the runbooks never see the webhook URL, and a token lives only in one job's memory. Each job prints its log, then one result line: `DBHUB-CONTROL <json>` or `DBHUB-STOP <json>`.

Tests: `tests/unit/Automation.Runbooks.Tests.ps1` (with Azure Resource Manager mocked) and `tests/unit/DbHubDemo.ActivityControl.Tests.ps1` (the published content).
