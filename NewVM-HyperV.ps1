# Filename:    AutomateNewVMCreation.ps1
# Description: Create a System Center Virtual Machine Manager-based 
#              hardware profile and operating-system profile; use 
#              these profiles and a sysprepped VHD to create a 
#              template; use the template to create 'n' number of 
#              virtual machines, adding an additional VHD to each
#              new VM; and deploy each virtual machine on the most 
#              suitable host. Display progress messages for each task 
#              and display a final status message for attempt to
#              create a virtual machine.

# DISCLAIMER:
# Copyright © Microsoft Corporation. All rights reserved. This 
# script is made available to you without any express, implied or 
# statutory warranty, not even the implied warranty of 
# merchantability or fitness for a particular purpose, or the 
# warranty of title or non-infringement. The entire risk of the 
# use or the results from the use of this script remains with you.

####################################################################
# Define variables
####################################################################
# Define a string variable for your VMM server.
$VMMServer = "SCVMM1"

# Define hardware profile parameters.
$HWProfileName = "HwCfgWith1DVD1NIC512MBRam"
$MemoryInMB = 512

# Define guest OS profile parameters.
$OSProfileName = "Win2K3R2Profile"
$ProductKey = "C938K-6CHYF-2K8VH-FX94R-XVQ2J"
$AdminPassword = "!!123abc"
$FullName = "VMMUser"
$Workgroup = "VMWorkgroup"
$SysPrepScriptPath = "\\LibraryServer1.Contoso.com\MSSCVMMLibrary\Scripts\SysPrep.inf"

# Define template parameters.
$TemplateName = "Win2K3R2Template"
$SysPrepVHDPath = "\\LibraryServer1.Contoso.com\MSSCVMMLibrary\VHDs\ENU-W2003-Std-R2-Sysprep.vhd"

# Define VM parameters.
$VMName = "VMN_"
$VMAdditionalVhdDiskPath = "\\LibraryServer1.Contoso.com\MSSCVMMLibrary\VHDs\BaseDisk20GB.vhd"
$NumVMs = 2

####################################################################
# Define a function to create a PSCredential object.
####################################################################
function SecurePass {
param([string]$User, [string]$Password)
    $SPassword = New-Object System.Security.SecureString
    for ($i=0; $i -lt $Password.Length; $i++) {
        $SPassword.AppendChar($Password[$i])
    }
    New-Object System.Management.Automation.PSCredential $User,$SPassword
}

####################################################################
# Connect to the Virtual Machine Manager server.
####################################################################
$C = Get-VMMServer $VMMServer

####################################################################
# Create a hardware profile.
####################################################################
$HWProfileJobGroup = [System.Guid]::NewGuid()
New-VirtualDVDDrive -Bus 1 -Lun 0 -JobGroup $HWProfileJobGroup
New-VirtualNetworkAdapter -EthernetAddressType Dynamic -NoConnection -JobGroup $HWProfileJobGroup
$HWProfile = New-HardwareProfile -Name $HWProfileName -MemoryMB $MemoryInMB -JobGroup $HWProfileJobGroup

####################################################################
# Create a guest OS profile from the SysPrep.inf script.
####################################################################
$Script = Get-Script | where {$_.SharePath -eq $SysPrepScriptPath}
$Cred = SecurePass "Administrator" $AdminPassword
$OSProfile = New-GuestOSProfile -Name $OSProfileName -Desc $OSProfileName -ComputerName "*" -ProductKey $ProductKey -FullName $FullName -JoinWorkgroup $Workgroup -AdminPasswordCredential $Cred -SysPrepFile $Script

####################################################################
# Create a template from the Win2K3R2 sysprepped VHD, hardware 
# profile, and guest OS profile.
####################################################################
$Win2K3R2VHD = Get-VirtualHardDisk | where {$_.SharePath -eq $SysPrepVHDPath}
$TemplateJobGroup = [System.Guid]::NewGuid()
$Win2K3R2VHD | Add-VirtualHardDisk -Bus 0 -Lun 0 -IDE -JobGroup $TemplateJobGroup
$Template = New-Template -Name $TemplateName -Description $TemplateName -HardwareProfile $HWProfile -GuestOSProfile $OSProfile -JobGroup $TemplateJobGroup

#####################################################################
# Create the specified number of VMs from the template (adding 
# another VHD) and determine the best host on which to deploy each VM.
#####################################################################
# Create a random number used later to create a unique name for a VM.
$Random = (New-Object Random)

# Get the object that represents BaseDisk20GB.vhd.
$VMAdditionalVhd = Get-VirtualHardDisk | where {$_.SharePath -eq $VMAdditionalVhdDiskPath}

# Get the objects that represent all hosts.
$VMHosts = Get-VMHost

# Calculate the amount of hard disk space required on the physical 
# host by a VM. 
$DiskSizeGB = ($Win2K3R2VHD.Size + $VMAdditionalVhd.Size) /1024 /1024 /1024

# Create variable arrays in which to store tasks and VMS.
$NewVMTasks = [System.Array]::CreateInstance("Microsoft.SystemCenter.VirtualMachineManager.Task", $NumVMs)
$NewVMs = [System.Array]::CreateInstance("Microsoft.SystemCenter.VirtualMachineManager.VM", $NumVMs)

$i = 0
# Loop that creates each VM asynchronously.
while($NumVMs -gt 0)
{
    # Generate a unique VM name.
    $VMRnd = $Random.next()
    $NewVMName = $VMName+$VMRnd

    # Get the ratings for each host and sort the hosts by ratings.
    $Ratings = @(Get-VMHostRating -Template $Template -VMHost $VMHosts -DiskSpaceGB $DiskSizeGB -VMName $NewVMName | where { $_.Rating -gt 0} | Sort-Object -property Rating -descending)

    if ($Ratings.Count -gt 0) 
    {
       $VMHost = $Ratings[0].VMHost
       $VMPath = $Ratings[0].VMHost.VMPaths[0]

       # Create a new VM from the template and add an additional VHD
       # to the VM.
       $NewVMJobGroup = [System.Guid]::NewGuid()
       $VMAdditionalVhd | Add-VirtualHardDisk -Bus 0 -Lun 1 -IDE -JobGroup $NewVMJobGroup
       $NewVMs[$i] = New-VM -Template $Template -Name $NewVMName -Description $NewVMName -VMHost $VMHost -Path $VMPath -RunAsynchronously -StartVM -JobGroup $NewVMJobGroup
       $NewVMTasks[$i] = $NewVMs[$i].MostRecentTask
       $i = $i + 1
   }
   $NumVMs = $NumVMs - 1
   Start-Sleep -seconds 5
}

####################################################################
# Wait for all of the tasks to complete, and provide a progress 
# message about each task.
####################################################################
$Done = 0
while($Done -eq 0)
{ 
    $Done = 1
    Start-Sleep -seconds 5
    ForEach($Task in $NewVMTasks)
    {
        echo "##############################"
        echo $Task.ResultName "VM creation" $Task.Status $Task.Progress Complete $Task.ErrorInfo.Problem 
        echo "##############################"
        echo ""
        if($Task.Status -eq "Running")
        {
           $done = 0
        }
    }
}

####################################################################
# Display results.
####################################################################
ForEach($Task in $NewVMTasks)
{
    echo "##############################"
    echo $Task.ResultName "VM creation " $Task.Status "Start time" $Task.StartTime.DateTime "End time" $Task.EndTime.DateTime $Task.ErrorInfo.Problem 
    echo "##############################"
    echo ""
} 