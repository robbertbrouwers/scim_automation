-- Run as:  ACCOUNTADMIN or SECURITYADMIN
-- Purpose: Grant the automation role the minimum privileges needed to:
--            1. Rotate the PAT on scim_idp_user
--            2. Replace the network rule with updated IP ranges
--
-- Prerequisites: Run 05_create_automation_user.sql first.
--
-- Placeholders:
--   <DB>               database containing the network rule (matches script 02)
--   <SCHEMA>           schema containing the network rule  (matches script 02)

-- 1. PAT rotation
GRANT MODIFY PROGRAMMATIC AUTHENTICATION METHODS ON USER scim_idp_user
    TO ROLE scim_automation_role;

-- 2. Network rule replacement (CREATE OR REPLACE requires CREATE privilege on the schema)
GRANT CREATE NETWORK RULE ON SCHEMA SCIMMY.PUBLIC
    TO ROLE scim_automation_role;

-- 3. Network policy ownership so the automation role can reference the rule
--    (only needed if the policy was created by a different role/user)
--    Remove the COPY CURRENT GRANTS clause if you do not want to preserve
--    existing grants on the policy object.
GRANT OWNERSHIP ON NETWORK POLICY entra_scim_network_policy
    TO ROLE scim_automation_role
    COPY CURRENT GRANTS;

-- Verify
SHOW GRANTS TO ROLE scim_automation_role;
