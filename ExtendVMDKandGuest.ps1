# PowerCLI Script for adding vmdk to VM and extending disk in windows
# @davidstamen
# http://davidstamen.com

param(
  [string]$VM
)

#Save the current value in the $p variable.
$p = [Environment]::GetEnvironmentVariable("PSModulePath")

#Add the new path to the $p variable. Begin with a semi-colon separator.
$p += ";C:\Program Files (x86)\VMware\Infrastructure\vSphere PowerCLI\Modules\"

#Add the paths in $p to the PSModulePath value.
[Environment]::SetEnvironmentVariable("PSModulePath",$p)

#Save the current value in the $p variable.
$p = [Environment]::GetEnvironmentVariable("PSModulePath")
 
#Add the new path to the $p variable. Begin with a semi-colon separator.
$p += ";C:\Program Files (x86)\VMware\Infrastructure\vSphere PowerCLI\Modules\"
 
#Add the paths in $p to the PSModulePath value.
[Environment]::SetEnvironmentVariable("PSModulePath",$p)

Get-Module –ListAvailable VM* | Import-Module

Connect-VIServer -Server nc-vca01.co.randolph.nc.us
Connect-VIServer -Server sb-vca01.co.randolph.nc.us

$VM = Get-VM $VM
Get-VM $VM|Get-HardDisk|FT Parent, Name, CapacityGB -Autosize
$HardDisk = Read-Host "Enter VMware Hard Disk (Ex. 1)"
$HardDisk = "Hard Disk " + $HardDisk
$HardDiskSize = Read-Host "Enter the new Hard Disk size in GB (Ex. 50)"
$VolumeLetter = Read-Host "Enter the volume letter (Ex. c,d,e,f)"
Get-HardDisk -vm $VM | where {$_.Name -eq $HardDisk} | Set-HardDisk -CapacityGB $HardDiskSize -Confirm:$false
Invoke-VMScript -vm $VM -ScriptText "echo rescan > c:\diskpart.txt && echo select vol $VolumeLetter >> c:\diskpart.txt && echo extend >> c:\diskpart.txt && diskpart.exe /s c:\diskpart.txt" -ScriptType BAT
