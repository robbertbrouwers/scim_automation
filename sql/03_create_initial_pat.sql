-- Run as:  a role with MODIFY PROGRAMMATIC AUTHENTICATION METHODS on scim_idp_user
-- Purpose: Generate the initial PAT for the Entra SCIM service user.
--
-- !! IMPORTANT !!
-- The token_secret in the result appears EXACTLY ONCE and cannot be retrieved
-- again. Copy it immediately and paste it into the Entra enterprise application:
--
--   Entra admin centre
--     → Enterprise applications → <your Snowflake app>
--     → Provisioning → Admin Credentials → Secret Token
--
-- Then click "Test Connection" and save.

ALTER USER IF EXISTS scim_idp_user
    ADD PROGRAMMATIC ACCESS TOKEN scim_entra_pat
    ROLE_RESTRICTION = 'SCIM_ROLE'
    DAYS_TO_EXPIRY   = 365
    COMMENT          = 'PAT for Entra SCIM provisioning — rotated automatically by Azure Function';

-- Confirm the token was created (token_secret is NOT shown here — only above)
SHOW USER PROGRAMMATIC ACCESS TOKENS FOR USER scim_idp_user;
