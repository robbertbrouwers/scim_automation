-- Run as:  ACCOUNTADMIN or SECURITYADMIN
-- Purpose: Create the role and service user that the Azure Function connects as
--          to rotate the PAT and update the network rule.
--          Uses key-pair authentication (no password).
--
-- Prerequisites:
--   1. Generate an RSA-2048 key pair (already done — see instructions below).
--   2. Run this script to create the user with the public key.
--   3. Store the private key as GitHub secret SNOWFLAKE_AUTOMATION_PRIVATE_KEY.
--   4. Then run 04_grant_automation_privileges.sql.
--
-- ── How to find your generated keys ────────────────────────────────────────
-- Private key : C:\Users\rbro\scim_automation_private_key.pem
--               → Copy the full file contents into GitHub secret:
--                 SNOWFLAKE_AUTOMATION_PRIVATE_KEY
--               → Delete the file from your machine when done.
--
-- Public key  : paste the value below where it says <PASTE-PUBLIC-KEY-HERE>
--               (everything between BEGIN/END PUBLIC KEY lines, no line breaks)
--               Run this to print it:
--                 grep -v "BEGIN\|END" C:\Users\rbro\scim_automation_private_key.pem
--               (or open the .pem file, extract the public key using openssl:
--                 openssl pkey -in scim_automation_private_key.pem -pubout 2>nul)
-- ───────────────────────────────────────────────────────────────────────────

CREATE ROLE IF NOT EXISTS scim_automation_role;

CREATE USER IF NOT EXISTS scim_automation_user
    TYPE           = SERVICE
    RSA_PUBLIC_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlHWvUKP4jcdsXbBCKEq51kKEg8cp1Lu90IYej29hxQ2I4UU9lAEGSWXdJiY7gsU8Lv0eK7jSJNLmViWhLmi97OH3QZ/pCfyV7B8UhbKf8t/eF7QrTri3XQU19sidOffZ3UCgVvxdN7McQubJSl2fF9n3li+ZxynwxkJQKFCTpTUOkOgfj8ZzWjUXfBIut27VXr1Kseu0uDjopGsrUDr8b5V6EpqoQ3mdrIQvODDzzna2DxIzntcq8Aj2xA+S6n6a8wq3gUWmkXTp3VoY5y4mOfKGu7/OdZjyk07IJPeiDpV52SttQQEhp2knxHEvubdAFjEaKuojPebaBf6274kynQIDAQAB'
    DEFAULT_ROLE   = scim_automation_role
    COMMENT        = 'Service user for Azure Function SCIM PAT automation — key-pair auth only';

GRANT ROLE scim_automation_role TO USER scim_automation_user;

-- Verify
SHOW USERS LIKE 'SCIM_AUTOMATION_USER';
DESC USER scim_automation_user;
