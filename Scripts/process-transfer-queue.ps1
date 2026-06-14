param(
    [switch]$RunOnce,
    [string]$ConfigPath = "C:\ProgramData\ProVideTransfer\transfer-config.json"
)

$ErrorActionPreference = "Stop"

function Get-ObjectValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue
    )

    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) {
        return $Object.$Name
    }

    return $DefaultValue
}

function Set-ObjectValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    if ($null -ne $Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
        return
    }

    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Read-TransferConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
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

    $json = $Value | ConvertTo-Json -Depth 12
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
}

function Normalize-Job {
    param([object]$Job)

    $now = [DateTimeOffset]::UtcNow.ToString("o")
    foreach ($pair in @(
        @{ Name = "NextAttemptAt"; Value = $now },
        @{ Name = "ErrorCategory"; Value = "" },
        @{ Name = "LockedSince"; Value = "" },
        @{ Name = "CompletedAt"; Value = "" },
        @{ Name = "InputSubfolder"; Value = "" },
        @{ Name = "RouteName"; Value = "" },
        @{ Name = "PartialPath"; Value = "" }
    )) {
        if ($null -eq $Job.PSObject.Properties[$pair.Name]) {
            Set-ObjectValue -Object $Job -Name $pair.Name -Value $pair.Value
        }
    }
}

function Add-AuditEntry {
    param(
        [object]$Config,
        [object]$Job,
        [string]$Status,
        [string]$Message
    )

    $logDir = Join-Path $Config.StateRoot "logs"
    Ensure-Directory $logDir
    $logPath = Join-Path $logDir ("transfer-status-{0}.jsonl" -f (Get-Date -Format "yyyy-MM-dd"))
    $entry = [ordered]@{
        Id = Get-ObjectValue -Object $Job -Name "Id" -DefaultValue ""
        Status = $Status
        LocalPath = Get-ObjectValue -Object $Job -Name "LocalPath" -DefaultValue ""
        FtpPath = Get-ObjectValue -Object $Job -Name "FtpPath" -DefaultValue ""
        UserName = Get-ObjectValue -Object $Job -Name "UserName" -DefaultValue ""
        Customer = Get-ObjectValue -Object $Job -Name "Customer" -DefaultValue ""
        InputSubfolder = Get-ObjectValue -Object $Job -Name "InputSubfolder" -DefaultValue ""
        RouteName = Get-ObjectValue -Object $Job -Name "RouteName" -DefaultValue ""
        DestinationPath = Get-ObjectValue -Object $Job -Name "DestinationPath" -DefaultValue ""
        PartialPath = Get-ObjectValue -Object $Job -Name "PartialPath" -DefaultValue ""
        ArchivePath = Get-ObjectValue -Object $Job -Name "ArchivePath" -DefaultValue ""
        AttemptCount = Get-ObjectValue -Object $Job -Name "AttemptCount" -DefaultValue 0
        NextAttemptAt = Get-ObjectValue -Object $Job -Name "NextAttemptAt" -DefaultValue ""
        ErrorCategory = Get-ObjectValue -Object $Job -Name "ErrorCategory" -DefaultValue ""
        LockedSince = Get-ObjectValue -Object $Job -Name "LockedSince" -DefaultValue ""
        Timestamp = ([DateTimeOffset]::UtcNow.ToString("o"))
        Message = $Message
        LastError = Get-ObjectValue -Object $Job -Name "LastError" -DefaultValue ""
    }
    Add-Content -LiteralPath $logPath -Value ($entry | ConvertTo-Json -Depth 10 -Compress) -Encoding UTF8
}

