-- T2 arcsql01: creates ContosoCare in the guest's default data folder. Run it in master.
-- Caps respect the 64 GB guest VHDX, which also holds Windows, SQL Server, and the setup media.

IF DB_ID(N'ContosoCare') IS NULL
BEGIN
    CREATE DATABASE ContosoCare;
END;
GO
