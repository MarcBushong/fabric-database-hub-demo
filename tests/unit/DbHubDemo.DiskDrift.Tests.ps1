BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext

    function New-TestConfig([hashtable] $Override = @{}) {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        # Obviously fake IDs: every group repeats one character.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        foreach ($key in $Override.Keys) { $config[$key] = $Override[$key] }
        return $config
    }

    function New-StorageProfile([string] $Vm, [string] $OsType, [string] $CreateOption = 'FromImage', [object[]] $DataDisks = @()) {
        # A deallocated VM's model has no storageAccountType (live, 2026-10-26): pass an empty OsType for one.
        $managedDisk = if ($OsType) { @{ storageAccountType = $OsType } } else { @{ id = ('/subscriptions/x/resourceGroups/RG-DBHUB-DEMO/providers/Microsoft.Compute/disks/{0}-osdisk' -f $Vm) } }
        ConvertTo-Json -Depth 10 -InputObject @{
            osDisk    = @{ name = ('{0}-osdisk' -f $Vm); createOption = $CreateOption; managedDisk = $managedDisk }
            dataDisks = @($DataDisks)
        }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoVmDiskDrift' {
    BeforeEach {
        $script:profiles = @{}
        $script:disks = @{}
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $name = $ArgumentList[[array]::IndexOf($ArgumentList, '--name') + 1]
            $store = if ($ArgumentList[0] -eq 'disk') { $script:disks } else { $script:profiles }
            if (-not $store.ContainsKey($name)) {
                return [pscustomobject]@{ ExitCode = 3; StdOut = ''; StdErr = '(ResourceNotFound) not found' }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = $store[$name]; StdErr = '' }
        }
    }

    It 'reads the disk itself when the VM is deallocated, because its model then has no storage type' {
        # Live, 2026-10-26: STATUS.DISKS passed for two Standard HDD OS disks while both VMs were deallocated.
        $script:profiles['sqlvm01'] = New-StorageProfile -Vm 'sqlvm01' -OsType ''
        $script:profiles['archost01'] = New-StorageProfile -Vm 'archost01' -OsType '' -CreateOption 'Attach'
        $script:disks['sqlvm01-osdisk'] = "Standard_LRS`n"
        $script:disks['archost01-osdisk'] = 'StandardSSD_LRS'
        $drift = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoVmDiskDrift -Config $Config -VmName 'sqlvm01', 'archost01' })
        $drift.Count | Should -Be 1
        $drift[0].DiskName | Should -Be 'sqlvm01-osdisk'
        $drift[0].Current | Should -Be 'Standard_LRS'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -Times 2 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '^disk show --resource-group \S+ --name \S+-osdisk --query sku\.name --output tsv$' }
    }

    It 'doesn''t read a disk whose type the VM model already has' {
        $script:profiles['sqlvm01'] = New-StorageProfile -Vm 'sqlvm01' -OsType 'Standard_LRS'
        @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoVmDiskDrift -Config $Config -VmName 'sqlvm01' }).Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'disk' }
    }

    It 'finds an OS disk the subscription''s automation switched to Standard HDD, and says whether the template sets its type' {
        # Live, 2026-10-24: both OS disks became Standard_LRS while the VMs were deallocated.
        $script:profiles['sqlvm01'] = New-StorageProfile -Vm 'sqlvm01' -OsType 'Standard_LRS'
        $script:profiles['archost01'] = New-StorageProfile -Vm 'archost01' -OsType 'Standard_LRS' -CreateOption 'Attach'
        $drift = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoVmDiskDrift -Config $Config -VmName 'sqlvm01', 'archost01' })
        $drift.Count | Should -Be 2
        $t1 = $drift | Where-Object VmName -EQ 'sqlvm01'
        $t1.DiskName | Should -Be 'sqlvm01-osdisk'
        $t1.Kind | Should -Be 'OS'
        $t1.Current | Should -Be 'Standard_LRS'
        $t1.Expected | Should -Be 'StandardSSD_LRS' -Because 'the lowest-cost profile''s OS disk tier is E10'
        $t1.TemplateSetsType | Should -BeTrue
        ($drift | Where-Object VmName -EQ 'archost01').TemplateSetsType | Should -BeFalse -Because 'a golden host''s OS disk is attached by ID'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -Times 2 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match '^vm show .*--query storageProfile' }
    }

    It 'reports nothing when the disks match, and skips a VM it can''t read' {
        $script:profiles['sqlvm01'] = New-StorageProfile -Vm 'sqlvm01' -OsType 'StandardSSD_LRS'
        @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoVmDiskDrift -Config $Config -VmName 'sqlvm01', 'archost01' }).Count | Should -Be 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -ParameterFilter { $Message -match 'archost01: its storage profile couldn''t be read' }
    }

    It 'compares the template''s data disk too, and ignores a data disk the template doesn''t declare' {
        $script:profiles['sqlvm01'] = New-StorageProfile -Vm 'sqlvm01' -OsType 'StandardSSD_LRS' -DataDisks @(
            @{ name = 'sqlvm01-data01'; lun = 0; managedDisk = @{ storageAccountType = 'Standard_LRS' } }
            @{ name = 'someone-elses-disk'; lun = 1; managedDisk = @{ storageAccountType = 'Standard_LRS' } }
        )
        $drift = @(InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig -Override @{ dataDiskSku = 'E10' }) } { Get-DemoVmDiskDrift -Config $Config -VmName 'sqlvm01' })
        $drift.Count | Should -Be 1
        $drift[0].DiskName | Should -Be 'sqlvm01-data01'
        $drift[0].Kind | Should -Be 'Data'
        $drift[0].Expected | Should -Be 'StandardSSD_LRS'
        $drift[0].TemplateSetsType | Should -BeTrue
    }
}

