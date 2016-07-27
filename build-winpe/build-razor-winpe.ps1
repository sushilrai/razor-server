# -*- powershell -*-
# To run this script:
# powershell -executionpolicy bypass -file build-razor-winpe.ps1 [ASM appliance IP -or- DHCP] [Your Windows .iso name] [New Windows .iso name]
#
#
param(
    [Cmdletbinding(PositionalBinding = $false)]
    [string]$asmapplianceip,
    [string]$userisoname,
    [string]$finalisoname
)

function test-administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function get-currentdirectory {
    $thisName = $MyInvocation.MyCommand.Name
    [IO.Path]::GetDirectoryName((Get-Content function:$thisName).File)
}
function check-validip ([string]$isvalidip) {
   $hasfouroctet = (($isvalidip.Split((".")) | Measure-Object).Count -eq 4)
   if(!$hasfouroctet) {
       Write-Host 'WARNING: Invalid ASM Appliance IP if ASM appliance is not your DHCP server'
       return $false
   } else {
      foreach($string in $isvalidip.Split(".")) {
          if(($string.Length -gt 3) -or ($string.Length -lt 1)) {
                 Write-Host 'WARNING: Invalid ASM Appliance IP if ASM appliance is not your DHCP server'
                 return $false
          }
      }
   }
   return $true
}

function check-validisoname ([string] $isvalidiso) {
    $filename = [System.IO.Path]::GetFileName($isvalidiso)
    $extension = [System.IO.Path]::GetExtension($isvalidiso)
    $test = $extension.CompareTo('.iso')
    $test2 = $filename.Length
    if(($test -eq '0') -and ($test2 -ne '0') -and ($filename -ne '.iso')) {
        return $true
    } else {
        return $false
    }
}

if (-not (test-administrator)) {
    write-error @"
You must be running as administrator for this script to function.
Unfortunately, we can't reasonable elevate privileges ourselves
so you need to launch an administrator mode command shell and then
re-run this script yourself.  
"@
    exit 1
}

if(!$finalisoname) {
    $finalisoname = 'asmwindows.iso'
} 

if(-not (check-validisoname $finalisoname)) {
    write-host 'Error: Final iso name entered ' $finalisoname ' is not a valid iso name.'
    exit 1
}

# Basic location stuff...
$cwd    = get-currentdirectory
$razorclientloc = $cwd + '\razor-client.ps1'
$output = join-path $cwd "razor-winpe"
$mount  = join-path $cwd "razor-winpe-mount"
$adkversion = 0.0
$userisoloc = $cwd + '\' + $userisoname

#Check user .iso exists and mount user's Windows iso
if(check-validisoname $userisoname) {
    if(-not(test-path $userisoloc)) {
        write-host 'ERROR: The user iso location does not exist, ensure the iso is located in the same folder as this script'
        write-host 'Could not locate .iso: ' $userisoloc
        exit 1
    }
} else {
    write-host 'ERROR: The user iso name ' $userisoname ' is not valid.'
    exit 1
}
Mount-DiskImage -ImagePath $userisoloc -Verbose

#Find drive letter for mounted .iso
$ciminstance = Get-DiskImage -ImagePath $userisoloc
$info = Get-Volume -DiskImage $ciminstance 
$driveletter = $info.DriveLetter
$isodirectory = $driveletter + ":\*"
Write-Host 'Iso mounted at: ' $driveletter ' and iso directory is: ' $isodirectory

#Create working copy of .iso files
$windowsdirectory = Join-Path $cwd "\workingisofiles"
New-Item $windowsdirectory -type directory
Copy-Item $isodirectory $windowsdirectory -Recurse

#Find boot.wim and install.wim, copy to where we need, and ensure writeable
$bootwimloc = $windowsdirectory + "\sources\boot.wim"
$installwimloc = $windowsdirectory + "\sources\install.wim"
$file = Get-Item $bootwimloc
$file.IsReadOnly = $false
$file = Get-Item $installwimloc
$file.IsReadOnly = $false
Copy-Item $bootwimloc $cwd
Copy-Item $installwimloc $cwd

