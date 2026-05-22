# Solution Design: Snowflake SCIM PAT Rotation

## Overview

This system automates the monthly rotation of the Snowflake SCIM Personal Access Token (PAT) used by Microsoft Entra to provision users and groups into Snowflake. It also keeps the Snowflake network policy synchronized with Entra's current provisioning IP ranges.

Without automation, the token would expire and break user provisioning. Manual rotation requires Snowflake admin access, Entra admin access, and careful coordination — this system eliminates that entirely.

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  GitHub                                                                  │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  GitHub Actions (OIDC → Azure SP)                               │    │
│  │  deploy-infra.yml  ──→  Bicep deployment + Key Vault secrets    │    │
│  │  deploy-function.yml ──→  Function App code deployment          │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ OIDC federated credential (no long-lived secrets)
                             ↓
┌─────────────────────────────────────────────────────────────────────────┐
│  Azure (West Europe)                                                     │
│                                                                          │
│  ┌──────────────────┐    Managed Identity     ┌──────────────────────┐  │
│  │  Azure Function  │ ──────────────────────→ │  Azure Key Vault     │  │
│  │  (Python 3.11)   │                          │  snowflake-account   │  │
│  │                  │ ←────────────────────── │  automation-user     │  │
│  │  Timer: 02:00    │    Secrets (read-only)   │  private-key (PEM)   │  │
│  │  on 1st of month │                          │  entra-app-object-id │  │
│  └────────┬─────────┘                          └──────────────────────┘  │
│           │                                                               │
│           │           ┌──────────────────────────────────────────────┐  │
│           │           │  Monitoring                                   │  │
│           │           │  App Insights ──→ Log Analytics Workspace    │  │
│           │           │  Scheduled Alert ──→ Email (on failure)      │  │
│           └──────────→│  Consumption Plan + Storage Account          │  │
│                        └──────────────────────────────────────────────┘  │
└────────┬──────────────────────────────────────┬──────────────────────────┘
         │ RSA key-pair auth                    │ Managed Identity bearer token
         ↓                                      ↓
┌──────────────────────┐             ┌──────────────────────────────────────┐
│  Snowflake           │             │  Microsoft Entra / Graph API         │
│                      │             │                                      │
│  ALTER USER          │             │  PUT  /synchronization/secrets       │
│    ROTATE PAT        │             │    → writes new PAT as SecretToken   │
│                      │             │                                      │
│  ALTER NETWORK RULE  │             │  POST /synchronization/jobs/         │
│    SET VALUE_LIST    │             │    {jobId}/validateCredentials       │
│    (Entra IPs)       │             │    → confirms connectivity           │
└──────────────────────┘             └──────────────────────────────────────┘
                                                   │
                                        SCIM provisioning
                                        (users & groups)
                                                   ↓
                                     ┌──────────────────────┐
                                     │  Snowflake           │
                                     │  entra_provisioning  │
                                     │  security integration│
                                     └──────────────────────┘
