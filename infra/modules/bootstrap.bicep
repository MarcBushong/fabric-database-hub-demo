metadata description = 'The managed Run Command DbHubDemo-Bootstrap on each VM, which runs the bootstrap loader (ADR 0003). Deployed only after Send-DemoBootstrapBundle has delivered the bundle in Run Command chunks, when deploy.ps1 passes the bundle SHA-256 and chunk count.'

@description('Azure region.')
param location string

@description('Tags for the Run Command resources.')
param tags object

@description('SHA-256 of the bundle zip. The loader checks every chunk and the whole bundle and fails closed on a mismatch. A new value re-runs the loader.')
@minLength(64)
@maxLength(64)
param bundleSha256 string

@description('Number of chunks Send-DemoBootstrapBundle delivered to each VM.')
@minValue(1)
@maxValue(999)
param chunkCount int

@description('Name of the T1 VM.')
param sqlVmName string

@description('Name of the T2 VM: archost01, or arcsql01 in the evaluation-only mode.')
param hostVmName string

@description('Bootstrap role of the T2 VM: ArcHost, or EvalArcVm in the evaluation-only mode (ADR 0006).')
@allowed([
  'ArcHost'
  'EvalArcVm'
])
param hostRole string = 'ArcHost'

@description('Non-secret settings for the T1 bootstrap.')
param sqlVmSettings object

@description('Non-secret settings for the T2 host bootstrap.')
param hostSettings object

// The loader is embedded at build time (96 KB limit per file; a test checks the size). It assembles the
// bundle from its chunks, checks every SHA-256, extracts it, registers the SYSTEM scheduled task, starts
// it, and returns.
var loaderScript = loadTextContent('../../vm/bootstrap/Invoke-DemoBootstrapLoader.ps1')

// Run Command passes parameters to a Windows script as '-Name value' arguments, so the settings are
// Base64-encoded to keep their JSON quotes intact; the loader decodes them. Nothing here is secret.
var targets = [
  {
    vmName: sqlVmName
    role: 'SqlVm'
    settings: sqlVmSettings
  }
  {
    vmName: hostVmName
    role: hostRole
    settings: hostSettings
  }
]

resource vms 'Microsoft.Compute/virtualMachines@2025-11-01' existing = [
  for target in targets: {
    name: target.vmName
  }
]

// treatFailureAsDeploymentFailure stays false so the deployment never waits on the loader;
// Wait-DemoBootstrapLoader reads the instance view and reports the loader's exit code instead.
resource loaders 'Microsoft.Compute/virtualMachines/runCommands@2025-11-01' = [
  for (target, i) in targets: {
    parent: vms[i]
    name: 'DbHubDemo-Bootstrap'
    location: location
    tags: tags
    properties: {
      asyncExecution: true
      treatFailureAsDeploymentFailure: false
      timeoutInSeconds: 1800
      source: {
        script: loaderScript
      }
      parameters: [
        {
          name: 'BundleSha256'
          value: toLower(bundleSha256)
        }
        {
          name: 'ChunkCount'
          value: string(chunkCount)
        }
        {
          name: 'Role'
          value: target.role
        }
        {
          name: 'SettingsJson'
          value: base64(string(target.settings))
        }
      ]
    }
  }
]

@description('Names of the Run Command resources, one per VM.')
output runCommandNames string[] = [for (target, i) in targets: loaders[i].name]
