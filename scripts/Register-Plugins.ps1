<#
  Builds the EduCore plug-in package (Release), uploads it to a Dataverse environment, registers every plug-in step with its images
  and binds the Custom APIs to their plug-in types. Idempotent (package updated in place, existing steps/images/bindings skipped); nothing is deleted.
  Usage: .\Register-Plugins.ps1 -OrgUrl https://<your-dev>.crm8.dynamics.com -TokenFile <file from Get-DvToken.ps1> [-SkipBuild]
#>
param(
    [Parameter(Mandatory)][string]$OrgUrl,
    [Parameter(Mandatory)][string]$TokenFile,
    [string]$Solution = 'EduCore',
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$api = "$OrgUrl/api/data/v9.2"
$h = @{ Authorization = "Bearer $((Get-Content $TokenFile -Raw).Trim())"; 'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0'; Accept = 'application/json'; 'MSCRM.SolutionUniqueName' = $Solution }
function Dv($m, $p, $b = $null) {
    $a = @{ Method = $m; Uri = "$api/$p"; Headers = $h }
    if ($null -ne $b) { $a.Body = ($b | ConvertTo-Json -Depth 10 -Compress); $a.ContentType = 'application/json; charset=utf-8' }
    try { Invoke-RestMethod @a } catch { throw "HTTP $m $p :: $($_.ErrorDetails.Message)" }
}

# 1. Package
$proj = Join-Path $PSScriptRoot '..\src\EduCore.Plugins'
if (-not $SkipBuild) { dotnet build $proj -c Release --no-incremental --nologo -v q; if ($LASTEXITCODE) { throw "build failed" } }   # clean build so the .nupkg is regenerated
$pkg = Get-ChildItem (Join-Path $proj 'bin\Release') -Filter *.nupkg | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $pkg) { throw 'no .nupkg found' }
$uname = 'edu_EduCorePlugins'
$ver = [regex]::Match($pkg.BaseName, '\d+\.\d+\.\d+(\.\d+)?$').Value
$body = @{ content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pkg.FullName)); version = $ver }
$ex = (Dv GET "pluginpackages?`$filter=uniquename eq '$uname'&`$select=pluginpackageid").value | Select-Object -First 1
if ($ex) { $pkgId = $ex.pluginpackageid; Dv PATCH "pluginpackages($pkgId)" $body | Out-Null; Write-Host "~ package updated $pkgId" }
else {
    $body.name = $uname; $body.uniquename = $uname; Dv POST 'pluginpackages' $body | Out-Null
    $pkgId = (Dv GET "pluginpackages?`$filter=uniquename eq '$uname'&`$select=pluginpackageid").value[0].pluginpackageid; Write-Host "+ package $pkgId"
}
Write-Host "  package id: $pkgId"

# plug-in types appear asynchronously after the package import
$types = @{}
for ($i = 0; $i -lt 30; $i++) {
    $types = @{}
    foreach ($t in (Dv GET "plugintypes?`$filter=startswith(typename,'EduCore.Plugins.')&`$select=plugintypeid,typename").value) { $types[$t.typename] = $t.plugintypeid }
    if ($types.Count -ge 20) { break }
    Start-Sleep 5
}
Write-Host "  plug-in types: $($types.Count)"

# 2. Steps: class, entities, messages, stage, filter (update only), images
$ref = 'edu_academicyear', 'edu_term', 'edu_calendarday', 'edu_grade', 'edu_course', 'edu_period', 'edu_gradeband', 'edu_staff', 'edu_section'
$cu = 'Create', 'Update'; $cud = 'Create', 'Update', 'Delete'
$script:defs = @()
function Def($cls, $ents, $msgs, $stage = 20, $filter = $null, $post = $false) {
    foreach ($e in $ents) {
        foreach ($m in $msgs) {
            $script:defs += [pscustomobject]@{ Cls = $cls; Ent = $e; Msg = $m; Stage = $stage; Filter = $(if ($m -eq 'Update') { $filter }); Pre = ($m -ne 'Create'); Post = ($post -and $m -ne 'Delete') }
        }
    }
}
Def ReferenceDataPlugin $ref $cu
Def StudentGuardianPlugin edu_studentguardian $cu
Def EnrolmentPlugin edu_enrolment $cu 20
Def EnrolmentPlugin edu_enrolment $cud 40
Def ApplicantPlugin edu_applicant $cu 20 'statuscode,edu_decisionreason'
Def ClassSchedulePlugin edu_classschedule $cu
Def StudentMarkPlugin edu_studentmark $cu
Def AttendancePlugin edu_attendance $cu
Def FeeStructurePlugin edu_feestructure $cu
Def AssessmentPlugin edu_assessment $cu 20 'edu_maxmarks'
Def InvoiceLineGuardPlugin edu_invoiceline $cud
Def PaymentGuardPlugin edu_payment $cud
Def InvoiceTotalsPlugin ('edu_invoiceline', 'edu_payment') $cud 40 $null $true
Def ReportCardGuardPlugin edu_reportcard ('Update', 'Delete')
Def ReportCardLineGuardPlugin edu_reportcardline $cud

