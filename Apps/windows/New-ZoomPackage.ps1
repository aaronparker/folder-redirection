#Requires -Modules Evergreen, IntuneWin32App, PSIntuneAuth, AzureAD
<#
    .SYNOPSIS
        Packages the latest Zoom for Intune deployment.
        Uploads the mew package into the target Intune tenant.

    .NOTES
        For details on IntuneWin32App go here: https://github.com/MSEndpointMgr/IntuneWin32App/blob/master/README.md
        For details on Evergreen go here: https://stealthpuppy.com/Evergreen
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $False)]
    [System.String] $Path = "C:\Temp\Zoom",

    [Parameter(Mandatory = $False)]
    [System.String] $ScriptName = "Install-Zoom.ps1",

    [Parameter(Mandatory = $False)]
    [System.String] $TenantName = "stealthpuppylab.onmicrosoft.com",

    [Parameter(Mandatory = $False)]
    [System.Management.Automation.SwitchParameter] $Upload
)

#region Check if token has expired and if, request a new
Write-Information -MessageData "Checking for existing authentication token."
If ($Null -ne $Global:AuthToken) {
    $UtcDateTime = (Get-Date).ToUniversalTime()
    $TokenExpireMins = ($Global:AuthToken.ExpiresOn.DateTime - $UtcDateTime).Minutes
    Write-Warning -Message "Current authentication token expires in (minutes): $($TokenExpireMins)"

    If ($TokenExpireMins -le 0) {
        Write-Information -MessageData "Existing token found but has expired, requesting a new token."
        $Global:AuthToken = Get-MSIntuneAuthToken -TenantName $TenantName
    }
    Else {
        Write-Information -MessageData "Existing authentication token has not expired, will not request a new token."
    }        
}
Else {
    Write-Information -MessageData "Authentication token does not exist, requesting a new token."
    $Global:AuthToken = Get-MSIntuneAuthToken -TenantName $TenantName -PromptBehavior "Auto"
}
#endregion


#region Variables
Write-Information -MessageData "Getting Zoom version via Evergreen."
$ProgressPreference = "SilentlyContinue"
$InformationPreference = "Continue"
$Package = Get-Zoom | Where-Object { $_.Type -eq "Msi" -and $_.Platform -eq "Windows" } | Select-Object -First 1
$IconSource = "https://raw.githubusercontent.com/Insentra/intune-icons/main/icons/Zoom.png"
$Win32Wrapper = "https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/master/IntuneWinAppUtil.exe"

# Variables for the package
$Description = "Simplified video conferencing and messaging across any device."
$ProductCode = "{9A0F6468-2A0B-4E6A-B212-40C55E9B4B4B}"
$Publisher = "Zoom Video Communications, Inc."
$ProductName = "Zoom Client for Meetings"
$DisplayName = $ProductName + " " + $Package.Version
$Executable = Split-Path -Path $Package.URI -Leaf

#$InstallCommandLine = "C:\windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File .\$ScriptName"
$InstallCommandLine = "msiexec /i $Executable /quiet /norestart ALLUSERS=1" 
$UninstallCommandLine = "msiexec.exe /X $ProductCode /QN-"

$AppPath = "${env:ProgramFiles(x86)}\Zoom\bin"
$AppExecutable = "Zoom.exe"
$InformationURL = "https://explore.zoom.us/meetings"
$PrivacyURL = "https://explore.zoom.us/legal"
#endregion


