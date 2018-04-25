# Script to rename many VMs and join them to the domain
# See https://superwidgets.wordpress.com/category/powershell/ for more details
# Requires Hyper-V and FailoverClusters modules. We'll use them off of the Hyper-V server via implicit remoting
# Sam Boutros - 7/3/2014 - V1.0
# 7/11/2014 - V1.1 - added code to online, initialize, and format 2 disks on each VM
# 7/29/2014 - V1.2 added option to run on all cluster VMs instead of localhost VMs only
# 7/31/2014 - V1.3 added code to 1. Enable file a print sharing (so that administrative shares are accessible)
#                                2. Set time zone to EST (GMT-5) - default was GMT-8
#                                3. Activate Windows 
#                                4. Enable Remote Desktop
#

$VMHDPath = 'C:\ClusterStorage\sqldata\vms\'
$NumberofVMs = 3 #How many VMs do you need?
$VMPrefix = 'Kube-Node' # We'll use that to make sure we don't process other VMs on this host..
$LocalAdmin = 'administrator' # This is the local admin account on the VMs
$DomainAdmin = 'rcob\itdgs'
# A domain admin account is not needed. By default, credentials of the user running this script will be used to join the VMs to the domain.
# If you're processing 10 VMs or less, any domain user account will do. If you're processing more than 10 VMs you need a domain account that has the "Create all child objects" AD permission to the Computers container in AD
$DomainName = "co.randolph.nc.us" 
#$Disks = @('e','f') # enter the drive letters for the disks to be initialized on each VM
#$BlockSize = 64KB # Enter the block size used to format the VM disks
$HyperVHost = 'LOCALHOST' # name of a HyperV host that's available in the environment. We'll use its HyperV & FailoverClusters PS modules via implicit remoting
$TimeZone = 'Eastern Standard Time'
$WinKey = 'WFHN3-GPQ77-2GT33-78MRV-WK9QH' # Using AVMA key for Windows 2012 R2 DC - see http://technet.microsoft.com/en-us/library/dn303421.aspx
# End Data Entry section
#
function Log {
    [CmdletBinding()]
    param(
        [Parameter (Mandatory=$true,Position=1,HelpMessage="String to be saved to log file and displayed to screen: ")][String]$String,
        [Parameter (Mandatory=$false,Position=2)][String]$Color = "White",
        [Parameter (Mandatory=$false,Position=3)][String]$Logfile = $myinvocation.mycommand.Name.Split(".")[0] + "_" + (Get-Date -format yyyyMMdd_hhmmsstt) + ".txt"
    )
    write-host $String -foregroundcolor $Color  
    ((Get-Date -format "yyyy.MM.dd hh:mm:ss tt") + ": " + $String) | out-file -Filepath $Logfile -append
}
#
$Logfile = (Get-Location).path + "\Init-VMs_" + (Get-Date -format yyyyMMdd_hhmmsstt) + ".txt"
if (!(Test-Path -Path ".\LocalCred.txt")) {
    Read-Host 'Enter the pwd to be encrypted and saved to .\LocalCred.txt for future script use:' -AsSecureString | ConvertFrom-SecureString | Out-File .\LocalCred.txt
}
$Pwd = Get-Content .\LocalCred.txt | ConvertTo-SecureString 
$LocalCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $LocalAdmin, $Pwd
if (!(Test-Path -Path ".\DomainCred.txt")) {
    Read-Host 'Enter the pwd to be encrypted and saved to .\DomainCred.txt for future script use:' -AsSecureString | ConvertFrom-SecureString | Out-File .\DomainCred.txt
}
$Pwd = Get-Content .\DomainCred.txt | ConvertTo-SecureString 
$DomainCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $DomainAdmin, $Pwd


#Create VMs
for ($i=1; $i -le $NumberofVMs; $i++) {

$VM = $VMPrefix + $i

New-VHD -path "$($VMHDPath)$($vm).vhdx" -ParentPath "$($VMHDPath)Server1709.vhdx" -differencing
New-VM -Name $VM -Path $VMHDPath -VHDPath "$($VMHDPath)$($VM).vhdx" | Set-VMMemory -DynamicMemoryEnabled $true -MaximumBytes 2GB -MinimumBytes 512MB -StartupBytes 1GB

Start-VM -Name $VM

}

Start-Sleep -Seconds 120 # Wait for VMs to start up

# Need Hyper-V and Failoverclusters modules - importing session commands - implicit remoting:


