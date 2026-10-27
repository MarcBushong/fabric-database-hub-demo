-- T1 sqlvm01: creates ContosoCare with file growth caps. Run it in master.
-- The bootstrap replaces {{DATA_DIRECTORY}} and {{LOG_DIRECTORY}} before it runs this: folders on the data
-- disk (LUN 0) that the SQL Server service account can write, or SQL Server's default data and log folders
-- on the OS disk when there's no data disk (dataDiskSku None). Tokens appear only inside string literals.

IF DB_ID(N'ContosoCare') IS NULL
BEGIN
    CREATE DATABASE ContosoCare
    ON PRIMARY
    (
        NAME = N'ContosoCare',
        FILENAME = N'{{DATA_DIRECTORY}}\ContosoCare.mdf',
        SIZE = 512MB,
        MAXSIZE = 16384MB,
        FILEGROWTH = 256MB
    )
    LOG ON
    (
        NAME = N'ContosoCare_log',
        FILENAME = N'{{LOG_DIRECTORY}}\ContosoCare_log.ldf',
        SIZE = 256MB,
        MAXSIZE = 8192MB,
        FILEGROWTH = 256MB
    );
END;
GO
