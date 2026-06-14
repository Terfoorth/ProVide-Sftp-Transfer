[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = "C:\ProgramData\ProVideTransfer\transfer-config.json",
    [string]$AccountsRoot = "C:\Program Files\ProVide\accounts"
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
        if ($PSCmdlet.ShouldProcess($Path, "Create directory")) {
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
        }
    }
}

function Get-UsernameFromUac {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -match "^Username=(.+)$") {
            return $Matches[1].Trim()
        }
    }

    return ""
}

function Test-ManagedResourceLine {
    param(
        [string]$Line,
        [string]$UserName,
        [string]$CustomerRoot
    )

    if ($Line -notmatch "^/") {
        return $false
    }

    $escapedUser = [regex]::Escape($UserName)
    if ($Line -match "^/$escapedUser($|/|\|)") {
        return $true
    }

    if ($Line.IndexOf($CustomerRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
    }

    return $false
}

function Get-InsertIndex {
    param(
        [string[]]$Lines,
        [int[]]$RemovedIndexes
    )

    if ($RemovedIndexes.Count -gt 0) {
        return ($RemovedIndexes | Measure-Object -Minimum).Minimum
    }

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\{") {
            return $i
        }
    }

    return $Lines.Count
}

function Sync-UacFile {
    param(
        [System.IO.FileInfo]$File,
        [string]$UploadRoot,
        [string]$InboundFolder,
        [string]$OutboundFolder,
        [string]$BackupDir
    )

    $lines = @(Get-Content -LiteralPath $File.FullName)
    $userName = Get-UsernameFromUac -Lines $lines
    if ([string]::IsNullOrWhiteSpace($userName) -or $userName.Equals("Admin", [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ UserName = $userName; File = $File.FullName; Changed = $false; Message = "Skipped" }
    }

    $customerRoot = Join-Path $UploadRoot $userName
    $inPath = Join-Path $customerRoot $InboundFolder
    $outPath = Join-Path $customerRoot $OutboundFolder

    Ensure-Directory $customerRoot
    Ensure-Directory $inPath
    Ensure-Directory $outPath

    $resourceLines = @(
        "/$userName/$InboundFolder||",
        "/$userName/$InboundFolder|$inPath|,AF,DF,LD,RF,WF",
        "/$userName/$OutboundFolder||",
        "/$userName/$OutboundFolder|$outPath|,AF,DF,LD,RF,WF",
        "/$userName||",
        "/$userName|$customerRoot|,AF,DF,RF,WF"
    )

    $kept = New-Object "System.Collections.Generic.List[string]"
    $removedIndexes = New-Object "System.Collections.Generic.List[int]"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (Test-ManagedResourceLine -Line $lines[$i] -UserName $userName -CustomerRoot $customerRoot) {
            [void]$removedIndexes.Add($i)
            continue
        }

        [void]$kept.Add($lines[$i])
    }

    $insertIndex = Get-InsertIndex -Lines $lines -RemovedIndexes ([int[]]$removedIndexes.ToArray())
    $newLines = New-Object "System.Collections.Generic.List[string]"
    for ($i = 0; $i -lt $kept.Count; $i++) {
        if ($i -eq $insertIndex) {
            foreach ($resourceLine in $resourceLines) {
                [void]$newLines.Add($resourceLine)
            }
        }
        [void]$newLines.Add($kept[$i])
    }

    if ($insertIndex -ge $kept.Count) {
        foreach ($resourceLine in $resourceLines) {
            [void]$newLines.Add($resourceLine)
        }
    }

    $oldText = [string]::Join("`n", $lines)
    $newText = [string]::Join("`n", $newLines.ToArray())
    if ($oldText -eq $newText) {
        return [pscustomobject]@{ UserName = $userName; File = $File.FullName; Changed = $false; Message = "Already current" }
    }

    Ensure-Directory $BackupDir
    $backupPath = Join-Path $BackupDir $File.Name
    if ($PSCmdlet.ShouldProcess($File.FullName, "Update UAC resources and backup to $backupPath")) {
        Copy-Item -LiteralPath $File.FullName -Destination $backupPath -Force
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($File.FullName, [string[]]$newLines.ToArray(), $encoding)
    }

    return [pscustomobject]@{ UserName = $userName; File = $File.FullName; Changed = $true; Message = "Updated" }
}

$config = Read-TransferConfig -Path $ConfigPath
$uploadRoot = [string](Get-ObjectValue -Object $config -Name "InboundRoot" -DefaultValue "C:\Users\Public\sftp_file_upload_root")
$inboundFolder = [string](Get-ObjectValue -Object $config -Name "InboundFolderName" -DefaultValue "in")
$outboundFolder = [string](Get-ObjectValue -Object $config -Name "OutboundFolderName" -DefaultValue "out")

if (-not (Test-Path -LiteralPath $AccountsRoot -PathType Container)) {
    throw "AccountsRoot not found: $AccountsRoot"
}

Ensure-Directory $uploadRoot
$backupDir = Join-Path (Join-Path $AccountsRoot "backup") ("codex-uac-sync-" + (Get-Date -Format "yyyyMMddHHmmss"))

Get-ChildItem -LiteralPath $AccountsRoot -Filter "*.uac" -File |
    Where-Object { $_.Name -match "^acc\[.+\]\.uac$" } |
    Sort-Object Name |
    ForEach-Object {
    Sync-UacFile -File $_ -UploadRoot $uploadRoot -InboundFolder $inboundFolder -OutboundFolder $outboundFolder -BackupDir $backupDir
}