Describe 'Get-DemoT4CreateFailure' {
    BeforeEach {
        $script:operations = [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = '' }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { if ($ArgumentList -contains 'operation') { $script:operations } else { $script:read } }
    }

    It 'reads the size and zone of a creation Azure refused with SkuNotAvailable, from the pgflex01 deployment and its operations' {
        # Live shape, 2026-10-26: the deployment's own error stops at ResourceDeploymentFailure; the code is in the server's operation.
        $json = ConvertTo-Json -Depth 20 -InputObject @{ properties = @{ provisioningState = 'Failed'; timestamp = '2026-10-26T14:11:42Z'; parameters = @{ sizing = @{ value = @{ skuName = 'Standard_B1ms' } }; availabilityZone = @{ value = '2' } }; error = @{ code = 'DeploymentFailed'; details = @(@{ code = 'ResourceDeploymentFailure'; details = $null }) } } }
        $script:read = [pscustomobject]@{ ExitCode = 0; StdOut = $json; StdErr = '' }
        $operations = ConvertTo-Json -Depth 20 -InputObject @(
            @{ properties = @{ provisioningState = 'Succeeded'; targetResource = @{ resourceType = 'Microsoft.Network/privateDnsZones' } } }
            @{ properties = @{ provisioningState = 'Failed'; targetResource = @{ resourceType = 'Microsoft.DBforPostgreSQL/flexibleServers' }; statusMessage = @{ status = 'Failed'; error = @{ code = 'SkuNotAvailable'; message = 'Specified SKU is not supported in this region. Please choose a different SKU.' } } } }
        )
        $script:operations = [pscustomobject]@{ ExitCode = 0; StdOut = $operations; StdErr = '' }
        $failure = InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4CreateFailure -Config $Config }
        $failure.Sku | Should -Be 'Standard_B1ms'
        $failure.Zone | Should -Be '2'
        $failure.TimeUtc | Should -Be '2026-10-26T14:11:42Z'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'deployment group show --resource-group rg-dbhub-demo --name pgflex01 --output json' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'deployment operation group list --resource-group rg-dbhub-demo --name pgflex01 --output json' }
    }

    It 'returns nothing for a deployment that succeeded, failed for another reason, or doesn''t exist' {
        foreach ($case in @(
                [pscustomobject]@{ ExitCode = 0; StdOut = '{"properties":{"provisioningState":"Succeeded"}}'; StdErr = '' }
                [pscustomobject]@{ ExitCode = 0; StdOut = '{"properties":{"provisioningState":"Failed","error":{"code":"Conflict"}}}'; StdErr = '' }
                [pscustomobject]@{ ExitCode = 3; StdOut = ''; StdErr = '(DeploymentNotFound) not found' }
            )) {
            $script:read = $case
            InModuleScope DbHubDemo -Parameters @{ Config = (New-TestConfig) } { Get-DemoT4CreateFailure -Config $Config } | Should -BeNullOrEmpty
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAz -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'operation' } -Because 'only the failed deployment needs its operations read'
    }
}
