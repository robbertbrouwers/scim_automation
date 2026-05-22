import logging

import snowflake.connector
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    load_pem_private_key,
)


def connect(account: str, user: str, private_key_pem: str) -> snowflake.connector.SnowflakeConnection:
    private_key = load_pem_private_key(private_key_pem.encode(), password=None)
    private_key_der = private_key.private_bytes(Encoding.DER, PrivateFormat.PKCS8, NoEncryption())
    return snowflake.connector.connect(
        account=account,
        user=user,
        private_key=private_key_der,
    )


def update_network_rule(conn: snowflake.connector.SnowflakeConnection, ip_ranges: list[str]) -> None:
    ip_list = ", ".join(f"'{ip}'" for ip in ip_ranges)
    # ALTER (not CREATE OR REPLACE) because the rule is attached to a network policy;
    # Snowflake blocks dropping a rule that is referenced by an active policy.
    conn.cursor().execute(
        f"""ALTER NETWORK RULE SCIMMY.PUBLIC.entra_scim_ip_rule
              SET VALUE_LIST = ({ip_list})"""
    )
    logging.info("Network rule updated with %d IP ranges", len(ip_ranges))


def rotate_pat(conn: snowflake.connector.SnowflakeConnection) -> str:
    """
    Rotates scim_entra_pat and returns the new token secret.
    The previous token remains valid for 1 hour so Entra can pick up the
    new credential without a provisioning gap.
    """
    cursor = conn.cursor()
    cursor.execute(
        """ALTER USER IF EXISTS scim_idp_user
             ROTATE PROGRAMMATIC ACCESS TOKEN SCIM_ENTRA_PAT
             EXPIRE_ROTATED_TOKEN_AFTER_HOURS = 1"""
    )
    row = cursor.fetchone()
    # Output columns: token_name, token_secret, rotated_token_name
    new_secret: str = row[1]
    old_token_name: str = row[2]
    logging.info("PAT rotated — old token '%s' expires in 1 hour", old_token_name)
    return new_secret
