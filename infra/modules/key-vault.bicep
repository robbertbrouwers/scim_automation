param prefix string
param location string

@description('Object ID of the identity (GitHub Actions SP or user) that runs deployments. Gets Key Vault Secrets Officer so it can write secrets post-deploy.')
param adminObjectId string

@allowed(['ServicePrincipal', 'User', 'Group'])
param adminPrincipalType string = 'ServicePrincipal'

var kvName = '${prefix}-kv1'

// Key Vault Secrets Officer — lets the deploying identity write secrets
var secretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource adminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, adminObjectId, secretsOfficerRoleId)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsOfficerRoleId)
    principalId: adminObjectId
    principalType: adminPrincipalType
  }
}

output keyVaultName string = kv.name
output keyVaultId string = kv.id
