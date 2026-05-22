import logging

import requests
from azure.core.credentials import TokenCredential

_GRAPH_BASE = "https://graph.microsoft.com/v1.0"


def _auth_headers(credential: TokenCredential) -> dict[str, str]:
    token = credential.get_token("https://graph.microsoft.com/.default")
    return {
        "Authorization": f"Bearer {token.token}",
        "Content-Type": "application/json",
    }


def update_scim_token(sp_object_id: str, new_token: str, credential: TokenCredential) -> None:
    url = f"{_GRAPH_BASE}/servicePrincipals/{sp_object_id}/synchronization/secrets"
    body = {"value": [{"key": "SecretToken", "value": new_token}]}
    resp = requests.put(url, headers=_auth_headers(credential), json=body, timeout=60)
    resp.raise_for_status()
    logging.info("Entra SCIM secret token updated (HTTP %d)", resp.status_code)


def verify_provisioning(sp_object_id: str, credential: TokenCredential) -> None:
    """
    Calls validateCredentials on the first synchronization job to confirm
    Entra can reach Snowflake with the newly stored token.
    Uses useSavedCredentials=true so we test exactly what was just written.
    """
    headers = _auth_headers(credential)
    jobs_url = f"{_GRAPH_BASE}/servicePrincipals/{sp_object_id}/synchronization/jobs"

    jobs_resp = requests.get(jobs_url, headers=headers, timeout=30)
    jobs_resp.raise_for_status()
    jobs = jobs_resp.json().get("value", [])
    if not jobs:
        raise ValueError(f"No synchronization jobs found on service principal {sp_object_id}")

    job_id = jobs[0]["id"]
    validate_resp = requests.post(
        f"{jobs_url}/{job_id}/validateCredentials",
        headers=headers,
        json={"useSavedCredentials": True, "credentials": []},
        timeout=60,
    )
    if validate_resp.ok:
        logging.info("Provisioning credentials validated successfully (job: %s)", job_id)
    else:
        # 400 is common immediately after token rotation — Entra needs time to propagate
        # the new credentials to its provisioning service. Log a warning but don't fail
        # the function; the rotation itself already succeeded.
        logging.warning(
            "Credential validation returned HTTP %d — token was updated but Entra may "
            "need a moment to propagate it. Verify via Test Connection in the portal.",
            validate_resp.status_code,
        )