# Download installer with Evergreen
If ($Package) {

    # Create the package folder
    $PackagePath = Join-Path -Path $Path -ChildPath "Package"
    Write-Information -MessageData "Check path: $PackagePath."
    If (!(Test-Path -Path $PackagePath)) { New-Item -Path $PackagePath -ItemType "Directory" -Force -ErrorAction "SilentlyContinue" > $Null }

    #region Download files and setup the package        
    # Download the Remote Desktop installer
    $OutFile = Join-Path -Path $PackagePath -ChildPath $Executable

    Write-Information -MessageData "Installer target: $OutFile."
    If (Test-Path -Path $OutFile) {
        Write-Information -MessageData "File exists: $OutFile."
    }
    Else {
        Write-Information -MessageData "Downloading to: $OutFile."
        try {
            Invoke-WebRequest -Uri $Package.Uri -OutFile $OutFile -UseBasicParsing
            If (Test-Path -Path $OutFile) { Write-Information -MessageData "Downloaded: $OutFile." }
        }
        catch [System.Exception] {
            Write-Warning -Message "Failed to download Remote Desktop installer with: $($_.Exception.Message)"
            Break
        }
    }
    #endregion


    #region Package the app
    # Download the Intune Win32 wrapper
    $wrapperBin = Join-Path -Path $Path -ChildPath (Split-Path -Path $Win32Wrapper -Leaf)
    try {
        Invoke-WebRequest -Uri $Win32Wrapper -OutFile $wrapperBin -UseBasicParsing
    }
    catch [System.Exception] {
        Write-Warning -Message "Failed to Microsoft Win32 Content Prep Tool with: $($_.Exception.Message)"
        Break
    }

    # Create the package
    try {
        $PackageOutput = Join-Path -Path $Path -ChildPath "Output"
        Start-Process -FilePath $wrapperBin -ArgumentList "-c $PackagePath -s $Executable -o $PackageOutput -q" -Wait -NoNewWindow
    }
    catch [System.Exception] {
        Write-Warning -Message "Failed to convert to an Intunewin package with: $($_.Exception.Message)"
        Break
    }
    try {
        $IntuneWinFile = Get-ChildItem -Path $PackageOutput -Filter "*.intunewin" -ErrorAction "SilentlyContinue"
    }
    catch {
        Write-Warning -Message "Failed to find an Intunewin package in $PackageOutput with: $($_.Exception.Message)"
        Break
    }
    Write-Information -MessageData "Found package: $($IntuneWinFile.FullName)."
    #endregion


    #region Upload intunewin file and create the Intune app
    # Convert image file to icon
    $ImageFile = (Join-Path -Path $Path -ChildPath (Split-Path -Path $IconSource -Leaf))
    try {
        Invoke-WebRequest -Uri $IconSource -OutFile $ImageFile -UseBasicParsing
    }
    catch [System.Exception] {
        Write-Warning -Message "Failed to download: $IconSource with: $($_.Exception.Message)"
        Break
    }
    If (Test-Path -Path $ImageFile) {
        $Icon = New-IntuneWin32AppIcon -FilePath $ImageFile
    }
    Else {
        Write-Warning -Message "Cannot find the icon file."
        Break
    }

    # Create detection rule using the en-US MSI product code
    If ($ProductCode -and $Package.Version) {
        $params = @{
            ProductCode            = $ProductCode
            #ProductVersionOperator = "greaterThanOrEqual"
            #ProductVersion         = $Package.Version
        }
        $DetectionRule1 = New-IntuneWin32AppDetectionRuleMSI @params
    }
    Else {
        Write-Warning -Message "Cannot create the detection rule - check ProductCode and version number."
        Write-Information -MessageData "ProductCode: $ProductCode."
        Write-Information -MessageData "Version: $($Package.Version)."
        Break
    }
    If ($AppPath -and $AppExecutable) {
        $params = @{
            Version              = $True
            Path                 = $AppPath
            FileOrFolder         = $AppExecutable
            Check32BitOn64System = $False 
            Operator             = "greaterThanOrEqual"
            VersionValue         = $Package.Version
        }
        $DetectionRule2 = New-IntuneWin32AppDetectionRuleFile @params
    }
    Else {
        Write-Warning -Message "Cannot create the detection rule - check application path and executable."
        Write-Information -MessageData "Path: $AppPath."
        Write-Information -MessageData "Exe: $AppExecutable."
        Break
    }
    If ($DetectionRule1 -and $DetectionRule2) {
        $DetectionRule = @($DetectionRule1, $DetectionRule2)
    }
    Else {
        Write-Information -MessageData "Failed to create the detection rule."
        Break
    }
    
    # Create custom requirement rule
    $params = @{
        Architecture                    = "All"
        MinimumSupportedOperatingSystem = "1607"
    }
    $RequirementRule = New-IntuneWin32AppRequirementRule @params

    # Add new EXE Win32 app
    # Requires a connection via Connect-MSIntuneGraph first
    If ($PSBoundParameters.Keys.Contains("Upload")) {
        try {
            $params = @{
                FilePath                 = $IntuneWinFile.FullName
                DisplayName              = $DisplayName
                Description              = $Description
                Publisher                = $Publisher
                InformationURL           = $InformationURL
                PrivacyURL               = $PrivacyURL
                CompanyPortalFeaturedApp = $false
                InstallExperience        = "system"
                RestartBehavior          = "suppress"
                DetectionRule            = $DetectionRule
                RequirementRule          = $RequirementRule
                InstallCommandLine       = $InstallCommandLine
                UninstallCommandLine     = $UninstallCommandLine
                Icon                     = $Icon
                Verbose                  = $true
            }
            $App = Add-IntuneWin32App @params
        }
        catch [System.Exception] {
            Write-Warning -Message "Failed to create application: $DisplayName with: $($_.Exception.Message)"
            Break
        }

        # Create an available assignment for all users
        If ($Null -ne $App) {
            try {
                $params = @{
                    Id                           = $App.Id
                    Intent                       = "available"
                    Notification                 = "showAll"
                    DeliveryOptimizationPriority = "foreground"
                    #AvailableTime                = ""
                    #DeadlineTime                 = ""
                    #UseLocalTime                 = $true
                    #EnableRestartGracePeriod     = $true
                    #RestartGracePeriod           = 360
                    #RestartCountDownDisplay      = 20
                    #RestartNotificationSnooze    = 60
                    Verbose                      = $true
                }
                Add-IntuneWin32AppAssignmentAllUsers @params
            }
            catch [System.Exception] {
                Write-Warning -Message "Failed to add assignment to $($App.displayName) with: $($_.Exception.Message)"
                Break
            }
        }
    }
    Else {
        Write-Host -Object "Parameter -Upload not specified. Skipping upload to Intune."
    }
    #endregion
}
Else {
    Write-Information -MessageData "Failed to retrieve Microsoft Remote Desktop package via Evergreen."
}