#Create razor-client.ps1 script with appliance IP
Write-host 'writing new razor client file with IP: ' $asmapplianceip
New-Item $razorclientloc -ItemType file
Write-Host 'File created creating strings'
$string1 = '# -*- powershell -*-#'
$String2 = '#'
$string3 = '# Search for the SET_STATIC_IP.CMD script on all mounted disks. If'
$string4 = '# the disk isn''t mounted or the script is not found there, just'
$string5 = '# continue. The script is included in the iPXE iso image in'
$string6 = '# static OS installation case.'
$string7 = '#'
$string8 = '$VolumeName = ''iPXE'''
$string9 = '$ScriptName = ''SET_STATIC_IP.CMD'''
$string10 = ''
$string11 = '# List all drives, grep for ''iPXE'' (the volume name set by the ipxe iso'
$string12 = '# generator code), and cut the first column (the drive letter plus '':'')'
$string13 = '$TargetDrive = wmic logicaldisk get ''caption,volumename'' | Select-String -Pattern $VolumeName | Out-String | %{$_.split('' '')[0]}'
$string14 = ''
$string15 = '# Strip out \r and \n characters'
$string16 = '$TargetDrive = ($TargetDrive.Replace("`n", '''')).Replace("`r",'''')'
$string17 = ''
$string18 = 'If (-Not ([string]::IsNullOrEmpty($TargetDrive))) {'
$string19 = '  # Found a volume named $VolumeName, now look for the script file'
$string20 = '  $ScriptPath = $TargetDrive + ''\'' + $ScriptName'
$string21 = ''
$string22 = '  If (test-path $ScriptPath) {'
$string23 = '    # Found the script, run it'
$string24 = '    cmd /c $ScriptPath $asmapplianceip'
$string25 = ''
$string26 = '    # Check return code from script'
$string27 = '    If (-Not ($LASTEXITCODE -eq 0)) {'
$string28 = '      # Error out if script returned an error'
$string29 = '      echo "ERROR: Script ''$ScriptName'' returned exit code: $LASTEXITCODE"'
$string30 = '      exit $LASTEXITCODE'
$string31 = '    }'
$string32 = '    echo "Script ''$ScriptName'' executed successfully"'
$string33 = '  }'
$string34 = '}'
$string35 = '# If we have a configuration file, source it in.'
$string36 = '$configfile = join-path $env:SYSTEMDRIVE "razor-client-config.ps1"'
$string37 = 'if (test-path $configfile) {'
$string38 = '    write-host "sourcing configuration from $configfile"'
$string39 = '    . $configfile'
$string40 = '    # $server is now set'
$string41 = '} else {'
$string42 = '    # No sign of a configuration file, our DHCP server is also our ASM server.'
$string43 ='    write-host "DHCP server == Razor server!"'
$string44 ='    $server = get-wmiobject win32_networkadapterconfiguration |'
$string45 ='                  where { $_.ipaddress -and'
$string46 ='                          $_.dhcpenabled -eq "true" -and'
$string47 ='                          $_.dhcpleaseobtained } |'
$string48 ='                  select -uniq -first 1 -expandproperty dhcpserver'
$string49 ='}'
if (check-validip $asmapplianceip) {
    $string50 ='$baseurl = "http://' + $asmapplianceip + ':8080/svc"'
} else {
    $string50 ='$baseurl = "http://${server}:8080/svc"'
}
$string51 ='# Figure out our node hardware ID details'
$string52 ='$hwid = get-wmiobject Win32_NetworkAdapter -filter "netenabled=''true''" | '
$string53 ='            select -expandproperty macaddress | '
$string54 ='            foreach-object -begin { $n = 0 } -process { $n++; "net${n}=${_}"; }'
$string55 ='$hwid = $hwid -join ''&'' -replace '':'', ''-'''
$string56 = '# Now, communicate with the server and translate our HWID into a node ID'
$string57 = '# number that we can use for our next step -- accessing our bound'
$string58 = '# installer templates.'
$string59 = 'write-host "contact ${baseurl}/nodeid?${hwid} for ID mapping"'
$string60 = '$data = invoke-restmethod "${baseurl}/nodeid?${hwid}"'
$string61 = '$id = $data.id'
$string62 ='write-host "mapped myself to node ID ${id}"'
$string63 ='# Finally, fetch down our next stage of script and evaluate it.'
$string64 ='$url = "${baseurl}/file/${id}/second-stage.ps1"'
$string65 ='write-host "load and execute ${url}"'
$string66 ='(new-object System.Net.WebClient).DownloadString($url) | invoke-expression'
$string67 ='# ...and done. '
$string68 = 'write-host "second stage completed, exiting."'
$string69 = 'exit'
Write-Host 'Strings created, writing file'
$string1 | Out-File $razorclientloc -Append
$string2 | Out-File $razorclientloc -Append
$string3 | Out-File $razorclientloc -Append
$string4 | Out-File $razorclientloc -Append
$string5 | Out-File $razorclientloc -Append
$string6 | Out-File $razorclientloc -Append
$string7 | Out-File $razorclientloc -Append
$string8 | Out-File $razorclientloc -Append
$string9 | Out-File $razorclientloc -Append
$string10 | Out-File $razorclientloc -Append
$string11 | Out-File $razorclientloc -Append
$string12 | Out-File $razorclientloc -Append
$string13 | Out-File $razorclientloc -Append
$string14 | Out-File $razorclientloc -Append
$string15 | Out-File $razorclientloc -Append
$string16 | Out-File $razorclientloc -Append
$string17 | Out-File $razorclientloc -Append
$string18 | Out-File $razorclientloc -Append
$string19 | Out-File $razorclientloc -Append
$string20 | Out-File $razorclientloc -Append
$string21 | Out-File $razorclientloc -Append
$string22 | Out-File $razorclientloc -Append
$string23 | Out-File $razorclientloc -Append
$string24 | Out-File $razorclientloc -Append
$string25 | Out-File $razorclientloc -Append
$string26 | Out-File $razorclientloc -Append
$string27 | Out-File $razorclientloc -Append
$string28 | Out-File $razorclientloc -Append
$string29 | Out-File $razorclientloc -Append
$string30 | Out-File $razorclientloc -Append
$string31 | Out-File $razorclientloc -Append
$string32 | Out-File $razorclientloc -Append
$string33 | Out-File $razorclientloc -Append
$string34 | Out-File $razorclientloc -Append
$string35 | Out-File $razorclientloc -Append
$string36 | Out-File $razorclientloc -Append
$string37 | Out-File $razorclientloc -Append
$string38 | Out-File $razorclientloc -Append
$string39 | Out-File $razorclientloc -Append
$string40 | Out-File $razorclientloc -Append
$string41 | Out-File $razorclientloc -Append
$string42 | Out-File $razorclientloc -Append
$string43 | Out-File $razorclientloc -Append
$string44 | Out-File $razorclientloc -Append
$string45 | Out-File $razorclientloc -Append
$string46 | Out-File $razorclientloc -Append
$string47 | Out-File $razorclientloc -Append
$string48 | Out-File $razorclientloc -Append
$string49 | Out-File $razorclientloc -Append
$string50 | Out-File $razorclientloc -Append
$string51 | Out-File $razorclientloc -Append
$string52 | Out-File $razorclientloc -Append
$string53 | Out-File $razorclientloc -Append
$string54 | Out-File $razorclientloc -Append
$string55 | Out-File $razorclientloc -Append
$string56 | Out-File $razorclientloc -Append
$string57 | Out-File $razorclientloc -Append
$string58 | Out-File $razorclientloc -Append
$string59 | Out-File $razorclientloc -Append
$string60 | Out-File $razorclientloc -Append
$string61 | Out-File $razorclientloc -Append
$string62 | Out-File $razorclientloc -Append
$string63 | Out-File $razorclientloc -Append
$string64 | Out-File $razorclientloc -Append
$string65 | Out-File $razorclientloc -Append
$string66 | Out-File $razorclientloc -Append
$string67 | Out-File $razorclientloc -Append
$string68 | Out-File $razorclientloc -Append
$string69 | Out-File $razorclientloc -Append