```

### Execution Flow (monthly, 1st of month at 02:00 UTC)

1. Timer trigger fires the Azure Function
2. Function reads four secrets from Key Vault via Managed Identity
3. Function fetches current Entra provisioning IP ranges from Microsoft's Service Tags feed
4. Function connects to Snowflake using RSA key-pair authentication
5. Snowflake network rule is updated with the latest Entra CIDR ranges
6. Snowflake PAT (`SCIM_ENTRA_PAT`) is rotated — old token stays valid for 1 hour during propagation
7. New PAT is written to Entra via Microsoft Graph API
8. Entra validates connectivity with the new token (warning logged on 400; rotation already succeeded)

---

## Snowflake Assets

### Objects, Roles, and Permissions

In Snowflake, most security objects (roles, users, security integrations, network policies) are **account-level** — they have no database or schema container. Network rules are the exception: they are **schema-level objects** and must live inside a database and schema.

```
╔══════════════════════════════════════════════════════════════╗
║  ACCOUNT-LEVEL OBJECTS  (created by ACCOUNTADMIN)           ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  SECURITY INTEGRATION: entra_provisioning                    ║
║    TYPE        = SCIM                                        ║
║    SCIM_CLIENT = AZURE                                       ║
║    RUN_AS_ROLE = aad_provisioner                             ║
║    NETWORK_POLICY = entra_scim_network_policy                ║
║                                                              ║
║  NETWORK POLICY: entra_scim_network_policy                   ║
║    ALLOWED_NETWORK_RULE_LIST = [SCIMMY.PUBLIC.entra_scim_ip_rule]  ←─┐
║    (applied to scim_idp_user only — not account-wide)        ║       │
║                                                              ║       │ fully-qualified
║  ROLE: aad_provisioner                                       ║       │ reference
║    GRANT CREATE USER ON ACCOUNT                              ║       │
║    GRANT CREATE ROLE ON ACCOUNT                              ║       │
║                                                              ║       │
║  ROLE: scim_role                                             ║       │
║    GRANT USAGE ON INTEGRATION entra_provisioning             ║       │
║    GRANTED TO USER scim_idp_user                             ║       │
║                                                              ║       │
║  ROLE: scim_automation_role                                  ║       │
║    GRANT MODIFY PROGRAMMATIC AUTHENTICATION METHODS          ║       │
║      ON USER scim_idp_user                                   ║       │
║    GRANT CREATE NETWORK RULE ON SCHEMA SCIMMY.PUBLIC         ║       │
║    GRANT OWNERSHIP ON NETWORK POLICY entra_scim_network_policy║       │
║                                                              ║       │
║  USER: scim_idp_user  (TYPE = SERVICE)                       ║       │
║    DEFAULT_ROLE    = scim_role                               ║       │
║    NETWORK_POLICY  = entra_scim_network_policy               ║       │
║    PAT: SCIM_ENTRA_PAT                                       ║       │
║      EXPIRY_DAYS                    = 365                    ║       │
║      EXPIRE_ROTATED_TOKEN_AFTER_HOURS = 1                    ║       │
║                                                              ║       │
║  USER: scim_automation_user  (TYPE = SERVICE)                ║       │
║    DEFAULT_ROLE  = scim_automation_role                      ║       │
║    RSA_PUBLIC_KEY = <stored on user in Snowflake>            ║       │
║                    (private key in Azure Key Vault)          ║       │
║                                                              ║       │
╠══════════════════════════════════════════════════════════════╣       │
║  SCHEMA-LEVEL OBJECT  (network rules require a container)   ║       │
╠══════════════════════════════════════════════════════════════╣       │
║                                                              ║       │
║  DATABASE: SCIMMY                                            ║       │
║  └── SCHEMA: PUBLIC                                          ║       │
║      └── NETWORK RULE: entra_scim_ip_rule  ──────────────────╫───────┘
║            TYPE       = IPV4                                 ║
║            MODE       = INGRESS                              ║
║            VALUE_LIST = [Entra AzureActiveDirectory CIDRs]  ║
║                         (updated monthly by automation)      ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
```

### Permission Matrix

| Principal | Used by | Object | Permission | Purpose |
| --------- | ------- | ------ | ---------- | ------- |
| `aad_provisioner` | `entra_provisioning` integration (runs as this role) | ACCOUNT | CREATE USER | Allows the SCIM integration to create Snowflake users when Entra assigns them to the Snowflake app |
| `aad_provisioner` | `entra_provisioning` integration (runs as this role) | ACCOUNT | CREATE ROLE | Allows the SCIM integration to create Snowflake roles when Entra pushes groups |
| `scim_role` | `scim_idp_user` — the service account Entra authenticates as | `entra_provisioning` integration | USAGE | Allows `scim_idp_user` to present its PAT against the SCIM endpoint; without this the token is valid but the integration rejects it |
| `scim_automation_role` | `scim_automation_user` — the Azure Function's service account | USER `scim_idp_user` | MODIFY PROGRAMMATIC AUTHENTICATION METHODS | Allows the Azure Function to rotate the PAT on `scim_idp_user`; scoped to that one user so the automation account cannot touch any other user's credentials |
| `scim_automation_role` | `scim_automation_user` — the Azure Function's service account | SCHEMA `SCIMMY.PUBLIC` | CREATE NETWORK RULE | Allows the Azure Function to replace the IP allowlist rule each month; scoped to this schema only |
| `scim_automation_role` | `scim_automation_user` — the Azure Function's service account | NETWORK POLICY `entra_scim_network_policy` | OWNERSHIP | Required so the automation role can alter the policy that references the network rule; without this the network rule update succeeds but the policy cannot be updated to reference it |

### Network Security

The `entra_scim_network_policy` is applied to `scim_idp_user` only (not account-wide). It restricts inbound SCIM requests to Microsoft's published `AzureActiveDirectory` IPv4 CIDR ranges. The automation function updates these ranges monthly alongside the token rotation, keeping the allowlist current as Microsoft expands its provisioning infrastructure.

---

## Azure Infrastructure

| Resource | Name | Purpose |
|----------|------|---------|
| Resource Group | `scim-pat-rg` (pre-existing) | Container for all resources |
| Key Vault | `scim-pat-kv1` | Stores Snowflake + Entra credentials |
| Function App | `scim-pat-func` | Runs monthly PAT rotation logic |
| App Service Plan | `scim-pat-plan` | Consumption (serverless) hosting |
| Storage Account | `scimpatstg` | Required by Functions runtime |
| Log Analytics Workspace | `scim-pat-law` | Centralised log storage (30-day retention) |
| Application Insights | `scim-pat-ai` | Function telemetry and traces |
| Action Group | `scim-pat-alerts` | Email notification on failure |

### Key Vault RBAC

| Principal | Role | Permissions |
|-----------|------|-------------|
| GitHub Actions SP | Key Vault Secrets Officer | Read + write secrets (used during deployment to inject secrets) |
| Function App Managed Identity | Key Vault Secrets User | Read secrets only (runtime access) |

---

## CI/CD Pipeline

```
Push to main
     │
     ├─ infra/** changed?
     │    └──→ deploy-infra.yml
     │           ├── az deployment group create (Bicep)
     │           └── az keyvault secret set × 4 (from GitHub Actions secrets)
     │
     └─ function_app.py / modules/** / requirements.txt changed?
          └──→ deploy-function.yml
                 ├── Waits for deploy-infra.yml if chained
                 ├── pip install (in Docker, linux/amd64 for GLIBC compat)
                 └── Azure Functions Action (deploys zip package)
```

Authentication from GitHub Actions to Azure uses OIDC federated credentials — no client secrets are stored in GitHub.

---

## Security Design Principles

- **No long-lived secrets in code or environment variables** — all secrets are in Key Vault
- **Least-privilege RBAC** — automation role can only rotate one PAT and update one network rule
- **Keyless GitHub-to-Azure auth** — OIDC federated credentials, no stored client secrets
- **Network-scoped SCIM access** — Entra provisioning is restricted to known Microsoft IP ranges
- **Overlap window on rotation** — 1-hour token overlap prevents provisioning gaps during propagation
- **Managed Identity only** — Function authenticates to both Key Vault and Entra without any stored credentials