$msgIds = @{}; foreach ($m in $cud) { $msgIds[$m] = (Dv GET "sdkmessages?`$filter=name eq '$m'&`$select=sdkmessageid").value[0].sdkmessageid }
$new = 0; $have = 0
foreach ($d in $script:defs) {
    $tn = "EduCore.Plugins.$($d.Cls)"
    $tid = $types[$tn]; if (-not $tid) { throw "plug-in type $tn not found" }
    $sn = "$($d.Cls): $($d.Msg) of $($d.Ent) ($(if ($d.Stage -eq 20) { 'pre' } else { 'post' }))"
    $q = "sdkmessageprocessingsteps?`$filter=name eq '$sn'&`$select=sdkmessageprocessingstepid"
    $st = (Dv GET $q).value | Select-Object -First 1
    if ($st) { $have++; $sid = $st.sdkmessageprocessingstepid }
    else {
        $f = (Dv GET "sdkmessagefilters?`$filter=primaryobjecttypecode eq '$($d.Ent)' and _sdkmessageid_value eq $($msgIds[$d.Msg])&`$select=sdkmessagefilterid").value[0].sdkmessagefilterid
        $b = @{ name = $sn; stage = $d.Stage; mode = 0; rank = 1; supporteddeployment = 0
            'sdkmessageid@odata.bind' = "/sdkmessages($($msgIds[$d.Msg]))"; 'sdkmessagefilterid@odata.bind' = "/sdkmessagefilters($f)"
            'plugintypeid@odata.bind' = "/plugintypes($tid)" }
        if ($d.Filter) { $b.filteringattributes = $d.Filter }
        Dv POST 'sdkmessageprocessingsteps' $b | Out-Null
        $sid = (Dv GET $q).value[0].sdkmessageprocessingstepid
        $new++; Write-Host "+ $sn"
    }
    Dv POST 'AddSolutionComponent' @{ ComponentId = $sid; ComponentType = 92; SolutionUniqueName = $Solution; AddRequiredComponents = $false } | Out-Null
    $imgs = @()
    if ($d.Pre) { $imgs += @{ n = 'pre'; t = 0; p = 'Target' } }
    if ($d.Post) { $imgs += @{ n = 'post'; t = 1; p = $(if ($d.Msg -eq 'Create') { 'Id' } else { 'Target' }) } }
    foreach ($im in $imgs) {
        $e = (Dv GET "sdkmessageprocessingstepimages?`$filter=_sdkmessageprocessingstepid_value eq $sid and entityalias eq '$($im.n)'&`$select=sdkmessageprocessingstepimageid").value | Select-Object -First 1
        if (-not $e) {
            # no attributes property = all columns
            Dv POST 'sdkmessageprocessingstepimages' @{ name = $im.n; entityalias = $im.n; imagetype = $im.t; messagepropertyname = $im.p
                'sdkmessageprocessingstepid@odata.bind' = "/sdkmessageprocessingsteps($sid)" } | Out-Null
            Write-Host "  + image $($im.n)"
        }
    }
}
Write-Host "Steps: $new new, $have existing, $($script:defs.Count) total"

# 3. Custom API bindings
$bind = @{ edu_EnrolApplicant = 'EnrolApplicantPlugin'; edu_RefreshAttendanceSummary = 'RefreshAttendanceSummaryPlugin'; edu_GenerateInvoice = 'GenerateInvoicePlugin'; edu_GenerateReportCards = 'GenerateReportCardsPlugin' }
foreach ($k in $bind.Keys) {
    $tid = $types["EduCore.Plugins.$($bind[$k])"]; if (-not $tid) { throw "type for $k not found" }
    $c = (Dv GET "customapis?`$filter=uniquename eq '$k'&`$select=customapiid").value | Select-Object -First 1
    if (-not $c) { throw "custom api $k not found" }
    Dv PATCH "customapis($($c.customapiid))" @{ 'PluginTypeId@odata.bind' = "/plugintypes($tid)" } | Out-Null
    Write-Host "= bound $k -> $($bind[$k])"
}
Write-Host 'Done.'
