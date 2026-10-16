<#
  Phase 8 follow-ups in DEV: enable quick create on Payment and Attendance, add the three dashboards to the EDU School Admin app,
  and publish. Idempotent. Usage: .\Fix-AppSetup.ps1 -OrgUrl https://<your-dev>.crm8.dynamics.com -TokenFile <file from Get-DvToken.ps1>
#>
param(
    [Parameter(Mandatory)][string]$OrgUrl,
    [Parameter(Mandatory)][string]$TokenFile
)
$ErrorActionPreference = 'Stop'
$api = "$OrgUrl/api/data/v9.2"
$h = @{ Authorization = "Bearer $((Get-Content $TokenFile -Raw).Trim())"; 'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0'; Accept = 'application/json' }
function Dv($m, $p, $b = $null, $extra = @{}) {
    $a = @{ Method = $m; Uri = "$api/$p"; Headers = ($h + $extra) }
    if ($null -ne $b) { $a.Body = ($b | ConvertTo-Json -Depth 40 -Compress); $a.ContentType = 'application/json; charset=utf-8' }
    Invoke-RestMethod @a
}

foreach ($t in 'edu_payment', 'edu_attendance') {
    $e = Dv GET "EntityDefinitions(LogicalName='$t')"
    if ($e.IsQuickCreateEnabled) { Write-Host "= $t quick create already on"; continue }
    $e.IsQuickCreateEnabled = $true
    Dv PUT "EntityDefinitions($($e.MetadataId))" $e @{ 'MSCRM.MergeLabels' = 'true'; 'MSCRM.SolutionUniqueName' = 'EduCore' } | Out-Null
    Write-Host "+ $t quick create on"
}

$app = (Dv GET "appmodules?`$filter=uniquename eq 'edu_SchoolAdmin'&`$select=appmoduleid").value[0]
if (-not $app) { throw 'App edu_SchoolAdmin not found (is it published?)' }
$ids = @()
foreach ($n in 'Admin', 'Teacher', 'Front Office') {
    $d = (Dv GET "systemforms?`$filter=type eq 0 and contains(name,'$n')&`$select=formid,name").value
    foreach ($x in $d) { $ids += $x.formid; Write-Host "  dashboard $($x.name)" }
}
if ($ids.Count) {
    $comps = @($ids | ForEach-Object { @{ '@odata.type' = 'Microsoft.Dynamics.CRM.systemform'; formid = $_ } })
    Dv POST 'AddAppComponents' @{ AppId = $app.appmoduleid; Components = $comps } | Out-Null
    Write-Host "+ $($ids.Count) dashboards added to the app"
}
Dv POST 'PublishAllXml' @{} | Out-Null
Write-Host 'Published.'