function Update-Job {
    param(
        [object]$Job,
        [string]$Status,
        [string]$Message = "",
        [string]$ErrorCategory = ""
    )

    Set-ObjectValue -Object $Job -Name "Status" -Value $Status
    Set-ObjectValue -Object $Job -Name "UpdatedAt" -Value ([DateTimeOffset]::UtcNow.ToString("o"))

    if ($Status -in @("Archived", "Ignored")) {
        Set-ObjectValue -Object $Job -Name "LastError" -Value ""
        Set-ObjectValue -Object $Job -Name "ErrorCategory" -Value ""
        Set-ObjectValue -Object $Job -Name "CompletedAt" -Value ([DateTimeOffset]::UtcNow.ToString("o"))
        return
    }

    if ($Message) {
        Set-ObjectValue -Object $Job -Name "LastError" -Value $Message
    }

    if ($ErrorCategory) {
        Set-ObjectValue -Object $Job -Name "ErrorCategory" -Value $ErrorCategory
    }

    if ($Status -eq "Failed") {
        Set-ObjectValue -Object $Job -Name "CompletedAt" -Value ([DateTimeOffset]::UtcNow.ToString("o"))
    }
}

function Test-PatternList {
    param(
        [string]$Path,
        [object[]]$Patterns
    )

    $fileName = [System.IO.Path]::GetFileName($Path)
    foreach ($pattern in @($Patterns)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pattern) -and $fileName -like [string]$pattern) {
            return $true
        }
    }

    return $false
}

