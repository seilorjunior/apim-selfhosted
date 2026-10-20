param apimName string
param gatewayName string
param backendUrl string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource gateway 'Microsoft.ApiManagement/service/gateways@2024-05-01' = {
  parent: apim
  name: gatewayName
  properties: {
    description: 'Self-hosted gateway on Azure Container Apps'
    locationData: { name: 'Azure Container Apps' }
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'sample-api'
  properties: {
    displayName: 'Sample API'
    path: 'sample'
    protocols: ['https']
    serviceUrl: backendUrl
    subscriptionRequired: false
    format: 'openapi+json'
    value: loadTextContent('../../api/sample.openapi.json')
  }
}

resource policy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../api/policies/sample.xml')
  }
}

resource assignment 'Microsoft.ApiManagement/service/gateways/apis@2024-05-01' = {
  parent: gateway
  name: api.name
  properties: {}
  dependsOn: [policy]
}

resource readinessApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'gateway-readiness'
  properties: {
    displayName: 'Gateway configuration readiness'
    path: 'gateway-health'
    protocols: ['http', 'https']
    subscriptionRequired: false
  }
}

resource readinessOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: readinessApi
  name: 'ready'
  properties: {
    displayName: 'Configuration loaded'
    method: 'GET'
    urlTemplate: '/ready'
  }
}

resource readinessPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: readinessApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../api/policies/readiness.xml')
  }
  dependsOn: [readinessOperation]
}

resource readinessAssignment 'Microsoft.ApiManagement/service/gateways/apis@2024-05-01' = {
  parent: gateway
  name: readinessApi.name
  properties: {}
  dependsOn: [readinessPolicy]
}

output gatewayId string = gateway.id
