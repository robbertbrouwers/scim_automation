import logging
import os

import azure.functions as func
from azure.identity import ManagedIdentityCredential

from modules.entra_ops import update_scim_token, verify_provisioning
from modules.ip_ranges import get_entra_provisioning_ips
from modules.keyvault import get_secrets
from modules.snowflake_ops import connect, rotate_pat, update_network_rule

app = func.FunctionApp()

_SECRET_NAMES = [
    "snowflake-account",
    "snowflake-automation-user",
    "snowflake-automation-private-key",
    "entra-scim-app-object-id",
]


@app.timer_trigger(
    schedule="0 0 2 1 * *",  # 02:00 UTC on the 1st of every month
    arg_name="timer",
    run_on_startup=False,
    use_monitor=True,
)
def rotate_scim_pat(timer: func.TimerRequest) -> None:
    if timer.past_due:
        logging.warning("Timer is past due — running rotation anyway")

    logging.info("Starting Snowflake SCIM PAT rotation")

    credential = ManagedIdentityCredential()
    kv_url = os.environ["KEY_VAULT_URL"]
    secrets = get_secrets(kv_url, _SECRET_NAMES, credential)

    # Step 1: Fetch current Entra IP ranges from Microsoft
    logging.info("Fetching Entra IP ranges from Microsoft Service Tags")
    ip_ranges = get_entra_provisioning_ips()

    # Steps 2 & 3: Update network rule and rotate PAT in Snowflake
    logging.info("Connecting to Snowflake")
    conn = connect(
        secrets["snowflake-account"],
        secrets["snowflake-automation-user"],
        secrets["snowflake-automation-private-key"],
    )
    try:
        update_network_rule(conn, ip_ranges)
        new_pat_secret = rotate_pat(conn)
    finally:
        conn.close()

    # Step 4: Write the new token to the Entra enterprise application
    logging.info("Updating Entra SCIM secret token via Microsoft Graph")
    update_scim_token(secrets["entra-scim-app-object-id"], new_pat_secret, credential)

    # Step 5: Validate that Entra can reach Snowflake with the new token
    logging.info("Validating provisioning credentials")
    verify_provisioning(secrets["entra-scim-app-object-id"], credential)

    logging.info("PAT rotation completed successfully")
