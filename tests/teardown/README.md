# Teardown tests

Live, opt-in checks that `destroy.ps1` leaves nothing behind, Arc resources included ([ADR 0002](../../docs/adr/0002-resource-group-topology.md)), and the deployment-stack trial ([ADR 0001](../../docs/adr/0001-iac-bicep-avm-compiled-arm.md)). Phase 16 adds them. The static run (`tests/Invoke-StaticValidation.ps1`) never runs them: it runs `tests/unit` only, and `Teardown.Residue.Tests.ps1` skips every test unless it's asked to run and has a configuration. [Cleanup](../../docs/cleanup.md) has the tested results.

| File | What it does | Changes anything? |
|---|---|---|
| `Teardown.Residue.Tests.ps1` | Pester tests over `Test-DemoTeardownResidue` (`TEARDOWN.RESIDUAL.*`): the resource group, everything carrying the environment's deploymentId, Arc machines, extensions, and SQL Server instances, role assignments, managed identities and their P6 membership, subscription deployment records, the budget, references from outside the group, and the platform records. A Warning the check can't settle yet is inconclusive, not a failure | No (read-only) |
| `Invoke-TeardownTest.ps1` | Runs `destroy.ps1 -Force` first with `-Destroy`, then the tests | Only with `-Destroy` |
| `Invoke-DeploymentStackTrial.ps1` | Creates, updates, and deletes two small deployment stacks (free user-assigned identities only) in `rg-<prefix>-stacktest`, then removes everything it made | Yes, in its own resource group only |
| `stack-trial/*.bicep` | The trial's templates, at resource group and subscription scope | |

## Run them

Every script runs the subscription guard first, never signs in, and never changes the Azure CLI's default subscription: sign in with `az login --tenant <tenantId>`, and the scripts pass the configured subscription to every command.

- **Check a destroyed environment** (read-only):

  ```powershell
  ./tests/teardown/Invoke-TeardownTest.ps1 -ConfigPath ./out/demo.config.test.json
  ```

  Or run the tests directly with `-Live` (or `DBHUB_TEARDOWN_TESTS=true`) and a configuration (`-ConfigPath` or `DBHUB_TEARDOWN_CONFIG`). They read the manifest `destroy.ps1` wrote before it deleted anything, `out/destroy-manifest-<environment>.json` (or `-ManifestPath`, `DBHUB_TEARDOWN_MANIFEST`): it holds the deploymentId and the managed identities, which can't be found once the resource group is gone. That default path is shared by every prefix and subscription with the same environment name, so the tests stop when the manifest is of another resource group or subscription.

  The same check with the demo's status model, as `destroy.ps1` reports it, is `./scripts/destroy.ps1 -ConfigPath <file> -ResidueOnly`: it reads the saved manifest, deletes nothing, and exits 1 only on a Fail ([Cleanup](../../docs/cleanup.md#check-again-later-read-only)).

  Only this environment counts: its resource group by its exact name and its deploymentId, never the solution and environment tags alone, which another prefix's environment with the same environment name carries too. Resource Graph rows that Azure Resource Manager says are gone are index records, not residue. A Warning the tests can't settle (rows Resource Manager didn't confirm within the check's bound of reads, or no manifest) is inconclusive; a role assignment that a tenant policy gave a deleted identity outside the demo's groups is a Warning the tests accept.

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
