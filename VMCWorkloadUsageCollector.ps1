Function Get-WorkloadUsage {
    <#
        .NOTES
        ===========================================================================
        Created by:    William Lam
        Organization:  VMware
        Blog:          www.virtuallyghetto.com
        Twitter:       @lamw
        ===========================================================================
        .DESCRIPTION
            This function returns usage information for CPU, Memory and Disk for a given vSphere Cluster
            which helps provide information to VMware Cloud on AWS (VMC) Sizer Tool https://vmcsizer.vmware.com/home
        .PARAMETER Cluster
            The name of a vSphere Cluster to analyze
        .EXAMPLE
            Get-WorkloadUsage -Cluster Cluster-01
        .EXAMPLE
            Get-WorkloadUsage -Cluster Cluster-01 -VMIncludeList @("VM-1", "VM-2", "VM-3")
        .EXAMPLE
            Get-WorkloadUsage -Cluster Cluster-01 -VMExcludeList @("VM-4","VM-5")
    #>
    param(
        [Parameter(Mandatory=$true)][String]$Cluster,
        [Parameter(Mandatory=$false)][String[]]$VMIncludeList,
        [Parameter(Mandatory=$false)][String[]]$VMExcludeList
    )

    $clusterView = Get-View (Get-Cluster $Cluster)

    $hostResults = @()
    $vmhosts = Get-View -ViewType HostSystem -SearchRoot $clusterView.MoRef -Property Name, Hardware.MemorySize, Hardware.CpuInfo
    foreach ($vmhost in $vmhosts) {
        $tmp = [pscustomobject] @{
            Name = $vmhost.name;
            CpuCores = $vmhost.hardware.CpuInfo.NumCpuCores;
            Memory = $vmhost.hardware.memorySize;
        }
        $hostResults += $tmp
    }

    $vmResults = @()
    $vms = Get-View -ViewType VirtualMachine -SearchRoot $clusterView.MoRef -Property Name,Summary.Runtime.PowerState,Summary.Config,Config.Hardware.Device

    if($VMIncludeList) {
        $vms = $vms | where {$_.name -in $VMIncludeList}
    }

    if($VMExcludeList) {
        $vms = $vms | where {$_.name -ne $VMExcludeList}
    }

    foreach ($vm in $vms) {
        $disks = $vm.Config.Hardware.Device | where {$_ -is [VMware.Vim.VirtualDisk]}
        $totalCapacity = 0
        ($disks | where {$_ -is [VMware.Vim.VirtualDisk]}).CapacityInKB | Foreach { $totalCapacity += $_}

        $tmp = [pscustomobject] @{
            Name = $vm.name;
            PoweredState = $vm.summary.runtime.PowerState;
            vCPU = $vm.summary.config.numCpu;
            vMEM = $vm.summary.config.memorySizeMB;
            vDisk = $totalCapacity;
        }
        $vmResults += $tmp
    }

    $totalPoweredOnvCPU = $totalvCPU = $totalPoweredOnvMem = $totalvMem = $totalHostCPU = $totalHostMem = $totalPoweredOnvDisk = 0
    ($vmResults | where {$_.PoweredState -eq "poweredOn"}).vcpu | Foreach { $totalPoweredOnvCPU += $_}
    ($vmResults | where {$_.PoweredState -eq "poweredOn"}).vmem | Foreach { $totalPoweredOnvMem += $_}
    ($vmResults | where {$_.PoweredState -eq "poweredOn"}).vdisk | Foreach { $totalPoweredOnvDisk += $_}
    $vmResults.vcpu | Foreach { $totalvCPU += $_}
    $vmResults.vmem | Foreach { $totalvMem += $_}
    $hostResults.cpucores | Foreach { $totalHostCPU += $_}
    $hostResults.Memory | Foreach { $totalHostMem += $_}
    $vCPUtoCoreRatio = [math]::Round($totalPoweredOnvCPU/$totalHostCPU,2)
    $vCPUOvercommit = [math]::Round((($totalPoweredOnvCPU - $totalHostCPU) / $totalHostCPU)*100,2)
    $VMtoHostRatio = [math]::Round( ($vmResults.count / $vmhosts.count),2)

    $totalHostMemInGB = [math]::Round($totalHostMem/1Gb,2)
    $totalvMemInGB = [math]::Round($totalvMem*1Mb/1Gb,2)
    $totalvDiskInGB = [math]::Round($totalPoweredOnvDisk/1Mb,2)
    $totalPoweredOnvMemInGB = [math]::Round($totalPoweredOnvMem*1Mb/1Gb,2)
    $vMemtoHostMemRatio = [math]::Round($totalPoweredOnvMemInGB/$totalHostMemInGB,2)
    $memOvercommit = [math]::Round((($totalPoweredOnvMemInGB - $totalHostMemInGB) / $totalHostMemInGB)*100,2)

    $measureVMvCPU = ($vmResults | where {$_.PoweredState -eq "poweredOn"}).vcpu | measure -Maximum -Average -Minimum
    $measureVMvMem = ($vmResults | where {$_.PoweredState -eq "poweredOn"}).vmem | measure -Maximum -Average -Minimum
    $measureVMvDisk = ($vmResults | where {$_.PoweredState -eq "poweredOn"}).vdisk | measure -Maximum -Average -Minimum

    $resultsString = @"

    ### Cluster Summary ###
        Name: $Cluster
        Total Host: $($hostResults.Count)
        Total VM: $($vms.count)
        Total Storage (GB): $totalvDiskInGB
        VM to Host Ratio: $VMtoHostRatio

    ### CPU Summary ###
        Total CPU Cores: $totalHostCPU
        Total vCPUs: $totalvCPU
        Total PoweredOn vCPUs: $totalPoweredOnvCPU
        vCPU to Core Ratio: $vCPUtoCoreRatio
        CPU Overcommmitment (%): $vCPUOvercommit

    ### Memory Summary ###
        Total Physical Memory (GB): $totalHostMemInGB
        Total vMem (GB): $totalvMemInGB
        Total PoweredOn vMEM (GB): $totalPoweredOnvMemInGB
        vMem to Memory Ratio: $vMemtoHostMemRatio
        Memory Overcommitment (%): $memOvercommit

    ### VM vCPU Summary ###
        Min vCPU: $($measureVMvCPU.Minimum)
        Max vCPU: $($measureVMvCPU.Maximum)
        Avg vCPU: $([math]::round($measureVMvCPU.Average,2))

    ### VM vMem (GB) Summary ###
        Min vMem: $([math]::Round($measureVMvMem.Minimum*1Mb/1Gb,2))
        Max vMem: $([math]::Round($measureVMvMem.Maximum*1Mb/1Gb,2))
        Avg vMem: $([math]::Round($measureVMvMem.Average*1Mb/1Gb,2))

    ### VM vDisk (GB) Summary ###
        Min vDisk: $([math]::Round($measureVMvDisk.Minimum/1Mb,2))
        Max vDisk: $([math]::Round($measureVMvDisk.Maximum/1Mb,2))
        Avg vDisk: $([math]::Round($measureVMvDisk.Average/1Mb,2))

"@
    $resultsString
}