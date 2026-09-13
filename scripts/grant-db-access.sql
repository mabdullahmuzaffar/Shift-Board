-- Grants the workload identities access to the ShiftBoard database.
--
-- WHY THIS SCRIPT EXISTS AND CANNOT BE TERRAFORM:
-- Azure SQL contained database users live INSIDE the database, not in the
-- Azure control plane. Terraform's azurerm provider manages the server and
-- the database, but it cannot create users inside them -- that needs a T-SQL
-- connection. So this runs once, manually or from the pipeline, after
-- `terraform apply`.
--
-- HOW TO RUN IT:
--   1. You must be signed in as a member of the Entra group that is the SQL
--      administrator (var.sql_admin_group_name).
--   2. The server has NO public endpoint, so you must run this from inside
--      the VNet -- a jumpbox, a self-hosted agent, or a temporary pod:
--
--      kubectl -n shiftboard run sqlcmd --rm -it --restart=Never \
--        --image=mcr.microsoft.com/mssql-tools18/sqlcmd:latest -- \
--        /opt/mssql-tools18/bin/sqlcmd -S <server>.database.windows.net \
--        -d shiftboard -G -C -i grant-db-access.sql
--
--      (-G = Entra auth, -C = trust the server certificate)
--
--   3. In dev you can instead temporarily allow your IP:
--      az sql server update -g <rg> -n <server> --enable-public-network true
--      az sql server firewall-rule create -g <rg> -s <server> \
--        -n mylaptop --start-ip-address <ip> --end-ip-address <ip>
--      ...then REVERT both when finished.
--
-- The user name must exactly match the managed identity NAME, not its client
-- id. Azure SQL resolves it against Entra by display name.

-- ---------------------------------------------------------------- shift-api
-- Reads and writes shifts, sites and workers. Does NOT need to write
-- conflicts -- only roster-worker does -- but shares the schema, so table
-- level grants keep the separation honest.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'id-shiftboard-dev-shift-api')
BEGIN
    CREATE USER [id-shiftboard-dev-shift-api] FROM EXTERNAL PROVIDER;
END
GO

ALTER ROLE db_datareader ADD MEMBER [id-shiftboard-dev-shift-api];
ALTER ROLE db_datawriter ADD MEMBER [id-shiftboard-dev-shift-api];
GO

-- Alembic needs DDL to run migrations. This is the one elevated grant in the
-- system. An alternative is a separate migration identity with ddl_admin and
-- a read/write-only identity for the API -- worth doing in prod, and noted
-- in docs/adr/0005-migration-privileges.md.
ALTER ROLE db_ddladmin ADD MEMBER [id-shiftboard-dev-shift-api];
GO

-- ------------------------------------------------------------ roster-worker
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'id-shiftboard-dev-roster-worker')
BEGIN
    CREATE USER [id-shiftboard-dev-roster-worker] FROM EXTERNAL PROVIDER;
END
GO

ALTER ROLE db_datareader ADD MEMBER [id-shiftboard-dev-roster-worker];
ALTER ROLE db_datawriter ADD MEMBER [id-shiftboard-dev-roster-worker];
GO

-- No DDL for the worker. It never migrates the schema, so it must not be
-- able to alter it.

-- ------------------------------------------------------------------- verify
SELECT
    dp.name              AS principal_name,
    dp.type_desc         AS principal_type,
    r.name               AS role_name
FROM sys.database_principals dp
LEFT JOIN sys.database_role_members drm ON drm.member_principal_id = dp.principal_id
LEFT JOIN sys.database_principals r     ON r.principal_id = drm.role_principal_id
WHERE dp.name LIKE 'id-shiftboard-%'
ORDER BY dp.name, r.name;
GO
