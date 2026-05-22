-- Run as:  ACCOUNTADMIN or SECURITYADMIN
-- Purpose: Create the SCIM service user, a dedicated role, and grant the role
--          access to the Entra SCIM security integration.
--
-- The SCIM integration uses Snowflake's built-in AAD_PROVISIONER role.
-- scim_role is the role that scim_idp_user assumes for provisioning operations.

CREATE USER IF NOT EXISTS scim_idp_user
    TYPE    = SERVICE
    COMMENT = 'Service user for Entra SCIM provisioning';

CREATE ROLE IF NOT EXISTS scim_role;

GRANT ROLE scim_role TO USER scim_idp_user;

ALTER USER scim_idp_user SET DEFAULT_ROLE = scim_role;

-- scim_role needs USAGE on the integration so the PAT (restricted to scim_role)
-- can authenticate against the SCIM endpoint.
GRANT USAGE ON INTEGRATION entra_provisioning TO ROLE scim_role;

-- Verify
SHOW USERS LIKE 'SCIM_IDP_USER';
SHOW GRANTS TO ROLE scim_role;