$Session = New-PSSession -ComputerName $HyperVHost
Invoke-Command -ScriptBlock { Import-Module Hyper-V,FailoverClusters } -Session $Session # Imports these 2 modules in this PS instance (if we don't have them locally)
Import-PSSession -Session $Session -Module Hyper-V,FailoverClusters | Out-Null # Import the 2 modules' commands in this PS instance
$VMs = Get-VM | Where-Object { ($_.State –eq ‘Running’) -and ($_.Name.StartsWith($VMPrefix)) } # Get all running VMs on $HyperVHost
# Alternatively, the following line gets all running VMs on the 'GS-Cluster' cluster:
# $VMs  = Get-ClusterGroup -Cluster 'GS-Cluster' | Where-Object { ($_.State –eq ‘Online’) -and ($_.Name.StartsWith($VMPrefix)) } | Sort -Property 'OwnerNode'
$VMCount = $VMs.Count
if ($VMCount -lt 1) {log "Error: No running VMs found that have the prefix $VMPrefix in their name.. stopping" Yellow $Logfile; break}
#
function RanameAndJoin() {
    $s = 0 # Success counter
    for ($i=1; $i -lt $VMCount+1; $i++) {
        $VMName = $VMs[$i-1].Name
        if ($VMs[$i-1].OwnerNode -ne $null) { $HVHost = $VMs[$i-1].OwnerNode } else { $HVHost = '.' }
        $IP = (Get-VMNetworkAdapter -VMName $VMName -ComputerName $HVHost | Select -ExpandProperty ipaddresses)[0]
        log "Processing VM# $i of $VMcount : $VMName, IP address: $IP" Cyan $Logfile
        $Current = Invoke-Command -ComputerName $VMName { param($VMName)
                Get-WmiObject -Class Win32_ComputerSystem -ComputerName $VMName} -ArgumentList $VMName
        $CurrentName = $Current.Name
        $CurrentDomain = $Current.Domain
        if ($CurrentDomain -ne $DomainName) {
            log "Attmpting to change machine domain\name from $CurrentDomain\$CurrentName to $DomainName\$VMName" Cyan $Logfile
            if ($CurrentName -eq $VMName) { # Join domain only
                Invoke-Command -ComputerName $VMName { param($DomainName,$LocalCred,$DomainCred,$VMName) 
                    Add-Computer -DomainName $DomainName -LocalCredential $LocalCred -Credential $DomainCred -Restart -Force
                } -ArgumentList $DomainName,$LocalCred,$DomainCred,$VMName
            } else { # Join domain and rename VM
                Invoke-Command -ComputerName $VMName { param($DomainName,$LocalCred,$DomainCred,$VMName) 
                    Add-Computer -NewName $VMName -DomainName $DomainName -LocalCredential $LocalCred -Credential $DomainCred -Restart -Force
                } -ArgumentList $DomainName,$LocalCred,$DomainCred,$VMName
            }
        } else { $s += 1; log "VM $VMName is already a member of the $DomainName domain" Green $Logfile }
    }
    return $s
}
#
log "Pass 1, Rename the VMs and join them to domain $DomainName :" Yellow $Logfile
$s = RanameAndJoin
If ($s -lt $VMCount) { log "Pass 2, verify success/failure:" Yellow $Logfile; $s = RanameAndJoin}
If ($s -lt $VMCount) { log "Error: only $s VMs were renamed and joined the domain from a total of $VMCount" Magenta $Logfile}
    else { log "All VMs have been successfully renamed and joined to the $DomainName domain" Green $Logfile} 
#
# Format disks on VMs
<#
for ($i=1; $i -lt $VMCount+1; $i++) {
    $VMName = $VMs[$i-1].Name
    $IP = (Get-VMNetworkAdapter -VMName $VMName | Select -ExpandProperty ipaddresses)[0]
    log "Initializing & formatting disks '$Disks' on VM# $i of $VMcount : $VMName, IP address: $IP" Cyan $Logfile
    For ($j=0; $j -lt $Disks.Count; $j++) {
        $DriveLetter = $Disks[$j]
        Invoke-Command -ComputerName $VMName { param($DriveLetter,$BlockSize) 
            $VMDisks = Get-Disk | where partitionstyle -eq "Raw" # Get raw disks if any
            if ($VMDisks.Count -gt 0) {
                Initialize-Disk -Number $VMDisks[0].Number -PartitionStyle GPT -PassThru 
                New-Partition -DiskNumber $VMDisks[0].Number -DriveLetter $DriveLetter -UseMaximumSize
                Format-Volume -DriveLetter $DriveLetter -FileSystem NTFS -NewFileSystemLabel "Drive_$DriveLetter" -Confirm:$false -AllocationUnitSize $BlockSize
            }
        } -ArgumentList $DriveLetter,$BlockSize
    }
    log "Activating Windows, enabling file/print sharing, setting time zone, and enabling Remote Desktop.." Cyan $Logfile
    Invoke-Command -ComputerName $VMName { param($WinKey,$TimeZone) 
        # Activate Windows - no Internet access needed:
        slmgr /ipk $WinKey
        # Enable file and print sharing:
        netsh advfirewall firewall set rule group=”File and Printer Sharing” new enable=Yes
        # Set time zone:
        tzutil /s $TimeZone
        # Enable Remote Desktop
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server'-name "fDenyTSConnections" -Value 0
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -name "UserAuthentication" -Value 1   
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
    } -ArgumentList $WinKey,$TimeZone
}
#> 
#
# Doing separate loop for checking process success/failure to give the VMs time to finish the format (avoid false negatives)
for ($i=1; $i -lt $VMCount+1; $i++) {
    $VMName = $VMs[$i-1].Name
    $IP = (Get-VMNetworkAdapter -VMName $VMName | Select -ExpandProperty ipaddresses)[0]
    log "Checking disks '$Disks' on VM# $i of $VMcount : $VMName, IP address: $IP" Cyan $Logfile
    if (!($LogString -eq $null)) { log $LogString $Logfile; $LogString = $null }
    For ($j=0; $j -lt $Disks.Count; $j++) {        
        $DriveLetter = $Disks[$j] + ":\"
        Invoke-Command -ComputerName $VMName { param($DriveLetter,$VMName) 
            if (Test-Path -Path $DriveLetter) {$LogString += "    Drive $DriveLetter initialized & formatted successfully on VM $VMName      "
            } else { $LogString += "Failed to initialize & format drive $DriveLetter on VM $VMName      " }
            return $LogString
        } -ArgumentList $DriveLetter,$VMName
    }    
}
#
Remove-PSSession $Session
If ($Error.Count -gt 0) { log "Errors encountered: $Error" Magenta $Logfile } else { log "All VMs successfully setup." Cyan $Logfile }