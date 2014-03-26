# -*- powershell -*-
# To run this script:
# powershell -executionpolicy bypass -file build-razor-winpe.ps1
#


function test-administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function get-currentdirectory {
    $thisName = $MyInvocation.MyCommand.Name
    [IO.Path]::GetDirectoryName((Get-Content function:$thisName).File)
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


# Basic location stuff...
$cwd    = get-currentdirectory
$output = join-path $cwd "razor-winpe"
$mount  = join-path $cwd "razor-winpe-mount"
$adkversion = 0.0


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
# You can’t change it safely. Also cab files differ between 8.0 and 8.1 so we 
# need to choose depending on the ADK version
if($adkversion -eq 8.1) {
@('WinPE-WMI', 'WinPE-NetFX', 'WinPE-Scripting', 'WinPE-PowerShell') | foreach {
    write-host "installing $_ to image"
    $pkg = join-path $packages "$_.cab"
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
    write-host "installing $_ to image"
    $pkg = join-path $packages "$_.cab"
    add-windowspackage -packagepath $pkg -path $mount
}
}

write-host "Adding Drivers to the image"
$drivers  = join-path $cwd "Drivers"
Add-WindowsDriver -Path $mount -Driver "$drivers" -Recurse
Copy-Item $drivers $mount

write-host "Adding dism to the image"
$pkg = join-path $packages "WinPE-DismCmdlets.cab"
if(Test-Path $pkg) {
    Add-WindowsPackage -PackagePath $pkg -path $mount
    write-host "Successfully added dism to winpe"
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
        @(1,2,3,4) | foreach {
            Copy-Item $installwimsource $output
            $wim = join-path $output "install.wim"
#mount boot.wim
            write-host "mounting the wim image, index $_ at the following path"
            Write-Host $wim
            mount-windowsimage -imagepath $wim -index $_ -path $mount -erroraction stop
#install driver
            Add-WindowsDriver -Path $mount -Driver "$drivers" -Recurse
#unmount boot.wim
            dismount-windowsimage -save -path $mount -erroraction stop
            Write-Host "Image unmounteded at index: $_" 
        }
    } else {
        Write-Host "no installwim source"
    }

Clear-WindowsCorruptMountPoint