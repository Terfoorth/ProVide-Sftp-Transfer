param(
    [Parameter(Mandatory = $true)]
    [string]$LocalPath,

    [string]$FtpPath = "",
    [string]$UserName = "",
    [string]$ClientIp = "",
    [string]$EventName = "OnUploadEnd",
    [string]$ConfigPath = "C:\ProgramData\ProVideTransfer\transfer-config.json"
)

$ErrorActionPreference = "Stop"

function Get-ConfigValue {
    param(
        [object]$Config,
        [string]$Name,
        [object]$DefaultValue
    )

    if ($null -ne $Config -and $null -ne $Config.PSObject.Properties[$Name] -and $null -ne $Config.$Name) {
        return $Config.$Name
    }

    return $DefaultValue
}

function Read-TransferConfig {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }

    return [pscustomobject]@{
        StateRoot = "C:\ProgramData\ProVideTransfer"
        InboundRoot = "C:\Users\Public\sftp_file_upload_root"
        InboundFolderName = "in"
        OutboundFolderName = "out"
        IgnoredPatterns = @("*.filepart", "*.partial", "*.tmp")
    }
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 10
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
}

function Add-AuditEntry {
    param(
        [string]$StateRoot,
        [object]$Entry
    )

    $logDir = Join-Path $StateRoot "logs"
    Ensure-Directory $logDir
    $logPath = Join-Path $logDir ("transfer-status-{0}.jsonl" -f (Get-Date -Format "yyyy-MM-dd"))
    $line = ($Entry | ConvertTo-Json -Depth 8 -Compress)
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Test-PatternList {
    param(
        [string]$Path,
        [object[]]$Patterns
    )

    $fileName = [System.IO.Path]::GetFileName($Path)
    foreach ($pattern in $Patterns) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pattern) -and $fileName -like [string]$pattern) {
            return $true
        }
    }

    return $false
}

