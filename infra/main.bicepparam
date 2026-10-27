using 'main.bicep'

// Defaults for the lowest-cost profile in West US 3. scripts/deploy.ps1 generates the real parameters
// from config/demo.config.json; this file is for what-if, manual runs, and PSRule in CI. The only secret,
// adminPassword, is never set here (ADR 0009).
param prefix = 'dbhub'
param environment = 'demo'
param networkMode = 'public'
param outboundMode = 'DefaultOutboundAccess'
param owner = 'demo-owner'
param ownerEmail = 'owner@example.com'
param costCenter = 'demo'
param autoShutdownTime = '1900'
param autoShutdownTimeZone = 'Pacific Standard Time'
param monthlyCeilingUsd = 250
param enableLocks = false
param profile = 'lowest-cost'
param zone = ''
param dataDiskSku = 'Auto'
param t1Priority = 'Regular'
param hostPriority = 'Regular'
param t1SecurityType = 'Standard'
param hostSecurityType = 'Standard'
param windowsHybridBenefit = false
param sqlHybridBenefit = false
param hybridBenefitAttested = false
param t2SqlInstallMode = 'PaygWizard'
param t2Mode = 'Nested'
param assignArcOnboardingRole = false
param existingVmNames = []
// Placeholder for the P6 group's object ID (prerequisite P6); deploy.ps1 passes t3AdminGroupObjectId from the configuration.
param t3AdminGroupObjectId = '00000000-0000-0000-0000-000000000000'
param t3UseFreeLimit = true
