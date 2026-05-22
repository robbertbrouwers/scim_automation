# Developer Guide: Snowflake SCIM PAT Rotation

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Prerequisites and Access Rights](#2-prerequisites-and-access-rights)
3. [One-Time Setup](#3-one-time-setup)
4. [Local Development](#4-local-development)
5. [Deploying to Azure](#5-deploying-to-azure)
6. [Snowflake Setup](#6-snowflake-setup)
7. [Connecting Entra to Snowflake](#7-connecting-entra-to-snowflake)
8. [Verifying the System](#8-verifying-the-system)
9. [Routine Operations](#9-routine-operations)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. System Overview

This project is an Azure Function (Python 3.11, timer trigger) that:
- Runs on the 1st of every month at 02:00 UTC
- Rotates the Snowflake SCIM PAT used by Microsoft Entra to provision users/groups
- Updates the Snowflake network allowlist with current Entra provisioning IP ranges
- Writes the new PAT into Entra via Microsoft Graph API

See [SOLUTION_DESIGN.md](SOLUTION_DESIGN.md) for the full architecture.

---

## 2. Prerequisites and Access Rights

### 2.1 Azure

| What | Why |
|------|-----|
| Contributor on the target Resource Group | Required to deploy Bicep (creates Function App, Key Vault, etc.) |
| User Access Administrator on the Resource Group | Required to assign RBAC roles during Bicep deployment (Key Vault role assignments) |
| Key Vault Secrets Officer on `scim-pat-kv1` | Required to inject secrets post-deployment |
| Azure AD Application Administrator (or the ability to create App Registrations) | Required for OIDC setup — create the GitHub Actions service principal and its federated credential |

> If your account has Owner on the resource group, all of the above are covered.

### 2.2 Snowflake

| What | Why |
|------|-----|
| `ACCOUNTADMIN` role | Required to run all six SQL setup scripts (create security integration, roles, users, network policy, PAT) |

All scripts in `sql/` have a comment at the top indicating the minimum required role. All currently require `ACCOUNTADMIN`.

### 2.3 Microsoft Entra / Graph API

| What | Why |
|------|-----|
| Entra Global Administrator or Application Administrator | Required to configure the Snowflake Enterprise Application for SCIM provisioning |
| Entra Global Administrator or Privileged Role Administrator | Required to grant the Function App's Managed Identity the `Synchronization Data` API permission on the Graph API (see [§3.3](#33-grant-managed-identity-graph-api-permissions)) |

### 2.4 GitHub

| What | Why |
|------|-----|
| Repository write access | Required to push code and trigger workflows |
| Repository Secrets write access (Settings → Secrets → Actions) | Required to store the nine secrets the workflows consume |

### 2.5 Local Development Tools

| Tool | Min Version | Install |
|------|-------------|---------|
| Python | 3.11 | [python.org](https://www.python.org) |
| Azure Functions Core Tools | v4 | `npm install -g azure-functions-core-tools@4` |
| Azure CLI | latest | [Microsoft docs](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| Docker Desktop | any | [docker.com](https://www.docker.com) — needed for linux dependency build only |
| Snowflake client (SnowSQL or worksheet) | any | For running the SQL setup scripts |

---

## 3. One-Time Setup

This section covers the setup steps that are done once per environment.

### 3.1 Create the GitHub Actions Service Principal

This SP is used by GitHub Actions to authenticate to Azure via OIDC.

```bash
# Create the app registration
az ad app create --display-name "scim-pat-github-actions"

# Note the appId from the output, then create a service principal for it
az ad sp create --id <appId>

# Note the SP's object ID (used in main.bicepparam)
az ad sp show --id <appId> --query id -o tsv
```

Assign roles on the resource group:


```bash
RG="<your-resource-group>"
SP_APP_ID="<appId>"
SUB_ID="<SubscriptionId>"

az role assignment create \
  --role "Contributor" \
  --assignee $SP_APP_ID \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG"

az role assignment create \
  --role "User Access Administrator" \
  --assignee $SP_APP_ID \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$RG"

 # if an error is thrown about missing sub or tenant info. This is due to path conversion on windows machines. prefix your az statement with MSYS_NO_PATHCONV=1 (ie: MSYS_NO_PATHCONV=1 az role assignment.....)
 
```

### 3.2 Create the OIDC Federated Credential

```bash
az ad app federated-credential create \
  --id <appId> \
  --parameters '{
    "name": "github-actions-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:<github-org>/<repo-name>:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

> The `subject` must exactly match your repository path and branch name.

### 3.3 Grant Managed Identity Graph API Permissions

The Function App's Managed Identity needs permission to call the Graph API
(`/servicePrincipals/{id}/synchronization/secrets`). The required app role is
`Synchronization.ReadWrite.All` — this must be granted by an admin because it is
an application permission, not a delegated one.

After the Function App is deployed (so its Managed Identity exists), run:

```powershell
# Connect to Graph
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All"

# IDs you need
$tenantId     = "<your-tenant-id>"
$miObjectId   = "<managed-identity-object-id>"   # output from Bicep: managedIdentityPrincipalId
$graphAppId   = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph, always this value

# Find the Graph service principal in your tenant
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"

# Find the app role
$appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq "Synchronization.ReadWrite.All" }

# Assign it to the Managed Identity
New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $miObjectId `
  -PrincipalId        $miObjectId `
  -ResourceId         $graphSp.Id `
  -AppRoleId          $appRole.Id
```

Alternatively, use the Azure Portal: **Entra** → **Enterprise Applications** → find the Function App
managed identity → **Permissions** → **Grant admin consent**.

### 3.4 Generate the Automation User RSA Key Pair

The `scim_automation_user` in Snowflake authenticates using an RSA key pair.
The private key is stored in Key Vault; the public key is stored on the Snowflake user.

```bash
# Generate a 2048-bit RSA key (no passphrase — Key Vault is the security boundary)
openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out snowflake_automation_private_key.pem

# Extract the public key
openssl rsa -in snowflake_automation_private_key.pem -pubout -out snowflake_automation_public_key.pem
```

Keep both files locally until:
1. The public key value (without headers) is pasted into `sql/05_create_automation_user.sql`
2. The private key file is stored in GitHub Actions secrets as `SNOWFLAKE_AUTOMATION_PRIVATE_KEY`

Delete both local files afterwards.

---

## 4. Local Development

### 4.1 Install Dependencies

```bash
cd c:\Users\rbro\SCIM_AUTOMATION

python -m venv .venv
.venv\Scripts\activate          # Windows
# source .venv/bin/activate     # macOS/Linux

pip install -r requirements.txt
```

### 4.2 Configure Local Settings

Copy the example settings file and fill in values:

```bash
cp local.settings.json.example local.settings.json
```

`local.settings.json` contents:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "KEY_VAULT_URL": "https://scim-pat-kv1.vault.azure.net"
  }
}
```

> `local.settings.json` is gitignored. Never commit it.

For the function to reach Key Vault locally, authenticate the Azure CLI with an account that has **Key Vault Secrets User** on the vault:

```bash
az login
az account set --subscription <subscriptionId>
```

`DefaultAzureCredential` (used by the SDK locally) will pick up your CLI session automatically.

### 4.3 Run Locally

```bash
func start
```

To trigger the function manually without waiting for the timer:

```bash
# POST to the admin endpoint
curl -X POST http://localhost:7071/admin/functions/rotate_scim_pat \
  -H "Content-Type: application/json" \
  -d "{}"
```

---

## 5. Deploying to Azure

### 5.1 Set GitHub Actions Secrets

Go to **GitHub → Repository → Settings → Secrets and variables → Actions** and add:

| Secret Name | Value |
|-------------|-------|
| `AZURE_CLIENT_ID` | App ID of the GitHub Actions service principal (from §3.1) |
| `AZURE_TENANT_ID` | Your Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target Azure subscription ID |
| `AZURE_RESOURCE_GROUP` | Target resource group name |
| `AZURE_FUNCTION_APP_NAME` | `scim-pat-func` (or whatever `prefix` is set to in `main.bicepparam`) |
| `SNOWFLAKE_ACCOUNT` | Snowflake account identifier (e.g. `abc12345.west-europe.azure`) |
| `SNOWFLAKE_AUTOMATION_USER` | `scim_automation_user` |
| `SNOWFLAKE_AUTOMATION_PRIVATE_KEY` | Full PEM content of the private key (including headers) |
| `ENTRA_SCIM_APP_OBJECT_ID` | Object ID of the Snowflake Enterprise Application in Entra |

### 5.2 Configure Bicep Parameters

Edit `infra/main.bicepparam` before the first deployment:

```bicep
param prefix                  = 'scim-pat'          // prefix for all resource names
param location                = 'westeurope'
param keyVaultAdminObjectId   = '<sp-object-id>'    // from §3.1
param keyVaultAdminPrincipalType = 'ServicePrincipal'
param alertEmailAddress       = '<your-email>'
```

### 5.3 Deploy Infrastructure

Push a change to `infra/**` or trigger manually:

```
GitHub → Actions → Deploy Infrastructure → Run workflow
```

The workflow:
1. Runs `az deployment group create` with the Bicep template
2. Captures Key Vault name and Function App name from outputs
3. Injects all four Snowflake/Entra secrets into Key Vault

### 5.4 Deploy Function Code

Push a change to `function_app.py`, `modules/`, `requirements.txt`, or `host.json`, or trigger manually:

```
GitHub → Actions → Deploy Function → Run workflow
```

The workflow:
1. Installs Python dependencies in a Docker container (linux/amd64, matching Azure's runtime)
2. Deploys the package to the Function App via the Azure Functions Action

> The function deployment workflow waits for the infra workflow to succeed if both are triggered together.

### 5.5 Grant Managed Identity Graph API Permissions

After the first infrastructure deployment, run the PowerShell from [§3.3](#33-grant-managed-identity-graph-api-permissions) using the `managedIdentityPrincipalId` output from the Bicep deployment:

```bash
az deployment group show \
  --resource-group <rg> \
  --name main \
  --query properties.outputs.managedIdentityPrincipalId.value \
  -o tsv
```

---

## 6. Snowflake Setup

Run the six SQL scripts in order. All require `ACCOUNTADMIN`. Use a Snowflake worksheet or SnowSQL.

| Script | Purpose | Notes |
|--------|---------|-------|
| `sql/00_create_scim_integration.sql` | Creates `aad_provisioner` role and `entra_provisioning` SCIM integration | Run before script 01 |
| `sql/01_create_scim_user_role.sql` | Creates `scim_idp_user` (SERVICE) and `scim_role` | — |
| `sql/02_create_network_policy.sql` | Creates `SCIMMY` database, network rule, and network policy; attaches policy to `scim_idp_user` | Run before completing script 00 step 3 |
| `sql/03_create_initial_pat.sql` | Creates the initial `SCIM_ENTRA_PAT`; output is shown **once only** | Copy the token immediately — it is used in §7 |
| `sql/04_grant_automation_privileges.sql` | Grants `scim_automation_role` minimum privileges | Run after script 05 |
| `sql/05_create_automation_user.sql` | Creates `scim_automation_user` with RSA public key | Paste public key from §3.4 first |

**Script 05 placeholder — paste your public key:**

Open `sql/05_create_automation_user.sql` and replace `<RSA_PUBLIC_KEY>` with the content of `snowflake_automation_public_key.pem` — strip the `-----BEGIN PUBLIC KEY-----` and `-----END PUBLIC KEY-----` header/footer lines and join into a single string.

---

## 7. Connecting Entra to Snowflake

1. In the Azure Portal go to **Entra** → **Enterprise Applications** → find or create the Snowflake application
2. Go to **Provisioning** → **Admin Credentials**
3. Set **Tenant URL** to the SCIM endpoint from:
   ```sql
   DESC SECURITY INTEGRATION entra_provisioning;
   ```
   (the `SCIM_URL` property)
4. Set **Secret Token** to the initial PAT from script 03
5. Click **Test Connection** — it should succeed
6. Set **Provisioning Mode** to **Automatic** and start provisioning

The Function App will replace the secret token on the 1st of every month.

Note the **Object ID** of this Enterprise Application — it is the `ENTRA_SCIM_APP_OBJECT_ID` GitHub Actions secret.

---

## 8. Verifying the System

### Trigger a Manual Rotation

```bash
# Via Azure Portal:
# Function App → Functions → rotate_scim_pat → Code + Test → Test/Run

# Via CLI (requires Function host key):
curl -X POST "https://scim-pat-func.azurewebsites.net/admin/functions/rotate_scim_pat" \
  -H "x-functions-key: <host-key>" \
  -H "Content-Type: application/json" \
  -d "{}"
```

### Check Logs

```bash
# Stream live logs
func azure functionapp logstream scim-pat-func

# Or via Log Analytics (Application Insights):
# Azure Portal → Application Insights → scim-pat-ai → Logs
```

Expected log sequence on success:

```
Fetching secrets from Key Vault
Fetched N Entra IP ranges
Connected to Snowflake as scim_automation_user
Network rule updated with N IP ranges
PAT rotated. New token name: SCIM_ENTRA_PAT
Entra SCIM token updated
Credential validation passed (or: warning if 400 — normal within minutes of rotation)
```

### Verify in Entra

**Entra** → **Enterprise Applications** → **Snowflake app** → **Provisioning** → **Provisioning logs**

A successful provisioning cycle confirms end-to-end connectivity.

---

## 9. Routine Operations

### Adding a New Developer

1. Grant **Contributor + User Access Administrator** on the resource group (or Owner)
2. Grant **Key Vault Secrets Officer** on `scim-pat-kv1` (to read/write secrets locally)
3. Grant Snowflake `ACCOUNTADMIN` role (for any SQL changes)
4. Provide access to the GitHub repository

Local development uses the developer's personal Azure CLI session — no shared credentials.

### Rotating the Automation User's RSA Key

If the private key is compromised or needs rotation:

1. Generate a new key pair (§3.4)
2. Update the public key on the Snowflake user:
   ```sql
   USE ROLE ACCOUNTADMIN;
   ALTER USER scim_automation_user SET RSA_PUBLIC_KEY = '<new-public-key>';
   ```
3. Update the GitHub Actions secret `SNOWFLAKE_AUTOMATION_PRIVATE_KEY` with the new PEM
4. Re-run the infra workflow to push the new key into Key Vault
5. Delete the old key files

### Changing the Alert Email

Edit `infra/main.bicepparam`:

```bicep
param alertEmailAddress = 'new-email@example.com'
```

Then push to trigger the infra workflow.

### Changing the Rotation Schedule

Edit the cron expression in `function_app.py`:

```python
@app.schedule(schedule="0 0 2 1 * *", ...)
```

Format: `seconds minutes hours day-of-month month day-of-week`  
Current value: `0 0 2 1 * *` = 02:00 UTC on the 1st of every month.

---

## 10. Troubleshooting

### Function fails: `KeyVaultError` / secret not found

- Confirm the secret exists: `az keyvault secret list --vault-name scim-pat-kv1`
- Confirm the Managed Identity has **Key Vault Secrets User** on the vault
- Check the `KEY_VAULT_URL` app setting on the Function App matches the vault URL

### Function fails: Snowflake authentication error

- Confirm `scim_automation_user` exists in Snowflake with the correct RSA public key
- Confirm the private key in Key Vault is the matching PEM (including full headers)
- Confirm `snowflake-account` secret uses the correct Snowflake account identifier format

### Function fails: Graph API 403 Forbidden

- The Managed Identity is missing the `Synchronization.ReadWrite.All` app role
- Re-run the PowerShell from §3.3
- Allow up to 5 minutes for the permission grant to propagate

### Function warns: credential validation returned 400

This is expected within a few minutes of token rotation. Entra needs time to internally propagate the new token before `validateCredentials` succeeds. The rotation itself already completed. Check again after 5–10 minutes via the Entra provisioning logs.

### Network rule update fails: `SQL compilation error`

If you see an error about `CREATE OR REPLACE` on a rule attached to a policy, the code is using `ALTER` (correct). If you see this error, check that `scim_automation_role` has `OWNERSHIP` on `entra_scim_network_policy` — run script 04 again if needed.

### Infra deployment fails: role assignment already exists

Bicep role assignments are idempotent. If a deployment fails with a conflict on role assignment, check whether a manual role assignment was added outside of Bicep. Remove the duplicate and re-run.

---

## Repository Structure

```
SCIM_AUTOMATION/
├── function_app.py              # Azure Function entry point (timer trigger)
├── host.json                    # Function timeout and logging config
├── requirements.txt             # Python dependencies
├── local.settings.json.example  # Template for local development
│
├── modules/
│   ├── keyvault.py              # Key Vault secret retrieval
│   ├── ip_ranges.py             # Fetches Entra IP ranges from Microsoft Service Tags
│   ├── snowflake_ops.py         # Snowflake connection, PAT rotation, network rule update
│   └── entra_ops.py             # Microsoft Graph API calls (update + validate token)
│
├── sql/
│   ├── 00_create_scim_integration.sql   # aad_provisioner role + SCIM integration
│   ├── 01_create_scim_user_role.sql     # scim_idp_user + scim_role
│   ├── 02_create_network_policy.sql     # Network rule + policy
│   ├── 03_create_initial_pat.sql        # Initial SCIM_ENTRA_PAT (token shown once)
│   ├── 04_grant_automation_privileges.sql  # scim_automation_role grants
│   └── 05_create_automation_user.sql    # scim_automation_user with RSA key
│
├── infra/
│   ├── main.bicep               # Bicep orchestrator
│   ├── main.bicepparam          # Deployment parameters
│   └── modules/
│       ├── function-app.bicep   # Storage, App Service Plan, Function App
│       ├── key-vault.bicep      # Key Vault with RBAC
│       ├── monitoring.bicep     # Log Analytics, App Insights, alerts
│       └── kv-role-assignment.bicep  # RBAC: Managed Identity → Key Vault
│
├── .github/workflows/
│   ├── deploy-infra.yml         # Bicep deployment + secret injection
│   └── deploy-function.yml      # Function code deployment
│
└── docs/
    ├── SOLUTION_DESIGN.md       # Architecture and design
    └── DEVELOPER_GUIDE.md       # This file
```
