@{
    # Desired state for T1 sqlvm01 (ADR 0003). Invoke-SqlVmBootstrap.ps1 converges to it.

    # The data disk at LUN 0 holds ContosoCare's data and log files. SQL VM automated storage configuration
    # isn't used (Premium SSD only), so every profile gets the same layout. Without a data disk (dataDiskSku
    # None, the lowest-cost default), ContosoCare uses SQL Server's default folders on the OS disk instead.
    DataDisk = @{
        Lun                = 0
        DriveLetter        = 'F'
        Label              = 'DbHubSqlData'
        AllocationUnitSize = 65536
        DataFolder         = 'SQLData'
        LogFolder          = 'SQLLog'
    }

    Sql      = @{
        InstanceName   = 'MSSQLSERVER'
        ServiceName    = 'MSSQLSERVER'
        AgentService   = 'SQLSERVERAGENT'
        ServiceAccount = 'NT SERVICE\MSSQLSERVER'
        # Granted sysadmin only when the image's least-privilege setup leaves SYSTEM without it.
        AdminLogin     = 'BUILTIN\Administrators'
    }

    Database = @{
        Name = 'ContosoCare'
    }

    # Features the SQL Server 2022 Standard Marketplace image installs next to the engine that the demo doesn't use
    # (owner decision 2026-10-21: the lightest default). The AssociatedServices step stops and disables their
    # services, then, with Uninstall, removes the features with the image's own setup media: unified inventory keeps
    # listing installed features as SQL Server instance resources even when their services are stopped. A failed
    # uninstall is only a warning; the services stay stopped and disabled.
    AssociatedServices = @{
        # Analysis Services (default instance), Integration Services 2022, and their CEIP telemetry services.
        ServiceNames   = @('MSSQLServerOLAPService', 'MsDtsServer160', 'SSASTELEMETRY', 'SSISTELEMETRY160')
        Uninstall      = $true
        Features       = 'AS,IS'
        InstanceName   = 'MSSQLSERVER'
        SetupPath      = 'C:\SQLServerFull\setup.exe'
        SummaryPath    = 'C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log\Summary.txt'
        TimeoutMinutes = 30
        # Unified inventory drops the features' instance resources only after the SQL IaaS Agent discovers the
        # instances again: live, they went about 6 minutes after the agent service restarted (2026-10-21) and were
        # still listed 46 minutes after an uninstall without a restart (2026-10-22, deploy.ps1's parallel path, which
        # has no second template deployment to restart the agent). The step restarts it once the features are gone
        # and records that in the state folder.
        AgentServiceName = 'SQLIaaSExtension'
        InventoryMarker  = 'associated-services.json'
    }
}
