<#
  Creates the model-driven app "EDU School Admin" (edu_SchoolAdmin), its site map and three dashboards in solution EduApps (idempotent).
  The old edu_Phase3Admin app record does not exist in DEV (only a dangling solution component), so this app is created fresh.
  Usage: .\New-AdminApp.ps1 -TokenFile <file> -OrgUrl https://<your-dev>.crm8.dynamics.com
#>
param(
    [Parameter(Mandatory)][string]$OrgUrl,
    [Parameter(Mandatory)][string]$TokenFile,
    [string]$Solution = 'EduApps'
)
$ErrorActionPreference = 'Stop'
$api = "$OrgUrl/api/data/v9.2"
$script:failures = New-Object System.Collections.ArrayList
$script:token = (Get-Content $TokenFile -Raw).Trim()
function Dv {
    param([string]$Method, [string]$Path, $Body = $null, [switch]$NoSolution, [switch]$Quiet404)
    $h = @{ Authorization = "Bearer $script:token"; 'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0'; Accept = 'application/json' }
    if (-not $NoSolution) { $h['MSCRM.SolutionUniqueName'] = $Solution }
    $p = @{ Method = $Method; Uri = "$api/$Path"; Headers = $h }
    if ($null -ne $Body) {
        $p.Body = ($Body | ConvertTo-Json -Depth 40 -Compress)
        $p.ContentType = 'application/json; charset=utf-8'
    }
    for ($try = 1; $try -le 4; $try++) {
        try { return Invoke-RestMethod @p }
        catch {
            $msg = "$($_.ErrorDetails.Message)"
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($code -eq 404 -and $Quiet404) { return $null }
            if ($try -lt 4 -and ($code -ge 500 -or $code -eq 429 -or $msg -match 'lock|in progress|timed out|0x80040237|0x8004F')) {
                Start-Sleep -Seconds (6 * $try); continue
            }
            throw "HTTP $code $Method $Path :: $msg"
        }
    }
}
function Step([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Fail([string]$what, $err) { Write-Host "  FAILED: $what -> $err" -ForegroundColor Red; [void]$script:failures.Add("$what :: $err") }
function Q([string]$s) { [uri]::EscapeDataString($s) }

# ---------------------------------------------------------------- site map layout
$map = [ordered]@{
  'Admissions' = @('edu_applicant','edu_reenrolment','edu_reenrolmentcycle','edu_reenrolmentcohort','edu_reenrolmentrule','edu_approvalrequest','edu_approvalhistory','edu_documentreference')
  'Students'   = @('edu_student','edu_studentguardian','contact','edu_enrolment','edu_behaviourrecord','edu_behaviourcategory','edu_consentrecord','edu_consenttype','edu_pickupauthorisation','edu_gatepass','edu_visitor','edu_kioskrecord')
  'Academics'  = @('edu_section','edu_course','edu_subjectassignment','edu_classschedule','edu_assessment','edu_studentmark','edu_gradebookcomponent','edu_gradebookresult','edu_gradebookpublish','edu_reportcard','edu_reportcardline','edu_academicreport','edu_academicreportversion')
  'Attendance' = @('edu_attendance','edu_attendancerecord','edu_attendancesummary','edu_musterevent','edu_musterentry')
  'Finance'    = @('edu_feestructure','edu_feetype','edu_invoice','edu_invoiceline','edu_payment')
  'Staff'      = @('edu_staff','edu_approvaldelegation','edu_activity','edu_activityparticipant','edu_activityvenue','edu_activitytransport','edu_activityrisk','edu_activityreport','edu_activityfeedback')
  'Setup'      = @('edu_academicyear','edu_term','edu_calendarday','edu_period','edu_grade','edu_gradeband','edu_notification','edu_notificationrule','edu_notificationtemplate','edu_notificationrecipient','edu_notificationrecipientrule','edu_approvalmatrix','edu_approvalmatrixdetail','edu_approvalcontenttemplate','edu_rolloverplan')
}
$srcDir = Join-Path $PSScriptRoot '..\solutions\EduCore\src\Entities'
$all = @(Get-ChildItem $srcDir -Directory | ForEach-Object { $_.Name.ToLower() })
$placed = @($map.Values | ForEach-Object { $_ })
$extra = @($all | Where-Object { $_ -like 'edu_*' -and $placed -notcontains $_ })
if ($extra) { $map['Setup'] += $extra; Write-Host "  unassigned tables placed in Setup: $($extra -join ', ')" }

Step '== Entity metadata =='
$ents = @{}
(Dv GET "EntityDefinitions?`$select=LogicalName,MetadataId" -NoSolution).value | ForEach-Object { $ents[$_.LogicalName] = $_.MetadataId }
$missing = @(($placed + $extra) | Where-Object { -not $ents.ContainsKey($_) })
if ($missing) { Fail 'entities not in org' ($missing -join ', ') }

# ---------------------------------------------------------------- charts
Step '== Charts =='
function New-Chart($name, $entity, $fetchInner, $catAlias, $measures, $type = 'Column') {
    $flt = "`$select=savedqueryvisualizationid&`$filter=name eq '$(Q $name)' and primaryentitytypecode eq '$entity'"
    $ex = (Dv GET "savedqueryvisualizations?$flt" -NoSolution).value
    if ($ex.Count -gt 0) { Write-Host "  exists: $name"; return $ex[0].savedqueryvisualizationid }
    $m = ($measures | ForEach-Object { "<measurecollection><measure alias=`"$_`" /></measurecollection>" }) -join ''
    $dd = "<datadefinition><fetchcollection><fetch mapping=`"logical`" aggregate=`"true`"><entity name=`"$entity`">$fetchInner</entity></fetch></fetchcollection><categorycollection><category alias=`"$catAlias`">$m</category></categorycollection></datadefinition>"
    $s = ($measures | ForEach-Object { "<Series ChartType=`"$type`" IsValueShownAsLabel=`"True`" />" }) -join ''
    $pd = "<Chart Palette=`"None`" PaletteCustomColors=`"0,114,198;76,175,80;255,152,0;156,39,176`"><Series>$s</Series><ChartAreas><ChartArea><AxisY><MajorGrid LineColor=`"233, 233, 233`" /></AxisY><AxisX><MajorGrid Enabled=`"False`" /></AxisX></ChartArea></ChartAreas><Legends><Legend Alignment=`"Center`" Docking=`"Bottom`" /></Legends></Chart>"
    $body = @{ name = $name; primaryentitytypecode = $entity; type = 0; isdefault = $false; datadescription = $dd; presentationdescription = $pd }
    try {
        Dv POST 'savedqueryvisualizations' $body | Out-Null
        $id = (Dv GET "savedqueryvisualizations?$flt" -NoSolution).value[0].savedqueryvisualizationid
        Write-Host "  created: $name"; return $id
    } catch { Fail "chart $name" $_; return $null }
}
$chApp  = New-Chart 'EDU Applications by status' 'edu_applicant' '<attribute name="edu_applicantid" alias="cnt" aggregate="count" /><attribute name="statuscode" alias="grp" groupby="true" />' 'grp' @('cnt') 'Column'
$chFee  = New-Chart 'EDU Fees collected vs outstanding' 'edu_invoice' '<attribute name="edu_paidamount" alias="paid" aggregate="sum" /><attribute name="edu_dueamount" alias="due" aggregate="sum" /><attribute name="edu_invoicestatus" alias="grp" groupby="true" />' 'grp' @('paid','due') 'Column'
$chAtt  = New-Chart 'EDU Attendance trend by month' 'edu_attendance' '<attribute name="edu_attendanceid" alias="cnt" aggregate="count" /><attribute name="edu_date" alias="grp" groupby="true" dategrouping="month" />' 'grp' @('cnt') 'Line'
$chAttS = New-Chart 'EDU Attendance by status' 'edu_attendance' '<attribute name="edu_attendanceid" alias="cnt" aggregate="count" /><attribute name="edu_attendancestatus" alias="grp" groupby="true" />' 'grp' @('cnt') 'Pie'
$chAsm  = New-Chart 'EDU Assessments by type' 'edu_assessment' '<attribute name="edu_assessmentid" alias="cnt" aggregate="count" /><attribute name="edu_assessmenttype" alias="grp" groupby="true" />' 'grp' @('cnt') 'Column'
$chRc   = New-Chart 'EDU Report cards by status' 'edu_reportcard' '<attribute name="edu_reportcardid" alias="cnt" aggregate="count" /><attribute name="edu_reportstatus" alias="grp" groupby="true" />' 'grp' @('cnt') 'Pie'

# ---------------------------------------------------------------- dashboards
Step '== Dashboards =='
function ViewId($entity) {
    $v = (Dv GET "savedqueries?`$select=savedqueryid&`$filter=returnedtypecode eq '$entity' and querytype eq 0 and isdefault eq true" -NoSolution).value
    if ($v.Count -eq 0) { return $null }; return $v[0].savedqueryid
}
function NewGuid { '{' + [guid]::NewGuid().ToString().ToUpper() + '}' }
function Cell-Chart($entity, $chartId, $viewId) {
    "<cell id=`"$(NewGuid)`" showlabel=`"false`" rowspan=`"9`" colspan=`"1`"><labels><label description=`"`" languagecode=`"1033`" /></labels><control id=`"c$([guid]::NewGuid().ToString('N'))`" classid=`"{E7A81278-8635-4d9e-8D4D-59480B391C5B}`"><parameters><ViewId>{$viewId}</ViewId><IsUserView>false</IsUserView><RelationshipName /><TargetEntityType>$entity</TargetEntityType><AutoExpand>Fixed</AutoExpand><EnableQuickFind>false</EnableQuickFind><EnableViewPicker>false</EnableViewPicker><ViewIds /><EnableJumpBar>false</EnableJumpBar><ChartGridMode>Chart</ChartGridMode><VisualizationId>{$chartId}</VisualizationId><IsUserChart>false</IsUserChart><EnableChartPicker>false</EnableChartPicker><RecordsPerPage>5</RecordsPerPage></parameters></control></cell>"
}
function Cell-List($entity, $viewId) {
    "<cell id=`"$(NewGuid)`" showlabel=`"false`" rowspan=`"9`" colspan=`"1`"><labels><label description=`"`" languagecode=`"1033`" /></labels><control id=`"c$([guid]::NewGuid().ToString('N'))`" classid=`"{E7A81278-8635-4d9e-8D4D-59480B391C5B}`"><parameters><ViewId>{$viewId}</ViewId><IsUserView>false</IsUserView><RelationshipName /><TargetEntityType>$entity</TargetEntityType><AutoExpand>Fixed</AutoExpand><EnableQuickFind>false</EnableQuickFind><EnableViewPicker>true</EnableViewPicker><ViewIds>{$viewId}</ViewIds><EnableJumpBar>false</EnableJumpBar><ChartGridMode>Grid</ChartGridMode><VisualizationId /><IsUserChart>false</IsUserChart><EnableChartPicker>false</EnableChartPicker><RecordsPerPage>6</RecordsPerPage></parameters></control></cell>"
}
function New-Dashboard($name, $desc, $rows) {
    $flt = "`$select=formid&`$filter=name eq '$(Q $name)' and type eq 0"
    $ex = (Dv GET "systemforms?$flt" -NoSolution).value
    if ($ex.Count -gt 0) { Write-Host "  exists: $name"; return $ex[0].formid }
    $rx = ($rows | ForEach-Object { '<row>' + ($_ -join '') + '</row>' }) -join ''
    $xml = "<form><tabs><tab verticallayout=`"true`" id=`"$(NewGuid)`"><labels><label description=`"`" languagecode=`"1033`" /></labels><columns><column width=`"100%`"><sections><section showlabel=`"false`" showbar=`"false`" id=`"$(NewGuid)`" columns=`"2`"><labels><label description=`"`" languagecode=`"1033`" /></labels><rows>$rx</rows></section></sections></column></columns></tab></tabs></form>"
    try {
        Dv POST 'systemforms' @{ name = $name; description = $desc; type = 0; objecttypecode = 'none'; isdefault = $false; formxml = $xml } | Out-Null
        $id = (Dv GET "systemforms?$flt" -NoSolution).value[0].formid
        Write-Host "  created: $name"; return $id
    } catch { Fail "dashboard $name" $_; return $null }
}
$vApp = ViewId 'edu_applicant'; $vInv = ViewId 'edu_invoice'; $vAtt = ViewId 'edu_attendance'; $vSec = ViewId 'edu_section'; $vAsm = ViewId 'edu_assessment'; $vRc = ViewId 'edu_reportcard'
$dAdmin = $null; $dTeach = $null; $dFront = $null
if ($chApp -and $chFee -and $chAtt -and $chAttS) {
    $dAdmin = New-Dashboard 'EDU Admin Dashboard' 'Application funnel, fees collected vs outstanding, attendance trend' @(
        @((Cell-Chart 'edu_applicant' $chApp $vApp), (Cell-Chart 'edu_invoice' $chFee $vInv)),
        @((Cell-Chart 'edu_attendance' $chAtt $vAtt), (Cell-Chart 'edu_attendance' $chAttS $vAtt)))
}
if ($chAsm -and $chRc) {
    $dTeach = New-Dashboard 'EDU Teacher Dashboard' 'Sections, assessments to grade, report cards' @(
        @((Cell-List 'edu_section' $vSec), (Cell-List 'edu_assessment' $vAsm)),
        @((Cell-Chart 'edu_assessment' $chAsm $vAsm), (Cell-Chart 'edu_reportcard' $chRc $vRc)))
}
if ($chApp) {
    $dFront = New-Dashboard 'EDU Front Office Dashboard' 'Applications to process, offers, absences to phone, invoices' @(
        @((Cell-List 'edu_applicant' $vApp), (Cell-Chart 'edu_applicant' $chApp $vApp)),
        @((Cell-List 'edu_attendance' $vAtt), (Cell-List 'edu_invoice' $vInv)))
}

# ---------------------------------------------------------------- site map
Step '== Site map =='
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('<SiteMap IntroducedVersion="1.0.0.0">')
$first = $true
foreach ($area in $map.Keys) {
    [void]$sb.Append("<Area Id=`"area_$area`" ShowGroups=`"true`"><Titles><Title LCID=`"1033`" Title=`"$area`" /></Titles>")
    [void]$sb.Append("<Group Id=`"grp_$area`"><Titles><Title LCID=`"1033`" Title=`"$area`" /></Titles>")
    if ($first) { [void]$sb.Append('<SubArea Id="sub_dashboards" Entity="dashboard"><Titles><Title LCID="1033" Title="Dashboards" /></Titles></SubArea>'); $first = $false }
    foreach ($e in $map[$area]) { if ($ents.ContainsKey($e)) { [void]$sb.Append("<SubArea Id=`"sub_$e`" Entity=`"$e`" />") } }
    [void]$sb.Append('</Group></Area>')
}
[void]$sb.Append('</SiteMap>')
$smName = 'edu_SchoolAdminSiteMap'
$smId = $null
try {
    $sm = (Dv GET "sitemaps?`$select=sitemapid&`$filter=sitemapnameunique eq '$smName'" -NoSolution).value
    if ($sm.Count -gt 0) { $smId = $sm[0].sitemapid; Dv PATCH "sitemaps($smId)" @{ sitemapxml = $sb.ToString() } | Out-Null; Write-Host '  site map updated' }
    else {
        Dv POST 'sitemaps' @{ sitemapname = 'EDU School Admin'; sitemapnameunique = $smName; sitemapxml = $sb.ToString(); isappaware = $true } | Out-Null
        $smId = (Dv GET "sitemaps?`$select=sitemapid&`$filter=sitemapnameunique eq '$smName'" -NoSolution).value[0].sitemapid; Write-Host '  site map created'
    }
} catch { Fail 'sitemap' $_ }

# ---------------------------------------------------------------- app
Step '== App =='
$appId = $null
try {
    $app = (Dv GET "appmodules/Microsoft.Dynamics.CRM.RetrieveUnpublishedMultiple()?`$select=appmoduleid&`$filter=uniquename eq 'edu_SchoolAdmin'" -NoSolution).value
    if ($app.Count -gt 0) { $appId = $app[0].appmoduleid; Write-Host '  app exists' }
    else {
        Dv POST 'appmodules' @{ name = 'EDU School Admin'; uniquename = 'edu_SchoolAdmin'; description = 'EduCore school administration: admissions, students, academics, attendance, finance, staff, setup'; clienttype = 4; formfactor = 1; navigationtype = 0; webresourceid = '953b9fac-1e5e-e611-80d6-00155ded156f' } | Out-Null
        $appId = (Dv GET "appmodules/Microsoft.Dynamics.CRM.RetrieveUnpublishedMultiple()?`$select=appmoduleid&`$filter=uniquename eq 'edu_SchoolAdmin'" -NoSolution).value[0].appmoduleid; Write-Host '  app created'
    }
} catch { Fail 'app' $_ }

if ($appId) {
    $have = @()
    try { $have = @((Dv GET "appmodulecomponents?`$select=objectid&`$filter=_appmoduleidunique_value eq $appId" -NoSolution).value | ForEach-Object { $_.objectid }) } catch { Write-Host "  (could not list existing components: $_)" }
    $comps = @()
    foreach ($e in (($placed + $extra) | Select-Object -Unique)) { if ($ents.ContainsKey($e) -and $have -notcontains $ents[$e]) { $comps += @{ '@odata.type' = 'Microsoft.Dynamics.CRM.entity'; entityid = $ents[$e] } } }
    if ($smId -and $have -notcontains $smId) { $comps += @{ '@odata.type' = 'Microsoft.Dynamics.CRM.sitemap'; sitemapid = $smId } }
    foreach ($d in @($dAdmin, $dTeach, $dFront)) { if ($d -and $have -notcontains $d) { $comps += @{ '@odata.type' = 'Microsoft.Dynamics.CRM.systemform'; formid = $d } } }
    if ($comps.Count -gt 0) {
        try { Dv POST 'AddAppComponents' @{ AppId = $appId; Components = $comps } | Out-Null; Write-Host "  added $($comps.Count) components" }
        catch { Fail 'AddAppComponents' $_ }
    }
    Step '== Validate and publish =='
    try {
        $v = Dv GET "ValidateApp(AppModuleId=$appId)" -NoSolution
        $issues = @($v.AppValidationResponse.ValidationIssueList)
        Write-Host "  validation issues: $($issues.Count)"
        $issues | ForEach-Object { Write-Host "    $($_.ErrorType) $($_.Message)" }
    } catch { Fail 'ValidateApp' $_ }
    try {
        Dv POST 'PublishXml' @{ ParameterXml = "<importexportxml><appmodules><appmodule>$appId</appmodule></appmodules></importexportxml>" } -NoSolution | Out-Null
        Write-Host '  published app'
    } catch { Fail 'PublishXml' $_ }
}
if ($script:failures.Count) { Write-Host "`nFAILURES: $($script:failures.Count)" -ForegroundColor Red; $script:failures | ForEach-Object { Write-Host $_ }; exit 1 }
Write-Host "`nDone." -ForegroundColor Green
