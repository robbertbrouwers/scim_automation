# Snowflake SCIM PAT Rotation

Automated monthly rotation of the Snowflake SCIM token used by Microsoft Entra to provision users and groups, with continuous synchronisation of Entra's provisioning IP ranges into Snowflake's network allowlist.

## How it works

An Azure Function runs on the 1st of every month and:

1. Fetches the latest Entra provisioning IP ranges from Microsoft's Service Tags feed
2. Updates the Snowflake network rule with those ranges
3. Rotates the SCIM Personal Access Token on the Snowflake service user
4. Writes the new token into Entra via Microsoft Graph API
5. Validates that Entra can reach Snowflake with the new credentials

## Documentation

| Document | Description |
| -------- | ----------- |
| [Solution Design](docs/SOLUTION_DESIGN.md) | Architecture overview, component diagrams, Snowflake object/role/permission model |
| [Developer Guide](docs/DEVELOPER_GUIDE.md) | Prerequisites, access rights, one-time setup, deployment, and troubleshooting |

## Tech stack

- **Azure Functions** (Python 3.11, Consumption plan) — orchestration
- **Azure Key Vault** — secret storage (Snowflake credentials, Entra app ID)
- **Snowflake** — target system; PAT rotation via `ALTER USER … ROTATE PROGRAMMATIC ACCESS TOKEN`
- **Microsoft Graph API** — updates the SCIM secret token in the Entra enterprise application
- **Bicep** — infrastructure as code
- **GitHub Actions** — CI/CD with OIDC authentication (no stored Azure credentials)

## Repository layout

```
├── function_app.py          # Azure Function entry point
├── modules/                 # keyvault, ip_ranges, snowflake_ops, entra_ops
├── sql/                     # Snowflake setup scripts (run once, in order)
├── infra/                   # Bicep templates
├── .github/workflows/       # deploy-infra.yml, deploy-function.yml
└── docs/                    # Solution design and developer guide
```

## Status

Alerts are sent to the configured email address if the monthly rotation fails. Check [Application Insights](https://portal.azure.com) (`scim-pat-ai`) for logs and traces.
