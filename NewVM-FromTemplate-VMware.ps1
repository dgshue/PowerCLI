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

 
# ------vSphere Targeting Variables tracked below------
$vCenterInstance = "nc-vca01.co.randolph.nc.us"
 
# This section logs on to the defined vCenter instance above
Connect-VIServer $vCenterInstance -WarningAction SilentlyContinue 
 
 
######################################################-User-Definable Variables-In-This-Section-##########################################################################################
 
 
# ------Virtual Machine Targeting Variables tracked below------
 
# The Below Variables define the names of the virtual machines upon deployment, the target cluster, and the source template and customization specification inside of vCenter to use during
# the deployment of the VMs.
$VMName = $VM
$TargetClusterName = "ESHQ-NTX-Cluster1"
$SourceVMTemplateName = "Windows2016"
$SourceCustomSpecName = "Windows 2016 Clone"
$DataStoreName = "ESHQ-NTX-Cluster1-DS1"

 
# ------This Section Sets the Credentials to be used to connect to Guest VMs that are NOT part of a Domain------
 
# Below Credentials are used by the VM for first login to be able to add the machine to the new Domain.
# This should be the same local credentials as defined within the OS Customization Spec in VMware that you are using for the VM, in vCenter, go to the Home -> Customization Specifications Manager. 
#   Be sure to pay attention to your vCenter server when setting this, there are multiple configs for multiple vCenters. 
$LocalUser = "$VMName\Administrator"
$LocalPWordPlain = ""
 
# The below credentials are used by operations below once the domain controller virtual machines and the new domain are in place. These credentials should match the credentials
# used during the provisioning of the new domain. 
$DomainUser = ""
$DomainPWordPlain = ""

#Specify which roles to install. Be caustious here, a typo will result in failure of all roles.  Should be comma delimited and match the role names exactly.
# See Get-WindowsFeature on a server to get a full list. Management and Sub-Features will be installed as well.
$RolesToInstall = "Hyper-V,Failover-Clustering"

# Setup some vairables to pass to other commands below
$TargetCluster = Get-Cluster -Name $TargetClusterName
$SourceVMTemplate = Get-Template -Name $SourceVMTemplateName
$SourceCustomSpec = Get-OSCustomizationSpec -Name $SourceCustomSpecName
$DataStore = Get-Datastore -Name $DataStoreName


$LocalPWord = ConvertTo-SecureString -String $LocalPWordPlain -AsPlainText -Force
$LocalCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $LocalUser, $LocalPWord
$DomainPWord = ConvertTo-SecureString -String $DomainPWordPlain -AsPlainText -Force
$DomainCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $DomainUser, $DomainPWord 
 
 
 
# ------This Section Contains the Scripts to be executed against new VMs Regardless of Role
 
# This Scriptblock is used to add new VMs to the newly created domain by first defining the domain creds on the machine and then using Add-Computer
$JoinNewDomain = '$DomainUser = "' + $($DomainUser) + '";
                  $DomainPWord = ConvertTo-SecureString -String "'+$($DomainPWordPlain)+'" -AsPlainText -Force;
                  $DomainCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $DomainUser, $DomainPWord;
                  Add-Computer -DomainName co.randolph.nc.us -Credential $DomainCredential;
                  Start-Sleep -Seconds 60'
 
 
 
# ------This Section Contains the Scripts to be executed against the VM after creation and joining the fomain------
$InstallRoles = 'Install-WindowsFeature -Name '+$($RolesToInstall)+' -IncludeAllSubFeature -IncludeManagementTools'
 
########################################################################################################################################################################################
 

# Script Execution Occurs from this point down
 
# ------This Section Deploys the new VM(s) using a pre-built template and then applies a customization specification to it. It then waits for Provisioning To Finish------
 
Write-Verbose -Message "Deploying Virtual Machine with Name: [$VMName] using Template: [$SourceVMTemplate] and Customization Specification: [$SourceCustomSpec] on Cluster: [$TargetCluster] and waiting for completion" -Verbose
 
New-VM -Name $VMName -Template $SourceVMTemplate -ResourcePool $TargetCluster -OSCustomizationSpec $SourceCustomSpec -Datastore $DataStore

$NewVM = Get-VM -Name $VMName
 
Write-Verbose -Message "Virtual Machine $VMName Deployed, configuring for nested Hypervisor, Powering On" -Verbose

$NewVMView = Get-View -Id $NewVM.Id


## Configuration for enabling a nested Hypervisor, not required if not running ESXi/Hyper-V on top of ESXi
$vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
$vmConfigSpec.NestedHVEnabled = $true

$configItems = @{"hypervisor.cpuid.v0" = 'FALSE'}


foreach($item in $configItems.GetEnumerator()){

    $extra = New-Object VMware.Vim.optionvalue
    $extra.Key=$item.Key
    $extra.Value=$item.Value
    $vmConfigSpec.extraconfig += $extra
}

$NewVMView.ReconfigVM($vmConfigSpec)

# Power on the new VM
Start-VM -VM $VMName

# ------This Section Targets and Executes the Scripts on the New VM.
 
# NOTE - The Below Sleep Command is due to it taking a few seconds for VMware Tools to read the IP Change so that we can return the below output. 
# This is strctly informational and can be commented out if needed, but it's helpful when you want to verify that the settings defined above have been 
# applied successfully within the VM. We use the Get-VM command to return the reported IP information from Tools at the Hypervisor Layer.

Write-Verbose -Message "Waiting for VM to boot, do VMware customization, and reboots..." -Verbose
Start-Sleep 180
Wait-Tools -VM $VMName -TimeoutSeconds 300

$FSEffectiveAddress = (Get-VM $VMName).guest.ipaddress[0]
Write-Verbose -Message "Assigned IP for VM [$VMName] is [$FSEffectiveAddress]" -Verbose 
Start-Sleep 60

Write-Verbose -Message "Joining Domain..." -Verbose
# The Below Cmdlets actually add the VM to the newly deployed domain. 
Invoke-VMScript -ScriptText $JoinNewDomain -VM $VMName -GuestCredential $LocalCredential

# Restart VM with a separate command to make sure the previous suceeded.
Invoke-VMScript -ScriptText "Restart-Computer -Force" -VM $VMName -GuestCredential $LocalCredential
 
# Below sleep command is in place as the reboot needed from the above command doesn't always happen before the wait-tools command is run
 
Wait-Tools -VM $VMName -TimeoutSeconds 300
Write-Verbose -Message "VMTools up after joining domain... waiting 2 min..." -Verbose
Start-Sleep -Seconds 120
 
Write-Verbose -Message "VM $VMName Added to Domain and Successfully Rebooted." -Verbose
 
Write-Verbose -Message "Installing Hyper-V and Failover Cluster roles on $VMName." -Verbose
 
# The below commands actually execute the script blocks defined above to install selected roles, using local Admin account vs Domain account. 
Invoke-VMScript -ScriptText $InstallRoles -VM $VMName -GuestCredential $LocalCredential

Invoke-VMScript -ScriptText "Restart-Computer -Force" -VM $VMName -GuestCredential $LocalCredential

 
Write-Verbose -Message "Environment Setup Complete" -Verbose
 
# End of Script