function Get-InboundPathInfo {
    param(
        [string]$Path,
        [object]$Config
    )

    $inboundRoot = [string](Get-ConfigValue -Config $Config -Name "InboundRoot" -DefaultValue "C:\Users\Public\sftp_file_upload_root")
    $inboundFolder = [string](Get-ConfigValue -Config $Config -Name "InboundFolderName" -DefaultValue "in")
    $outboundFolder = [string](Get-ConfigValue -Config $Config -Name "OutboundFolderName" -DefaultValue "out")
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($inboundRoot).TrimEnd('\')

    if (-not $fullPath.StartsWith($fullRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsInbound = $false; Customer = ""; InputSubfolder = ""; Reason = "Source path is outside InboundRoot." }
    }

    $relative = $fullPath.Substring($fullRoot.Length + 1)
    $parts = $relative -split "[\\/]"
    if ($parts.Count -lt 3) {
        return [pscustomobject]@{ IsInbound = $false; Customer = ""; InputSubfolder = ""; Reason = "Source path is not under a customer inbound folder." }
    }

    if ($parts[1].Equals($outboundFolder, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsInbound = $false; Customer = $parts[0]; InputSubfolder = ""; Reason = "Outbound folder is not processed." }
    }

    if (-not $parts[1].Equals($inboundFolder, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsInbound = $false; Customer = $parts[0]; InputSubfolder = ""; Reason = "Source path is not under the inbound folder." }
    }

    $inputSubfolder = ""
    if ($parts.Count -gt 3) {
        $inputSubfolder = [string]::Join("\", $parts[2..($parts.Count - 2)])
    }

    return [pscustomobject]@{ IsInbound = $true; Customer = $parts[0]; InputSubfolder = $inputSubfolder; Reason = "" }
}

try {
    $config = Read-TransferConfig -Path $ConfigPath
    $stateRoot = [string](Get-ConfigValue -Config $config -Name "StateRoot" -DefaultValue "C:\ProgramData\ProVideTransfer")
    if ([string]::IsNullOrWhiteSpace($stateRoot)) {
        $stateRoot = "C:\ProgramData\ProVideTransfer"
    }

    $queueDir = Join-Path $stateRoot "queue"
    Ensure-Directory $queueDir
    Ensure-Directory (Join-Path $stateRoot "logs")

    $now = [DateTimeOffset]::UtcNow
    $fullLocalPath = [System.IO.Path]::GetFullPath($LocalPath)
    $ignoredPatterns = @(Get-ConfigValue -Config $config -Name "IgnoredPatterns" -DefaultValue @("*.filepart", "*.partial", "*.tmp"))
    $pathInfo = Get-InboundPathInfo -Path $fullLocalPath -Config $config

    if (Test-PatternList -Path $fullLocalPath -Patterns $ignoredPatterns) {
        Add-AuditEntry -StateRoot $stateRoot -Entry ([ordered]@{
            Id = ""
            Status = "Ignored"
            LocalPath = $fullLocalPath
            FtpPath = $FtpPath
            UserName = $UserName
            Customer = $pathInfo.Customer
            EventName = $EventName
            Timestamp = $now.ToString("o")
            Message = "Upload event ignored because the file matches IgnoredPatterns."
        })
        exit 0
    }

    if (-not $pathInfo.IsInbound) {
        Add-AuditEntry -StateRoot $stateRoot -Entry ([ordered]@{
            Id = ""
            Status = "Ignored"
            LocalPath = $fullLocalPath
            FtpPath = $FtpPath
            UserName = $UserName
            Customer = $pathInfo.Customer
            EventName = $EventName
            Timestamp = $now.ToString("o")
            Message = $pathInfo.Reason
        })
        exit 0
    }

    $id = [guid]::NewGuid().ToString("N")
    $customer = if ([string]::IsNullOrWhiteSpace($UserName)) { [string]$pathInfo.Customer } else { $UserName.Trim() }

    $job = [ordered]@{
        Id = $id
        Status = "Queued"
        LocalPath = $fullLocalPath
        FtpPath = $FtpPath
        UserName = $UserName
        Customer = $customer
        ClientIp = $ClientIp
        EventName = $EventName
        CreatedAt = $now.ToString("o")
        UpdatedAt = $now.ToString("o")
        NextAttemptAt = $now.ToString("o")
        AttemptCount = 0
        Source = "OnUploadEnd"
        LastError = ""
        ErrorCategory = ""
        LockedSince = ""
        CompletedAt = ""
        InputSubfolder = [string]$pathInfo.InputSubfolder
        RouteName = ""
        DestinationPath = ""
        PartialPath = ""
        ArchivePath = ""
        SourceLength = $null
        DestinationLength = $null
        SourceHash = ""
        DestinationHash = ""
    }

    $fileName = "{0}_{1}.json" -f (Get-Date -Format "yyyyMMddHHmmssfff"), $id
    $tmpPath = Join-Path $queueDir ($fileName + ".tmp")
    $jobPath = Join-Path $queueDir $fileName
    Write-JsonFile -Path $tmpPath -Value $job
    Move-Item -LiteralPath $tmpPath -Destination $jobPath

    Add-AuditEntry -StateRoot $stateRoot -Entry ([ordered]@{
        Id = $id
        Status = "Queued"
        LocalPath = $fullLocalPath
        FtpPath = $FtpPath
        UserName = $UserName
        Customer = $customer
        EventName = $EventName
        Timestamp = $now.ToString("o")
        Message = "Upload job queued from ProVide event."
    })

    exit 0
}
catch {
    try {
        $fallbackRoot = "C:\ProgramData\ProVideTransfer"
        Ensure-Directory (Join-Path $fallbackRoot "logs")
        $message = "{0} enqueue-upload failed: {1}" -f ([DateTimeOffset]::UtcNow.ToString("o")), $_.Exception.Message
        Add-Content -LiteralPath (Join-Path $fallbackRoot "logs\enqueue-errors.log") -Value $message -Encoding UTF8
    }
    catch {
    }

    exit 0
}
