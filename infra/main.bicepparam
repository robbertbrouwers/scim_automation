using './main.bicep'

// ── Required — fill these in before deploying ───────────────────────────────

// Short prefix used in all resource names (2-12 chars, lowercase + hyphens).
// Example: 'scim-pat' produces scim-pat-kv, scim-pat-func, scimpatstg, etc.
param prefix = 'scim-pat'

// Azure region for all resources.
param location = 'westeurope'

// Object ID of the service principal that GitHub Actions authenticates as.
// Run: az ad sp show --id <client-id> --query id -o tsv
param keyVaultAdminObjectId = '27da36d7-b735-4ac9-ae1e-add9e553cd8e'

// 'ServicePrincipal' for a GitHub Actions SP; 'User' for a human deployer.
param keyVaultAdminPrincipalType = 'ServicePrincipal'

// Email address that receives failure alerts.
param alertEmailAddress = 'rbro@inspari.dk'

// ── Secrets are NOT stored here ─────────────────────────────────────────────
// After deployment the workflow runs `az keyvault secret set` for each of:
//   snowflake-account
//   snowflake-automation-user
//   snowflake-automation-private-key
//   entra-scim-app-object-id
// Values come from GitHub Actions secrets — see .github/workflows/deploy-infra.yml
