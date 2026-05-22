// Infrastructure entry point — managed by GitHub Actions (deploy-infra.yml)
targetScope = 'resourceGroup'

@description('Short prefix for all resource names (2-12 chars, lowercase letters and hyphens only). Storage account names strip hyphens, so avoid long prefixes.')
@minLength(2)
@maxLength(12)
param prefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Object ID of the identity that runs deployments (GitHub Actions SP or a user for manual deploys). Receives Key Vault Secrets Officer so it can write secrets after deployment.')
param keyVaultAdminObjectId string

@allowed(['ServicePrincipal', 'User', 'Group'])
param keyVaultAdminPrincipalType string = 'ServicePrincipal'

@description('Email address for failure alert notifications.')
param alertEmailAddress string

// ── Monitoring (Log Analytics + App Insights + Action Group) ────────────────
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    prefix: prefix
    location: location
    alertEmailAddress: alertEmailAddress
  }
}

// ── Key Vault ───────────────────────────────────────────────────────────────
module keyVault 'modules/key-vault.bicep' = {
  name: 'key-vault'
  params: {
    prefix: prefix
    location: location
    adminObjectId: keyVaultAdminObjectId
    adminPrincipalType: keyVaultAdminPrincipalType
  }
}

// ── Function App (Storage + Consumption plan + Function App) ────────────────
module functionApp 'modules/function-app.bicep' = {
  name: 'function-app'
  params: {
    prefix: prefix
    location: location
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    keyVaultName: keyVault.outputs.keyVaultName
  }
}

// ── Grant function app's managed identity read access to Key Vault ──────────
module kvRoleAssignment 'modules/kv-role-assignment.bicep' = {
  name: 'kv-role-assignment'
  params: {
    keyVaultName: keyVault.outputs.keyVaultName
    principalId: functionApp.outputs.managedIdentityPrincipalId
  }
}

// ── Alert: function execution failures ──────────────────────────────────────
// Query-based alert avoids the metric-dimension bootstrap problem (platform
// metric dimensions only appear after the first execution).
resource failureAlert 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = {
  name: '${prefix}-scim-pat-failure'
  location: location
  properties: {
    description: 'SCIM PAT rotation function failed — investigate before the 1-hour overlap window closes'
    severity: 1
    enabled: true
    scopes: [monitoring.outputs.appInsightsId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'traces | where message contains "Executed \'Functions.rotate_scim_pat\' (Failed"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [monitoring.outputs.actionGroupId]
    }
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────
output keyVaultName string = keyVault.outputs.keyVaultName
output functionAppName string = functionApp.outputs.functionAppName
output managedIdentityPrincipalId string = functionApp.outputs.managedIdentityPrincipalId
