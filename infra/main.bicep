targetScope = 'resourceGroup'

param baseName string = 'shgw'
param location string = resourceGroup().location
@allowed(['dev', 'prod'])
param environmentName string = 'dev'
@allowed(['Developer', 'Premium'])
param apimSku string = 'Developer'
param publisherEmail string = ''
param publisherName string = 'Contoso'
@description('Leave empty to create APIM. Existing APIM must use classic Developer or Premium.')
param existingApimName string = ''
param apimResourceGroup string = resourceGroup().name
param gatewayName string = 'aca-gateway'
param gatewayAppName string = 'ca-apim-gateway'
param backendAppName string = 'ca-backend'
param gatewayImageTag string = '2.9.2'
@description('Pinned sample backend; update deliberately after testing.')
param backendImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld@sha256:e9b3e7c34664c7cffd7144864b0e4eec369bfde80068f9095dc63b37058bec48'
@minValue(1)
param gatewayMinReplicas int = environmentName == 'prod' ? 2 : 1
@minValue(1)
param gatewayMaxReplicas int = 3
@minValue(1)
param gatewayConcurrentRequests int = 50
@allowed(['0.5', '1.0', '1.75'])
param gatewayCpu string = '1.0'
@allowed(['1Gi', '2Gi', '3.5Gi'])
param gatewayMemory string = '2Gi'
@description('Requires an appropriate existing infrastructure subnet and a supported region. Immutable after environment creation.')
param zoneRedundant bool = false
param infrastructureSubnetId string = ''
param tags object = {}

var suffix = uniqueString(resourceGroup().id)
var serviceName = empty(existingApimName) ? 'apim-${baseName}-${suffix}' : existingApimName
var resourceTags = union(tags, { environment: environmentName, project: 'apim-selfhosted' })

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = if (empty(existingApimName)) {
  name: serviceName
  location: location
  tags: resourceTags
  sku: {
    name: apimSku
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${baseName}-${suffix}'
  location: location
  tags: resourceTags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${baseName}-${suffix}'
  location: location
  tags: resourceTags
  properties: {
    zoneRedundant: zoneRedundant
    ...(empty(infrastructureSubnetId) ? {} : {
      vnetConfiguration: {
        infrastructureSubnetId: infrastructureSubnetId
        internal: false
      }
    })
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource backend 'Microsoft.App/containerApps@2024-03-01' = {
  name: backendAppName
  location: location
  tags: resourceTags
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'backend'
          image: backendImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 2
        rules: [
          {
            name: 'http'
            http: { metadata: { concurrentRequests: '50' } }
          }
        ]
      }
    }
  }
}

module api './modules/api.bicep' = {
  name: 'apim-api'
  scope: resourceGroup(apimResourceGroup)
  params: {
    apimName: serviceName
    gatewayName: gatewayName
    backendUrl: 'https://${backend.properties.configuration.ingress.fqdn}'
  }
  dependsOn: [apim]
}

output apimName string = serviceName
output gatewayName string = gatewayName
output gatewayId string = api.outputs.gatewayId
output environmentId string = env.id
output gatewaySettings object = {
  appName: gatewayAppName
  location: location
  imageTag: gatewayImageTag
  minReplicas: gatewayMinReplicas
  maxReplicas: gatewayMaxReplicas
  concurrentRequests: gatewayConcurrentRequests
  cpu: gatewayCpu
  memory: gatewayMemory
  tags: resourceTags
}