########################################################################
# Some "constants" that might have to change to accommodate different
# versions of the WinPE building tools.  
# Default install root for the ADK; 
$adk = @([Environment]::GetFolderPath('ProgramFilesX86'),
         [Environment]::GetFolderPath('ProgramFiles')) |
           % { join-path $_ 'Windows Kits\8.0\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64' } |
           ? { test-path  $_ } |
           select-object -First 1

if ($adk){
    write-host "*********************************************************"
    write-host "Discovered ADK 8.0, proceeding.  This will take some time"
    write-host "*********************************************************"
    $adkversion = 8.0
} else {
    $adk = @([Environment]::GetFolderPath('ProgramFilesX86'),
         [Environment]::GetFolderPath('ProgramFiles')) |
           % { join-path $_ 'Windows Kits\8.1\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64' } |
           ? { test-path  $_ } |
           select-object -First 1
           $adkversion = 8.1
    if(!$adk) {
        write-error "No ADK found in default location."
        exit 1
    } else {
        write-host "*********************************************************"
        write-host "Discovered ADK 8.1, proceeding.  This will take some time"
        write-host "*********************************************************"
    }
}

# Path to the clean WinPE WIM file.
$wim = join-path $adk "en-us\winpe.wim"

# Root for the CAB files for optional features.
$packages = join-path $adk "WinPE_OCs"

