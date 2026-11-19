// The Insights app's Copilot chat relay (Ask, ADR 0027) in the demo resource group. scripts/configure-fabric-app.ps1
// deploys it before the app on every run (Invoke-DemoAskRelaySetup), and again with the app's origin once the app is
// deployed; destroy.ps1 deletes it with the group:
// - cae-<prefix>-<environment>-ask: a Container Apps environment on the Consumption workload profile, with no Log
//   Analytics workspace (console logs stream with az containerapp logs show, and nothing is kept).
// - ca-<prefix>-<environment>-ask: the relay. A public image pinned by digest (config/versions.json askRelay.image),
//   external HTTPS ingress (WebSocket included), and scale to zero, at most one replica. No secret, no registry
//   credential, no managed identity, no role: it holds only the GitHub OAuth App's public client ID and the one origin
//   it serves, the Insights app's.

targetScope = 'resourceGroup'

@description('Region of the relay; the demo region.')
param location string = resourceGroup().location

@description('The Container Apps environment: cae-<prefix>-<environment>-ask.')
@minLength(2)
@maxLength(60)
param environmentName string

@description('The container app: ca-<prefix>-<environment>-ask.')
@minLength(2)
@maxLength(32)
param appName string

@description('The relay image, pinned by digest: registry/repository@sha256:<digest>, pullable without credentials.')
param image string

@description('The public client ID of the GitHub OAuth App viewers sign in with (device flow, no client secret).')
param githubClientId string

@description('The origins the relay serves, comma-separated: the Insights app\'s hosting origin. Empty until the app is deployed.')
param allowedOrigins string = ''

@description('vCPU per replica.')
param cpu string = '1.0'

@description('Memory per replica, matching cpu (1.0 vCPU: 2Gi).')
param memory string = '2Gi'

@description('At most this many replicas; one serves a demo.')
@minValue(1)
@maxValue(3)
param maxReplicas int = 1

@description('Tags for both resources: the demo\'s own tags, plus component ask-relay.')
param tags object

resource environment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
  }
}

resource relay 'Microsoft.App/containerApps@2025-07-01' = {
  name: appName
  location: location
  tags: tags
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'relay'
          image: image
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: [
            {
              name: 'ALLOWED_ORIGINS'
              value: allowedOrigins
            }
            {
              name: 'GITHUB_CLIENT_ID'
              value: githubClientId
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http'
            http: {
              metadata: {
                concurrentRequests: '40'
              }
            }
          }
        ]
      }
    }
  }
}

@description('The relay\'s address, for the app\'s dbhub-app.json.')
output endpoint string = 'https://${relay.properties.configuration.ingress.fqdn}'