function Test-PathUnderRoot {
    param(
        [string]$Path,
        [object[]]$Roots
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    foreach ($root in @($Roots)) {
        if ([string]::IsNullOrWhiteSpace([string]$root)) {
            continue
        }

        $fullRoot = [System.IO.Path]::GetFullPath([string]$root).TrimEnd('\')
        if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        if ($fullPath.StartsWith($fullRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
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

    $inboundRoot = [string](Get-ObjectValue -Object $Config -Name "InboundRoot" -DefaultValue "C:\Users\Public\sftp_file_upload_root")
    $inboundFolder = [string](Get-ObjectValue -Object $Config -Name "InboundFolderName" -DefaultValue "in")
    $outboundFolder = [string](Get-ObjectValue -Object $Config -Name "OutboundFolderName" -DefaultValue "out")
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

function Resolve-Customer {
    param(
        [object]$Job,
        [object]$Config
    )

    if (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectValue -Object $Job -Name "Customer" -DefaultValue "")) -and [string](Get-ObjectValue -Object $Job -Name "Customer" -DefaultValue "") -ne "Unknown") {
        return [string](Get-ObjectValue -Object $Job -Name "Customer" -DefaultValue "")
    }

    if (-not [string]::IsNullOrWhiteSpace([string](Get-ObjectValue -Object $Job -Name "UserName" -DefaultValue ""))) {
        return [string](Get-ObjectValue -Object $Job -Name "UserName" -DefaultValue "")
    }

    $info = Get-InboundPathInfo -Path ([string](Get-ObjectValue -Object $Job -Name "LocalPath" -DefaultValue "")) -Config $Config
    if (-not [string]::IsNullOrWhiteSpace([string]$info.Customer)) {
        return [string]$info.Customer
    }

    return "Unknown"
}

function Convert-HashBytesToString {
    param([byte[]]$Bytes)

    return ([BitConverter]::ToString($Bytes)).Replace("-", "")
}

function Get-FileHashValue {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-UniquePath {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Path
    }

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)
    $stamp = Get-Date -Format "yyyyMMddHHmmssfff"
    return Join-Path $directory ("{0}_{1}_{2}{3}" -f $name, $stamp, ([guid]::NewGuid().ToString("N").Substring(0, 8)), $extension)
}

function Expand-PathTemplate {
    param(
        [string]$Template,
        [object]$Job,
        [string]$SourcePath
    )

    $fileName = [System.IO.Path]::GetFileName($SourcePath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $extension = [System.IO.Path]::GetExtension($SourcePath)
    $customer = [string](Get-ObjectValue -Object $Job -Name "Customer" -DefaultValue "")
    $inputSubfolder = [string](Get-ObjectValue -Object $Job -Name "InputSubfolder" -DefaultValue "")

    $result = $Template
    $result = $result.Replace("%USER%", $customer)
    $result = $result.Replace("%CUSTOMER%", $customer)
    $result = $result.Replace("%FILENAME%", $fileName)
    $result = $result.Replace("%BASENAME%", $baseName)
    $result = $result.Replace("%EXTENSION%", $extension)
    $result = $result.Replace("%INPUTSUBFOLDER%", $inputSubfolder)
    $result = $result.Replace("%DATE%", (Get-Date -Format "yyyyMMdd"))

    while ($result -match "%DATE:([^%]+)%") {
        $format = $Matches[1]
        $result = $result.Replace($Matches[0], (Get-Date -Format $format))
    }

    return $result
}

function Resolve-Route {
    param(
        [object]$Config,
        [object]$Job
    )

    $sourcePath = [string](Get-ObjectValue -Object $Job -Name "LocalPath" -DefaultValue "")
    $customer = [string](Get-ObjectValue -Object $Job -Name "Customer" -DefaultValue "")
    $rules = @(Get-ObjectValue -Object $Config -Name "RouteRules" -DefaultValue @())
    $matchedRule = $null

    foreach ($rule in $rules) {
        $ruleCustomer = [string](Get-ObjectValue -Object $rule -Name "Customer" -DefaultValue "")
        if (-not [string]::IsNullOrWhiteSpace($ruleCustomer) -and -not $ruleCustomer.Equals($customer, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $patterns = @(Get-ObjectValue -Object $rule -Name "Patterns" -DefaultValue @())
        $singlePattern = [string](Get-ObjectValue -Object $rule -Name "Pattern" -DefaultValue "")
        if (-not [string]::IsNullOrWhiteSpace($singlePattern)) {
            $patterns += $singlePattern
        }

        if ($patterns.Count -gt 0 -and -not (Test-PatternList -Path $sourcePath -Patterns $patterns)) {
            continue
        }

        $matchedRule = $rule
        break
    }

    $routeName = "Default"
    $destinationPathTemplate = ""
    $destinationRoot = [string](Get-ObjectValue -Object $Config -Name "DestinationRoot" -DefaultValue "")
    $destinationSubdirectory = ""
    $appendCustomer = $true

    if ($null -ne $matchedRule) {
        $routeName = [string](Get-ObjectValue -Object $matchedRule -Name "Name" -DefaultValue "Rule")
        $destinationPathTemplate = [string](Get-ObjectValue -Object $matchedRule -Name "DestinationPath" -DefaultValue "")
        $destinationRoot = [string](Get-ObjectValue -Object $matchedRule -Name "DestinationRoot" -DefaultValue $destinationRoot)
        $destinationSubdirectory = [string](Get-ObjectValue -Object $matchedRule -Name "DestinationSubdirectory" -DefaultValue "")
        $appendCustomer = [bool](Get-ObjectValue -Object $matchedRule -Name "AppendCustomer" -DefaultValue $true)
    }

    $fileName = [System.IO.Path]::GetFileName($sourcePath)
    if (-not [string]::IsNullOrWhiteSpace($destinationPathTemplate)) {
        $expanded = Expand-PathTemplate -Template $destinationPathTemplate -Job $Job -SourcePath $sourcePath
        $templateHasFileToken = $destinationPathTemplate -match "%(FILENAME|BASENAME|EXTENSION)%"
        if ($templateHasFileToken -and -not $expanded.EndsWith("\") -and -not $expanded.EndsWith("/")) {
            return [pscustomobject]@{ Name = $routeName; DestinationPath = [System.IO.Path]::GetFullPath($expanded) }
        }

        return [pscustomobject]@{ Name = $routeName; DestinationPath = [System.IO.Path]::GetFullPath((Join-Path $expanded $fileName)) }
    }

    if ([string]::IsNullOrWhiteSpace($destinationRoot)) {
        throw "DestinationRoot is required."
    }

    $destinationDir = Expand-PathTemplate -Template $destinationRoot -Job $Job -SourcePath $sourcePath
    if ($appendCustomer) {
        $destinationDir = Join-Path $destinationDir $customer
    }

    if (-not [string]::IsNullOrWhiteSpace($destinationSubdirectory)) {
        $destinationDir = Join-Path $destinationDir (Expand-PathTemplate -Template $destinationSubdirectory -Job $Job -SourcePath $sourcePath)
    }

    return [pscustomobject]@{ Name = $routeName; DestinationPath = [System.IO.Path]::GetFullPath((Join-Path $destinationDir $fileName)) }
}

function Test-TransientFileAccessException {
    param([System.Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.UnauthorizedAccessException]) {
            return $true
        }

        if ($current -is [System.IO.IOException]) {
            $hresult = $current.HResult
            if ($hresult -in @(-2147024864, -2147024863, -2147024891)) {
                return $true
            }

            $message = $current.Message
            if ($message -match "being used by another process|used by another process|sharing violation|lock violation|Zugriff verweigert|process cannot access|gesperrt") {
                return $true
            }
        }

        $current = $current.InnerException
    }

    return $false
}

function Test-FileReady {
    param(
        [string]$Path,
        [int]$StabilitySeconds
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Source file not found: $Path"
    }

    $first = Get-Item -LiteralPath $Path
    Start-Sleep -Seconds $StabilitySeconds
    $second = Get-Item -LiteralPath $Path

    if ($first.Length -ne $second.Length -or $first.LastWriteTimeUtc -ne $second.LastWriteTimeUtc) {
        return [pscustomobject]@{ Ready = $false; Category = "Changing"; Message = "Source file is still changing."; Info = $second }
    }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    }
    catch {
        if (Test-TransientFileAccessException -Exception $_.Exception) {
            return [pscustomobject]@{ Ready = $false; Category = "Locked"; Message = $_.Exception.Message; Info = $second }
        }

        throw
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
    }

    return [pscustomobject]@{ Ready = $true; Category = ""; Message = ""; Info = $second }
}

function Copy-FileExclusive {
    param(
        [string]$SourcePath,
        [string]$PartialPath,
        [bool]$EnableHashVerification
    )

    $sourceStream = $null
    $destinationStream = $null
    $sha256 = $null
    $sourceHash = ""

    try {
        $sourceStream = [System.IO.File]::Open($SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)

        if ($EnableHashVerification) {
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            $sourceHash = Convert-HashBytesToString -Bytes ($sha256.ComputeHash($sourceStream))
            if (-not $sourceStream.CanSeek) {
                throw "Source stream cannot be rewound for copy."
            }
            $sourceStream.Position = 0
        }

        $destinationStream = [System.IO.File]::Open($PartialPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $sourceStream.CopyTo($destinationStream, 1048576)
    }
    finally {
        if ($destinationStream) {
            $destinationStream.Dispose()
        }
        if ($sourceStream) {
            $sourceStream.Dispose()
        }
        if ($sha256) {
            $sha256.Dispose()
        }
    }

    return $sourceHash
}

function Set-NextAttempt {
    param(
        [object]$Config,
        [object]$Job,
        [string]$Category
    )

    $seconds = [int](Get-ObjectValue -Object $Config -Name "DefaultRetryDelaySeconds" -DefaultValue 60)
    if ($Category -eq "Locked") {
        $seconds = [int](Get-ObjectValue -Object $Config -Name "LockedRetryDelaySeconds" -DefaultValue $seconds)
    }
    elseif ($Category -eq "Changing") {
        $seconds = [int](Get-ObjectValue -Object $Config -Name "ChangingRetryDelaySeconds" -DefaultValue $seconds)
    }

    if ($seconds -lt 1) {
        $seconds = 60
    }

    Set-ObjectValue -Object $Job -Name "NextAttemptAt" -Value ([DateTimeOffset]::UtcNow.AddSeconds($seconds).ToString("o"))
}

function Complete-Job {
    param(
        [object]$Config,
        [string]$ProcessingPath,
        [object]$Job,
        [string]$Status,
        [string]$Message,
        [string]$Bucket,
        [string]$ErrorCategory = ""
    )

    Update-Job -Job $Job -Status $Status -Message $Message -ErrorCategory $ErrorCategory
    $destinationDir = Join-Path $Config.StateRoot $Bucket
    Ensure-Directory $destinationDir
    $destinationPath = Join-Path $destinationDir ([System.IO.Path]::GetFileName($ProcessingPath))
    Write-JsonFile -Path $ProcessingPath -Value $Job
    Move-Item -LiteralPath $ProcessingPath -Destination $destinationPath -Force
    Add-AuditEntry -Config $Config -Job $Job -Status $Status -Message $Message
}

function Requeue-Job {
    param(
        [object]$Config,
        [string]$ProcessingPath,
        [object]$Job,
        [string]$Status,
        [string]$Message,
        [string]$ErrorCategory
    )

    Update-Job -Job $Job -Status $Status -Message $Message -ErrorCategory $ErrorCategory
    $queueDir = Join-Path $Config.StateRoot "queue"
    Ensure-Directory $queueDir
    $destinationPath = Join-Path $queueDir ([System.IO.Path]::GetFileName($ProcessingPath))
    Write-JsonFile -Path $ProcessingPath -Value $Job
    Move-Item -LiteralPath $ProcessingPath -Destination $destinationPath -Force
    Add-AuditEntry -Config $Config -Job $Job -Status $Status -Message $Message
}

function Wait-RequeueJob {
    param(
        [object]$Config,
        [string]$ProcessingPath,
        [object]$Job,
        [string]$Category,
        [string]$Message
    )

    $attempt = [int](Get-ObjectValue -Object $Job -Name "AttemptCount" -DefaultValue 0)
    Set-ObjectValue -Object $Job -Name "AttemptCount" -Value ([Math]::Max(0, $attempt - 1))

    if ($Category -eq "Locked") {
        $lockedSince = [string](Get-ObjectValue -Object $Job -Name "LockedSince" -DefaultValue "")
        if ([string]::IsNullOrWhiteSpace($lockedSince)) {
            Set-ObjectValue -Object $Job -Name "LockedSince" -Value ([DateTimeOffset]::UtcNow.ToString("o"))
        }
        else {
            $maxLockedMinutes = [int](Get-ObjectValue -Object $Config -Name "MaxLockedMinutes" -DefaultValue 1440)
            $lockedAt = [DateTimeOffset]::Parse($lockedSince)
            if ($maxLockedMinutes -gt 0 -and [DateTimeOffset]::UtcNow.Subtract($lockedAt).TotalMinutes -ge $maxLockedMinutes) {
                Complete-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Failed" -Message "Source file remained locked longer than MaxLockedMinutes. Last error: $Message" -Bucket "failed" -ErrorCategory "LockedTimeout"
                return
            }
        }

        Set-NextAttempt -Config $Config -Job $Job -Category "Locked"
        Requeue-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "WaitingLocked" -Message $Message -ErrorCategory "Locked"
        return
    }

    Set-NextAttempt -Config $Config -Job $Job -Category "Changing"
    Requeue-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Waiting" -Message $Message -ErrorCategory "Changing"
}

function Remove-JobPartialIfSafe {
    param([object]$Job)

    $partialPath = [string](Get-ObjectValue -Object $Job -Name "PartialPath" -DefaultValue "")
    $jobId = [string](Get-ObjectValue -Object $Job -Name "Id" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($partialPath) -or [string]::IsNullOrWhiteSpace($jobId)) {
        return
    }

    if (-not (Test-Path -LiteralPath $partialPath -PathType Leaf)) {
        return
    }

    $fileName = [System.IO.Path]::GetFileName($partialPath)
    if ($fileName.Contains($jobId) -and $fileName.EndsWith(".partial", [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $partialPath -Force
    }
}

function Recover-StaleProcessingJobs {
    param([object]$Config)

    $processingDir = Join-Path $Config.StateRoot "processing"
    $queueDir = Join-Path $Config.StateRoot "queue"
    Ensure-Directory $processingDir
    Ensure-Directory $queueDir

    $staleAfterMinutes = [int](Get-ObjectValue -Object $Config -Name "StaleAfterMinutes" -DefaultValue 15)
    if ($staleAfterMinutes -lt 1) {
        $staleAfterMinutes = 15
    }

    $now = [DateTimeOffset]::UtcNow
    Get-ChildItem -LiteralPath $processingDir -Filter "*.json" -File | ForEach-Object {
        $jobFile = $_
        $job = $null
        $updatedAt = [DateTimeOffset]$jobFile.LastWriteTimeUtc
        try {
            $job = Get-Content -Raw -LiteralPath $jobFile.FullName | ConvertFrom-Json
            Normalize-Job -Job $job
            $updatedAtText = [string](Get-ObjectValue -Object $job -Name "UpdatedAt" -DefaultValue "")
            if (-not [string]::IsNullOrWhiteSpace($updatedAtText)) {
                $updatedAt = [DateTimeOffset]::Parse($updatedAtText)
            }
        }
        catch {
            return
        }

        if ($now.Subtract($updatedAt).TotalMinutes -lt $staleAfterMinutes) {
            return
        }

        Remove-JobPartialIfSafe -Job $job
        Set-ObjectValue -Object $job -Name "NextAttemptAt" -Value $now.ToString("o")
        Requeue-Job -Config $Config -ProcessingPath $jobFile.FullName -Job $job -Status "Recovered" -Message "Stale processing job recovered and returned to queue." -ErrorCategory "StaleProcessing"
    }
}

function Test-QueueJobDue {
    param([string]$Path)

    try {
        $job = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
        $nextAttemptAt = [string](Get-ObjectValue -Object $job -Name "NextAttemptAt" -DefaultValue "")
        if ([string]::IsNullOrWhiteSpace($nextAttemptAt)) {
            return $true
        }

        return ([DateTimeOffset]::Parse($nextAttemptAt) -le [DateTimeOffset]::UtcNow)
    }
    catch {
        return $true
    }
}

function Invoke-TransferJob {
    param(
        [object]$Config,
        [string]$ProcessingPath,
        [object]$Job
    )

    Normalize-Job -Job $Job
    Set-ObjectValue -Object $Job -Name "AttemptCount" -Value ([int](Get-ObjectValue -Object $Job -Name "AttemptCount" -DefaultValue 0) + 1)
    Set-ObjectValue -Object $Job -Name "Customer" -Value (Resolve-Customer -Job $Job -Config $Config)
    Update-Job -Job $Job -Status "Processing"
    Add-AuditEntry -Config $Config -Job $Job -Status "Processing" -Message "Transfer job started."

    $localPath = [string](Get-ObjectValue -Object $Job -Name "LocalPath" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($localPath)) {
        Complete-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Failed" -Message "Job has no LocalPath." -Bucket "failed" -ErrorCategory "InvalidJob"
        return
    }

    $ignoredPatterns = @(Get-ObjectValue -Object $Config -Name "IgnoredPatterns" -DefaultValue @("*.filepart", "*.partial", "*.tmp"))
    if (Test-PatternList -Path $localPath -Patterns $ignoredPatterns) {
        Complete-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Ignored" -Message "File matches IgnoredPatterns." -Bucket "done"
        return
    }

    $pathInfo = Get-InboundPathInfo -Path $localPath -Config $Config
    if (-not $pathInfo.IsInbound) {
        Complete-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Ignored" -Message $pathInfo.Reason -Bucket "done"
        return
    }

    Set-ObjectValue -Object $Job -Name "Customer" -Value ([string]$pathInfo.Customer)
    Set-ObjectValue -Object $Job -Name "InputSubfolder" -Value ([string]$pathInfo.InputSubfolder)

    if (-not (Test-PathUnderRoot -Path $localPath -Roots @((Get-ObjectValue -Object $Config -Name "InboundRoot" -DefaultValue "C:\Users\Public\sftp_file_upload_root")))) {
        Complete-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Ignored" -Message "Source path is outside configured InboundRoot." -Bucket "done"
        return
    }

    if (-not (Test-PatternList -Path $localPath -Patterns @(Get-ObjectValue -Object $Config -Name "AllowedPatterns" -DefaultValue @("*.csv", "*.xls", "*.xlsx", "*.pdf")))) {
        Complete-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Ignored" -Message "File name does not match AllowedPatterns." -Bucket "done"
        return
    }

    $stabilitySeconds = [int](Get-ObjectValue -Object $Config -Name "FileStabilitySeconds" -DefaultValue 5)
    if ($stabilitySeconds -lt 1) {
        $stabilitySeconds = 5
    }

    $ready = Test-FileReady -Path $localPath -StabilitySeconds $stabilitySeconds
    if (-not $ready.Ready) {
        Wait-RequeueJob -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Category ([string]$ready.Category) -Message ([string]$ready.Message)
        return
    }

    $sourceInfo = $ready.Info
    $route = Resolve-Route -Config $Config -Job $Job
    Set-ObjectValue -Object $Job -Name "RouteName" -Value ([string]$route.Name)
    Set-ObjectValue -Object $Job -Name "DestinationPath" -Value ([string]$route.DestinationPath)

    $destinationPath = [string]$route.DestinationPath
    if (-not (Test-Path -LiteralPath $destinationPath)) {
        $destinationPath = Get-UniquePath -Path $destinationPath
        Set-ObjectValue -Object $Job -Name "DestinationPath" -Value $destinationPath
    }

    $partialPath = $destinationPath + "." + ([string](Get-ObjectValue -Object $Job -Name "Id" -DefaultValue ([guid]::NewGuid().ToString("N")))) + ".partial"
    Set-ObjectValue -Object $Job -Name "PartialPath" -Value $partialPath
    Write-JsonFile -Path $ProcessingPath -Value $Job

    $destinationExists = Test-Path -LiteralPath $destinationPath -PathType Leaf
    if (-not $destinationExists) {
        Ensure-Directory ([System.IO.Path]::GetDirectoryName($destinationPath))
        if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
            Remove-JobPartialIfSafe -Job $Job
        }

        $enableHash = [bool](Get-ObjectValue -Object $Config -Name "EnableHashVerification" -DefaultValue $true)
        $sourceHash = Copy-FileExclusive -SourcePath $localPath -PartialPath $partialPath -EnableHashVerification $enableHash
        $partialInfo = Get-Item -LiteralPath $partialPath

        if ($sourceInfo.Length -ne $partialInfo.Length) {
            throw "Copied file size mismatch. Source=$($sourceInfo.Length), Destination=$($partialInfo.Length)"
        }

        $destinationHash = ""
        if ($enableHash) {
            $destinationHash = Get-FileHashValue -Path $partialPath
            if ($sourceHash -ne $destinationHash) {
                throw "Copied file hash mismatch."
            }
        }

        Set-ObjectValue -Object $Job -Name "SourceLength" -Value $sourceInfo.Length
        Set-ObjectValue -Object $Job -Name "DestinationLength" -Value $partialInfo.Length
        Set-ObjectValue -Object $Job -Name "SourceHash" -Value $sourceHash
        Set-ObjectValue -Object $Job -Name "DestinationHash" -Value $destinationHash
        Write-JsonFile -Path $ProcessingPath -Value $Job
        Move-Item -LiteralPath $partialPath -Destination $destinationPath
    }
    else {
        $destinationInfo = Get-Item -LiteralPath $destinationPath
        if ($destinationInfo.Length -ne $sourceInfo.Length) {
            throw "Existing destination file does not match source length: $destinationPath"
        }
        Set-ObjectValue -Object $Job -Name "SourceLength" -Value $sourceInfo.Length
        Set-ObjectValue -Object $Job -Name "DestinationLength" -Value $destinationInfo.Length
    }

    $archivePath = [string](Get-ObjectValue -Object $Job -Name "ArchivePath" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($archivePath)) {
        $archiveDir = Join-Path (Join-Path ([string]$Config.ArchiveRoot) ([string](Get-ObjectValue -Object $Job -Name "Customer" -DefaultValue "Unknown"))) (Get-Date -Format "yyyyMMdd")
        Ensure-Directory $archiveDir
        $archivePath = Get-UniquePath -Path (Join-Path $archiveDir ([System.IO.Path]::GetFileName($localPath)))
        Set-ObjectValue -Object $Job -Name "ArchivePath" -Value $archivePath
        Write-JsonFile -Path $ProcessingPath -Value $Job
    }

    Move-Item -LiteralPath $localPath -Destination $archivePath
    Set-ObjectValue -Object $Job -Name "PartialPath" -Value ""
    Set-ObjectValue -Object $Job -Name "LastError" -Value ""
    Set-ObjectValue -Object $Job -Name "ErrorCategory" -Value ""

    Complete-Job -Config $Config -ProcessingPath $ProcessingPath -Job $Job -Status "Archived" -Message "File copied, verified, and source archived." -Bucket "done"
}

function Invoke-QueuePass {
    param([object]$Config)

    foreach ($name in @("queue", "processing", "done", "failed", "logs", "locks")) {
        Ensure-Directory (Join-Path $Config.StateRoot $name)
    }

    Recover-StaleProcessingJobs -Config $Config

    $queueDir = Join-Path $Config.StateRoot "queue"
    $processingDir = Join-Path $Config.StateRoot "processing"
    $jobs = Get-ChildItem -LiteralPath $queueDir -Filter "*.json" -File | Sort-Object LastWriteTimeUtc

    foreach ($jobFile in $jobs) {
        if (-not (Test-QueueJobDue -Path $jobFile.FullName)) {
            continue
        }

        $processingPath = Join-Path $processingDir $jobFile.Name

        try {
            Move-Item -LiteralPath $jobFile.FullName -Destination $processingPath
        }
        catch {
            continue
        }

        $job = $null
        try {
            $job = Get-Content -Raw -LiteralPath $processingPath | ConvertFrom-Json
            Normalize-Job -Job $job
            Invoke-TransferJob -Config $Config -ProcessingPath $processingPath -Job $job
        }
        catch {
            if ($null -eq $job) {
                $job = [pscustomobject]@{
                    Id = [guid]::NewGuid().ToString("N")
                    Status = "Failed"
                    LocalPath = ""
                    FtpPath = ""
                    UserName = ""
                    Customer = "Unknown"
                    DestinationPath = ""
                    PartialPath = ""
                    ArchivePath = ""
                    AttemptCount = 1
                    CreatedAt = [DateTimeOffset]::UtcNow.ToString("o")
                    UpdatedAt = [DateTimeOffset]::UtcNow.ToString("o")
                    NextAttemptAt = [DateTimeOffset]::UtcNow.ToString("o")
                    LastError = $_.Exception.Message
                    ErrorCategory = "InvalidJob"
                    LockedSince = ""
                    CompletedAt = ""
                    InputSubfolder = ""
                    RouteName = ""
                }
            }

            Normalize-Job -Job $job

            if (Test-TransientFileAccessException -Exception $_.Exception) {
                Wait-RequeueJob -Config $Config -ProcessingPath $processingPath -Job $job -Category "Locked" -Message $_.Exception.Message
                continue
            }

            Remove-JobPartialIfSafe -Job $job
            $maxAttempts = [int](Get-ObjectValue -Object $Config -Name "MaxAttempts" -DefaultValue 5)
            if ($maxAttempts -lt 1) {
                $maxAttempts = 5
            }

            if ([int](Get-ObjectValue -Object $job -Name "AttemptCount" -DefaultValue 0) -lt $maxAttempts) {
                Set-NextAttempt -Config $Config -Job $job -Category "TransferError"
                Requeue-Job -Config $Config -ProcessingPath $processingPath -Job $job -Status "Retry" -Message $_.Exception.Message -ErrorCategory "TransferError"
            }
            else {
                Complete-Job -Config $Config -ProcessingPath $processingPath -Job $job -Status "Failed" -Message $_.Exception.Message -Bucket "failed" -ErrorCategory "TransferError"
            }
        }
    }
}

$config = Read-TransferConfig -Path $ConfigPath
if ([string]::IsNullOrWhiteSpace([string]$config.StateRoot)) {
    throw "StateRoot is required."
}

foreach ($name in @("queue", "processing", "done", "failed", "logs", "locks")) {
    Ensure-Directory (Join-Path $config.StateRoot $name)
}

$lockPath = Join-Path (Join-Path $config.StateRoot "locks") "process-transfer-queue.lock"
$lockStream = $null
try {
    $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
}
catch {
    exit 0
}

try {
    do {
        Invoke-QueuePass -Config $config
        if (-not $RunOnce) {
            Start-Sleep -Seconds 30
        }
    } while (-not $RunOnce)
}
finally {
    if ($lockStream) {
        $lockStream.Dispose()
    }
}
