-- Run as:  ACCOUNTADMIN
-- Purpose: Create the AAD_PROVISIONER role required by Snowflake Azure SCIM,
--          then create the SCIM security integration.
--          Run this FIRST — script 01 grants USAGE on this integration.
--
-- Note: AAD_PROVISIONER is NOT a built-in Snowflake role — you must create it.
--       It is the role the SCIM integration uses to create/update users and groups.

USE ROLE ACCOUNTADMIN;

-- Step 1: Create the role that runs all SCIM provisioning operations
CREATE ROLE IF NOT EXISTS aad_provisioner;

GRANT CREATE USER ON ACCOUNT TO ROLE aad_provisioner;
GRANT CREATE ROLE ON ACCOUNT TO ROLE aad_provisioner;
GRANT ROLE aad_provisioner TO ROLE accountadmin;

-- Step 2: Create the SCIM security integration
CREATE OR REPLACE SECURITY INTEGRATION entra_provisioning
    TYPE        = SCIM
    SCIM_CLIENT = 'AZURE'
    RUN_AS_ROLE = 'AAD_PROVISIONER';

-- Step 3: Attach the network policy to the integration (required for SCIM requests)
--          Run this after 02_create_network_policy.sql has been executed.
ALTER SECURITY INTEGRATION entra_provisioning
    SET NETWORK_POLICY = entra_scim_network_policy;

-- Step 4: Get the SCIM endpoint URL — paste this as "Tenant URL" in Entra:
--   Enterprise applications → <Snowflake app> → Provisioning → Admin Credentials
DESC SECURITY INTEGRATION entra_provisioning;
