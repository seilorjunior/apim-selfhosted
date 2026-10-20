targetScope = 'resourceGroup'

param environmentId string
param appName string = 'ca-apim-gateway'
param location string = resourceGroup().location
param configurationEndpoint string
param expectedGatewayId string
@description('Explicit stable revision receiving traffic until the candidate passes verification.')
param previousRevision string = ''
@description('Complete gateway authorization value, including the GatewayKey prefix.')
@secure()
@minLength(1)
param gatewayToken string
@description('A new, nonsecret suffix forces token changes into a new revision.')
@minLength(1)
@maxLength(30)
param revisionSuffix string
param imageTag string = '2.9.2'
@minValue(1)
param minReplicas int = 1
@minValue(1)
param maxReplicas int = 3
@minValue(1)
param concurrentRequests int = 50
@allowed(['0.5', '1.0', '1.75'])
param cpu string = '1.0'
@allowed(['1Gi', '2Gi', '3.5Gi'])
param memory string = '2Gi'
param tags object = {}

resource gateway 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: union(tags, empty(previousRevision) ? {} : { shgwPreviousRevision: previousRevision })
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Multiple'
      secrets: [
        { name: 'gateway-token', value: gatewayToken }
      ]
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        traffic: empty(previousRevision) ? [
          { revisionName: '${appName}--${revisionSuffix}', weight: 100 }
        ] : [
          { revisionName: previousRevision, weight: 100 }
          { revisionName: '${appName}--${revisionSuffix}', weight: 0 }
        ]
      }
    }
    template: {
      revisionSuffix: revisionSuffix
      containers: [
        {
          name: 'gateway'
          image: 'mcr.microsoft.com/azure-api-management/gateway:${imageTag}'
          resources: { cpu: json(cpu), memory: memory }
          env: [
            { name: 'config.service.endpoint', value: configurationEndpoint }
            { name: 'config.service.auth', secretRef: 'gateway-token' }
            { name: 'net.server.http.forwarded.proto.enabled', value: 'true' }
          ]
          probes: [
            {
              type: 'Startup'
              httpGet: { path: '/status-0123456789abcdef', port: 8080 }
              periodSeconds: 5
              timeoutSeconds: 3
              failureThreshold: 60
            }
            {
              type: 'Readiness'
              httpGet: { path: '/ready', port: 18081 }
              periodSeconds: 5
              timeoutSeconds: 3
              failureThreshold: 3
            }
            {
              type: 'Liveness'
              httpGet: { path: '/status-0123456789abcdef', port: 8080 }
              periodSeconds: 15
              timeoutSeconds: 3
              failureThreshold: 3
            }
          ]
        }
        {
          name: 'readiness'
          image: 'python:3.12-alpine@sha256:1b668429b3511ab407d8e00648891631b0b1a4d7e15e3ca70f38ab5b91ad4ab4'
          command: ['python', '-u', '-c', loadTextContent('../gateway/readiness.py')]
          env: [
            { name: 'EXPECTED_GATEWAY_ID', value: expectedGatewayId }
          ]
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          probes: [
            {
              type: 'Liveness'
              tcpSocket: { port: 18081 }
              initialDelaySeconds: 5
              periodSeconds: 15
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http'
            http: { metadata: { concurrentRequests: string(concurrentRequests) } }
          }
        ]
      }
    }
  }
}

output gatewayFqdn string = gateway.properties.configuration.ingress.fqdn
output revisionName string = '${appName}--${revisionSuffix}'