#For windows 2008 we need to add the missing fonts for winpe
$fonts = join-path $adk '\Media\EFI\Microsoft\Boot\Fonts\*'
$fontsdir = Join-Path $windowsdirectory '\boot\fonts'
Copy-Item $fonts $fontsdir -Force

########################################################################
# These are "constants" that are calculated from the above.
write-host "Make sure our working and output directories exist."
if (test-path -path $output) {
    write-error "Output path $output already exists, delete these folders and try again!"
    exit 1
} else {
    new-item -type directory $output
}

if (-not(test-path -path $mount)) {
    new-item -type directory $mount
}


#Copy the clean ADK WinPE image into our output area.
copy-item $wim $output
# Update our wim location...
$wim = join-path $output "winpe.wim"


#Importing dism module"
import-module dism
write-host "*******************************************************"
write-host "Mounting the winpe.wim image, this will take some time."
write-host "*******************************************************"
write-host ""
mount-windowsimage -imagepath $wim -index 1 -path $mount -erroraction stop

write-host "*******************************************************"
write-host "Adding powershell, and dependencies, to the image"
write-host "*******************************************************"
write-host ""
# This order is documented in http://technet.microsoft.com/library/hh824926.aspx
# You cant change it safely. Also cab files differ between 8.0 and 8.1 so we 
# need to choose depending on the ADK version
if($adkversion -eq 8.1) {
@('WinPE-WMI', 'WinPE-NetFX', 'WinPE-Scripting', 'WinPE-PowerShell') | foreach {
    $item = $_
    write-host "installing $item to image"
    $pkg = join-path $packages "$item.cab"
    add-windowspackage -packagepath $pkg -path $mount
    $pkg = join-path $packages "en-us\${item}_en-us.cab"
    add-windowspackage -packagepath $pkg -path $mount
    
}
# Copy bootmgr.exe to root of winpe.wim, this is fix for ADK 8.1 & iPXE
# not supporting compression
#copy-item
  
    $bootmgrsource = Join-Path $mount "Windows\Boot\PXE\bootmgr.exe"
    if(Test-path $bootmgrsource) {
        Copy-Item $bootmgrsource $mount
        Write-Host "Copying bootmgr.exe to output"
        Copy-Item $bootmgrsource $output
    } else {
        Write-host "Bootmgr.exe was not successfully copied."
        Write-host "If using windows 2012 R2, deployment will not succeed."
    }
} else {
@('WinPE-WMI', 'WinPE-NetFX4', 'WinPE-Scripting', 'WinPE-PowerShell3') | foreach {
    $item = $_
    write-host "installing $item to image"
    $pkg = join-path $packages "$item.cab"
    add-windowspackage -packagepath $pkg -path $mount
    $pkg = join-path $packages "en-us\${item}_en-us.cab"
    add-windowspackage -packagepath $pkg -path $mount
}
}

write-host "Adding Drivers to the image"
$drivers  = join-path $cwd "Drivers"
Add-WindowsDriver -Path $mount -Driver "$drivers" -Recurse
Copy-Item $drivers $mount

write-host "Adding PowerShell cmdlets to the image"
@('WinPE-StorageWMI', 'WinPE-DismCmdlets') |foreach {
    $item = $_
    $pkg = join-path $packages "$item.cab"
    Add-WindowsPackage -PackagePath $pkg -path $mount
    $pkg = join-path $packages "en-us\${item}_en-us.cab"
    add-windowspackage -packagepath $pkg -path $mount
}

write-host "Writing razor-client.ps1 startup PowerShell script to Winpe.wim"
$file   = join-path $mount "razor-client.ps1"
$client = join-path $cwd "razor-client.ps1"
copy-item $client $file

write-host "Writing Windows\System32\startnet.cmd script"
$file = join-path $mount "Windows\System32\startnet.cmd"
set-content $file @'
@echo off
echo starting wpeinit to detect and boot network hardware
wpeinit
echo starting the razor client
powershell -executionpolicy bypass -noninteractive -file %SYSTEMDRIVE%\razor-client.ps1
echo dropping to a command shell now...
'@
write-host "*******************************************************"
write-host "Unmounting and saving the Winpe.wim image"
write-host "*******************************************************"
write-host ""
dismount-windowsimage -save -path $mount -erroraction stop
write-host "*******************************************************"
write-host "Winpe is ready, trying to process boot.wim and install.wim if they exist."
write-host "*******************************************************"

#need to add VMXNET3 drivers to boot.wim and install.wim
#copy boot.wim to the output area
    write-host "Starting to work with boot.wim and install.wim"
    $bootwimsource = Join-Path $cwd "boot.wim"
    $installwimsource = Join-Path $cwd "install.wim"

