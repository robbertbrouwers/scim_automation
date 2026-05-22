-- Run as:  ACCOUNTADMIN or SECURITYADMIN
-- Purpose: Create a network rule seeded with the initial Entra provisioning IP
--          ranges, wrap it in a network policy, and apply the policy to the SCIM
--          service user only (not account-wide).
--
-- The automation function calls CREATE OR REPLACE NETWORK RULE on each rotation
-- cycle, so the rule contents stay current without touching the policy object.
--
-- Current IP ranges: download the Service Tags JSON from
--   https://www.microsoft.com/en-us/download/details.aspx?id=56519
-- and filter for the "AzureActiveDirectory" entry → addressPrefixes (IPv4 only).
--
-- Placeholders:
--   <DB>     database where the network rule lives (e.g. AUTOMATION_DB)
--   <SCHEMA> schema where the network rule lives  (e.g. PUBLIC)

USE DATABASE SCIMMY;
USE SCHEMA PUBLIC;

CREATE OR REPLACE NETWORK RULE entra_scim_ip_rule
    TYPE       = IPV4
    MODE       = INGRESS
    VALUE_LIST = (
        '20.190.128.0/18',
        '40.126.0.0/18'
        -- The automation function will keep this up to date after the first rotation.
    )
    COMMENT = 'Entra provisioning service IPs - updated by automation on each PAT rotation';

CREATE NETWORK POLICY IF NOT EXISTS entra_scim_network_policy
    ALLOWED_NETWORK_RULE_LIST = ('SCIMMY.PUBLIC.entra_scim_ip_rule')
    COMMENT                   = 'Applied to scim_idp_user only — not account-wide';

-- Apply policy to the service user only
ALTER USER scim_idp_user SET NETWORK_POLICY = entra_scim_network_policy;

-- Verify
SHOW NETWORK POLICIES LIKE 'ENTRA_SCIM_NETWORK_POLICY';
DESC USER scim_idp_user;
