# Teardown tests

Live, opt-in checks that `destroy.ps1` leaves nothing behind, Arc resources included ([ADR 0002](../../docs/adr/0002-resource-group-topology.md)), and the deployment-stack trial ([ADR 0001](../../docs/adr/0001-iac-bicep-avm-compiled-arm.md)). Phase 16 adds them. The static run (`tests/Invoke-StaticValidation.ps1`) never runs them: it runs `tests/unit` only, and `Teardown.Residue.Tests.ps1` skips every test unless it's asked to run and has a configuration. [Cleanup](../../docs/cleanup.md) has the tested results.

| File | What it does | Changes anything? |
|---|---|---|
| `Teardown.Residue.Tests.ps1` | Pester tests over `Test-DemoTeardownResidue` (`TEARDOWN.RESIDUAL.*`): the resource group, everything carrying the environment's tags, Arc machines, extensions, and SQL Server instances, role assignments, managed identities and their P6 membership, subscription deployment records, the budget, references from outside the group, and the platform records | No (read-only) |
| `Invoke-TeardownTest.ps1` | Runs `destroy.ps1 -Force` first with `-Destroy`, then the tests | Only with `-Destroy` |
| `Invoke-DeploymentStackTrial.ps1` | Creates, updates, and deletes two small deployment stacks (free user-assigned identities only) in `rg-<prefix>-stacktest`, then removes everything it made | Yes, in its own resource group only |
| `stack-trial/*.bicep` | The trial's templates, at resource group and subscription scope | |

## Run them

Every script runs the subscription guard first, never signs in, and never changes the Azure CLI's default subscription: sign in with `az login --tenant <tenantId>`, and the scripts pass the configured subscription to every command.

- **Check a destroyed environment** (read-only):

  ```powershell
  ./tests/teardown/Invoke-TeardownTest.ps1 -ConfigPath ./out/demo.config.test.json
  ```

  Or run the tests directly with `-Live` (or `DBHUB_TEARDOWN_TESTS=true`) and a configuration (`-ConfigPath` or `DBHUB_TEARDOWN_CONFIG`). They read the manifest `destroy.ps1` wrote before it deleted anything, `out/destroy-manifest-<environment>.json` (or `-ManifestPath`, `DBHUB_TEARDOWN_MANIFEST`): it holds the deploymentId and the managed identities, which can't be found once the resource group is gone.

- **Destroy, then check** (deletes the environment):

  ```powershell
  ./tests/teardown/Invoke-TeardownTest.ps1 -ConfigPath ./out/demo.config.test.json -Destroy -ConfirmEnvironment test
  ```

  `-ConfirmEnvironment` must repeat the configuration's environment name. `-Destroy` refuses environment `demo` and any `PaygWizard` environment, whose setup-wizard step no script can redo, unless `-IncludeDemoEnvironment` records the owner's explicit go-ahead.

- **Deployment-stack trial** (about 15 minutes, no charge):

  ```powershell
  ./tests/teardown/Invoke-DeploymentStackTrial.ps1 -ConfigPath ./out/demo.config.test.json -Confirm:$false
  ```

  It refuses the configured environment's resource group, and a `rg-<prefix>-stacktest` group it didn't create (its `purpose` tag isn't `deployment-stack-trial`). Results go to `out/stack-trial.jsonl`; `TEARDOWN.STACK.CLEANUP` confirms that no trial stack, resource group, or deny assignment is left.

Use a disposable environment (its own `environment` name, so its own resource group) with `t2SqlInstallMode` `Developer`, so a redeploy needs no manual step. Never point `-Destroy` at an environment someone else uses without their agreement.