#test boot.wim and install.wim path and exit if not null
    if(-not(Test-path $bootwimsource)) {
        Write-host "No Windows boot.wim or install.wim files present, exiting"
        Write-host "Refer to the documentation for additional files required for processing"
        exit 1
    } else {
        if(-not(Test-path $installwimsource)) {
            Write-host "No Windows boot.wim or install.wim files present, exiting."
            Write-host "Refer to the documentation for additional files required for processing"
            exit 1
        }
    }

    if($bootwimsource) {
        Copy-Item $bootwimsource $output
        $wim = join-path $output "boot.wim"
#mount boot.wim
        write-host "mounting the wim image at the following path"
        Write-Host $wim
        mount-windowsimage -imagepath $wim -index 2 -path $mount -erroraction stop
#install driver
        Add-WindowsDriver -Path $mount -Driver "$drivers" -Recurse
#unmount boot.wim
        dismount-windowsimage -save -path $mount -erroraction stop
     }
     else {
        Write-Host "no bootwim source"
     }
#copy install.wim to the output area
    if($installwimsource){
        Copy-Item $installwimsource $output
#repeat injecting the drivers for each image in the install.wim
#right now we assume 4, but we need to programmatically figure this
#out probably
        $wim = join-path $output "install.wim"
        Get-WindowsImage -ImagePath $wim| foreach {
            $image = $_."ImageName"
            write-host "mounting $wim image $image at $mount"
            Write-Host $wim
            mount-windowsimage -imagepath $wim -name $image -path $mount -erroraction stop
#install driver
            Add-WindowsDriver -Path $mount -Driver "$drivers" -Recurse
#unmount boot.wim
            dismount-windowsimage -save -path $mount -erroraction stop
            Write-Host "unmounted $wim image $image" 
        }
    } else {
        Write-Host "no installwim source"
    }

Clear-WindowsCorruptMountPoint
#Copy our updated boot.wim, install.wim, winpe.wim, and bootmgr.exe to image
$originalpe = $cwd + "\razor-winpe\winpe.wim"
$razorpe = $cwd + "\razor-winpe\razor-winpe.wim"
$finalbootwimdir = $cwd + "\razor-winpe\boot.wim"
$finalinstallwimdir = $cwd + "\razor-winpe\install.wim"
$bootmgrdir = $cwd + "\razor-winpe\bootmgr.exe"
Rename-Item $originalpe $razorpe
Copy-Item $finalbootwimdir $bootwimloc
Copy-Item $finalinstallwimdir $installwimloc
Copy-Item $razorpe $windowsdirectory
Copy-Item $bootmgrdir $windowsdirectory

#Build a new .iso
#Todo, test name and have a default .iso name
$newisodirectory = $cwd + '\' + $finalisoname
$oscdimgloc = 'C:\Program Files (x86)\Windows Kits\8.1\Assessment and Deployment Kit\Deployment Tools\amd64\oscdimg\oscdimg.exe'
$arg1 = '-m'
$arg2 = '-h'
$arg3 = '-o'
$arg4 = '-u2'
$arg5 = '-udfver102'
$arg6 = '-l<Windows>'
$arg7 = '-bootdata:2#p0,e,b"' + $windowsdirectory + '\boot\ETFSBOOT.COM"#pEF,e,b"' + $windowsdirectory + '\efi\microsoft\boot\efisys.bin"' 
Write-Host "*************************"
Write-Host "Calling OSCDCMD: " + $oscdimgloc
& $oscdimgloc $arg1 $arg2 $arg3 $arg4 $arg5 $arg6 $arg7 $windowsdirectory $newisodirectory

#Cleanup unneeded files
Write-Host 'Deleting files no longer needed.'
Remove-Item $output -recurse
Remove-Item $mount -recurse
Remove-Item $razorclientloc
$Files = Get-ChildItem $windowsdirectory -Recurse
ForEach ($File in $Files) 
{
      if ($File.IsReadOnly -eq $true )
      {
          try  
          {
               Set-ItemProperty -path $File.FullName -name IsReadOnly -value $false 
          }
          catch [Exception] 
          { 
               Write-Host "Error at file " $Path "\" $File 
               Write-Host $_.Exception.Message
          }
      } 
}
Remove-Item $windowsdirectory -Recurse
$bootwimloc = $cwd + '\boot.wim'
$installwimloc = $cwd + '\install.wim'
Remove-Item $bootwimloc
Remove-Item $installwimloc

#Unmount customer's .iso
Write-host 'Unmounting customer windows .iso'
Dismount-DiskImage -ImagePath $userisoloc



           

