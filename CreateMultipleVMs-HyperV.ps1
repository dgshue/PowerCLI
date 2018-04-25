

[int]$VMcount = Read-host “Input Number of VMs”
$VMTemplate = "Windows2016_1709"
$VMNamePreFix = Read-host “Input VM Name Prefix” 
$VMHost = "WFC-Node1"
$VMPath = "C:\Clusterstorage\Volume1\VMs"

$Total = 1

While ($total -le $VMCount) {$NewVMName = "$VMNamePrefix" + $total

Write-Output $virtualMachineConfiguration

New-SCVirtualMachine -Name $NewVMName -VMHost $VMHost -path $VMPath -VMTemplate $VMTemplate -ReturnImmediately -DelayStartSeconds “0"

$Total++

}

#End