param prefix string
param location string
param appInsightsConnectionString string
param keyVaultName string

// Storage account name: strip hyphens, append 4-char hash for uniqueness, cap at 24 chars
var storageAccountName = take('${replace('${prefix}stg', '-', '')}${take(uniqueString(resourceGroup().id, prefix), 4)}', 24)

// Function app name: append 4-char hash for global DNS uniqueness
var functionAppName = '${prefix}-func-${take(uniqueString(resourceGroup().id, prefix), 4)}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${prefix}-plan'
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true  // required for Linux
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    siteConfig: {
      pythonVersion: '3.11'
      linuxFxVersion: 'Python|3.11'
      // Scale limit of 1: this is a monthly timer — no burst scaling needed
      functionAppScaleLimit: 1
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION',           value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',             value: 'python' }
        { name: 'AzureWebJobsStorage',                  value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        { name: 'KEY_VAULT_URL',                        value: 'https://${keyVaultName}${environment().suffixes.keyvaultDns}' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT',       value: 'false' }
        { name: 'ENABLE_ORYX_BUILD',                    value: 'false' }
      ]
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
          'https://ms.portal.azure.com'
        ]
        supportCredentials: false
      }
    }
  }
}

output functionAppName string = functionApp.name
output functionAppId string = functionApp.id
output managedIdentityPrincipalId string = functionApp.identity.principalId
