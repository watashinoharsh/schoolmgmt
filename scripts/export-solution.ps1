<#
.SYNOPSIS  Export a solution from the DEV environment and unpack it into source control.
.EXAMPLE   .\export-solution.ps1 -Solution EduCore -EnvironmentUrl https://<your-dev>.crm8.dynamics.com
.NOTES     Always export unmanaged from DEV. Custom API definitions that are not yet bound to a plug-in in DEV are not exported; unpack no longer deletes files, so they stay in source. Review the diff (git diff --stat) before committing.
#>
param(
    [Parameter(Mandatory)][ValidateSet('EduCore', 'EduFlows', 'EduApps')][string]$Solution,
    [Parameter(Mandatory)][string]$EnvironmentUrl
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$zip = Join-Path $env:TEMP "edu-export-$Solution.zip"

pac solution export --name $Solution --path $zip --environment $EnvironmentUrl --overwrite --managed false
if ($LASTEXITCODE -ne 0) { throw 'Export failed.' }

pac solution unpack --zipfile $zip --folder "$root\solutions\$Solution\src" --packagetype Unmanaged --allowWrite true
if ($LASTEXITCODE -ne 0) { throw 'Unpack failed.' }

# The unmanaged unpack resets the package type; the pipeline packs managed from source, so it must stay Both (2).
$sx = Join-Path $root "solutions\$Solution\src\Other\Solution.xml"
(Get-Content $sx -Raw) -replace '<Managed>0</Managed>', '<Managed>2</Managed>' | Set-Content $sx -NoNewline -Encoding utf8
Write-Host "Unpacked $Solution into solutions\$Solution\src. Review with: git diff --stat"
