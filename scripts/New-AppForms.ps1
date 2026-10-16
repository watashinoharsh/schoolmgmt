<#
  Creates/updates the EduCore Main and Quick Create forms (systemform) in DEV (idempotent, never deletes).
  Existing main/quick-create form of a table is updated in place (renamed 'EduCore Main'/'EduCore Quick Create'); otherwise one is created.
  Usage: .\New-AppForms.ps1 -TokenFile <token file> -OrgUrl https://<your-dev>.crm8.dynamics.com
  Then export with export-solution.ps1.
#>
param(
    [Parameter(Mandatory)][string]$OrgUrl,
    [string]$TokenFile = "$env:LOCALAPPDATA\Temp\dvtoken.txt",
    [string]$Solution = 'EduCore'
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
        $p.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 40 -Compress))
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

# ---------------------------------------------------------------- form builders
$script:Cls = @{
    String='{4273EDBD-AC1D-40d3-9FB2-095C621B552D}'; Memo='{4273EDBD-AC1D-40d3-9FB2-095C621B552D}'
    Lookup='{270BD3DB-D9AF-4782-9025-509E298DEC0A}'; Customer='{270BD3DB-D9AF-4782-9025-509E298DEC0A}'; Owner='{270BD3DB-D9AF-4782-9025-509E298DEC0A}'
    DateTime='{5B773807-9FB2-42DB-97C3-7A91EFF8ADFF}'; Picklist='{3EF39988-22BB-4F0B-BBBE-64B5A3748AEE}'
    Status='{5D68B988-0661-4DB2-BC3E-17598AD3BE6C}'; State='{5D68B988-0661-4DB2-BC3E-17598AD3BE6C}'
    Decimal='{C3EFE0C3-0EC6-42BE-8349-CBD9079AFDE7}'; Double='{0D2C745A-E5A8-4C8F-BA63-C6D3BB604660}'
    Integer='{C6D124CA-7EDA-4A60-AEA9-7FB8D318B68F}'; Money='{533B9E00-756B-4312-95A0-DC888637AC78}'
    Boolean='{67FAC785-CD58-4F9F-ABB3-4B7DDC6ED5ED}'
}
$script:SubgridCls = '{E7A81278-8635-4d9e-8D4D-59480B391C5B}'
$script:AttrCache = @{}
function Get-Attrs($ent) {
    if (-not $script:AttrCache[$ent]) {
        $r = Dv GET "EntityDefinitions(LogicalName='$ent')/Attributes?`$select=LogicalName,AttributeType,DisplayName" -NoSolution
        $m = @{}
        foreach ($a in $r.value) {
            $lbl = $a.DisplayName.UserLocalizedLabel.Label; if (-not $lbl) { $lbl = $a.LogicalName }
            $m[$a.LogicalName] = @{ type = "$($a.AttributeType)"; label = $lbl }
        }
        $script:AttrCache[$ent] = $m
    }
    $script:AttrCache[$ent]
}
function X([string]$s) { [System.Security.SecurityElement]::Escape($s) }
function G { '{' + [guid]::NewGuid().ToString().ToUpper() + '}' }
function Get-ViewId($ent) {
    $r = Dv GET "savedqueries?`$select=savedqueryid,isdefault&`$filter=returnedtypecode eq '$ent' and querytype eq 0 and statecode eq 0" -NoSolution
    $v = @($r.value | Sort-Object { if ($_.isdefault) { 0 } else { 1 } })
    if ($v.Count -eq 0) { throw "no public view for $ent" }
    '{' + $v[0].savedqueryid.ToUpper() + '}'
}
# field spec: 'logical' or 'logical!' for read-only
function Cell-Field($ent, [string]$f) {
    $ro = $f.EndsWith('!'); $f = $f.TrimEnd('!')
    $at = (Get-Attrs $ent)[$f]
    if (-not $at) { throw "attribute $f not on $ent" }
    $cls = $script:Cls[$at.type]; if (-not $cls) { $cls = $script:Cls.String }
    $dis = if ($ro) { ' disabled="true"' } else { '' }
    "<cell id=`"$(G)`" showlabel=`"true`"><labels><label description=`"$(X $at.label)`" languagecode=`"1033`" /></labels><control id=`"$f`" classid=`"$cls`" datafieldname=`"$f`"$dis /></cell>"
}
function Cell-Grid([string]$rel, [string]$target, [string]$label) {
    $vid = Get-ViewId $target
    $id = "sg_$($rel -replace '[^a-z0-9_]','')"
    "<cell id=`"$(G)`" showlabel=`"false`" rowspan=`"6`" colspan=`"1`"><labels><label description=`"$(X $label)`" languagecode=`"1033`" /></labels>" +
    "<control id=`"$id`" classid=`"$script:SubgridCls`"><parameters><ViewId>$vid</ViewId><IsUserView>false</IsUserView><RelationshipName>$rel</RelationshipName><TargetEntityType>$target</TargetEntityType><AutoExpand>Fixed</AutoExpand><EnableQuickFind>false</EnableQuickFind><EnableViewPicker>false</EnableViewPicker><ViewIds>$vid</ViewIds><EnableJumpBar>false</EnableJumpBar><ChartGridMode>Grid</ChartGridMode><VisualizationId /><IsUserChart>false</IsUserChart><EnableChartPicker>false</EnableChartPicker><RecordsPerPage>10</RecordsPerPage></parameters></control></cell>"
}
function Section($name, $rowsXml) { "<section name=`"sec_$($name -replace '[^A-Za-z0-9]','')`" showlabel=`"true`" showbar=`"false`" columns=`"1`" id=`"$(G)`"><labels><label description=`"$(X $name)`" languagecode=`"1033`" /></labels><rows>$rowsXml</rows></section>" }
function Rows($cells) { (@($cells) | ForEach-Object { "<row>$_</row>" }) -join '' }
function Tab($name, $sections) {
    "<tab name=`"tab_$($name -replace '[^A-Za-z0-9]','')`" verticallayout=`"true`" id=`"$(G)`" IsUserDefined=`"0`" expanded=`"true`"><labels><label description=`"$(X $name)`" languagecode=`"1033`" /></labels><columns><column width=`"100%`"><sections>$sections</sections></column></columns></tab>"
}
function FieldTab($ent, $name, $fields) { Tab $name (Section $name (Rows ($fields | ForEach-Object { Cell-Field $ent $_ }))) }
function GridTab($name, $grids) { Tab $name (Section $name (Rows $grids)) }
function Main-Xml($tabs) { "<form><tabs>$($tabs -join '')</tabs></form>" }

function Upsert-Form($ent, [int]$type, [string]$xml, [string]$desc) {
    $name = if ($type -eq 7) { 'EduCore Quick Create' } else { 'EduCore Main' }
    try {
        $r = Dv GET "systemforms?`$select=formid,name&`$filter=objecttypecode eq '$ent' and type eq $type" -NoSolution
        $ex = @($r.value | Where-Object { $_.name -eq $name }); if ($ex.Count -eq 0) { $ex = @($r.value) }
        $body = @{ name = $name; description = $desc; formxml = $xml }
        if ($ex.Count -gt 0) {
            Dv PATCH "systemforms($($ex[0].formid))" $body | Out-Null
            Write-Host "  updated $ent type $type"
        } else {
            $body.type = $type; $body.objecttypecode = $ent; $body.formactivationstate = 1
            Dv POST 'systemforms' $body | Out-Null
            Write-Host "  created $ent type $type"
        }
        return $true
    } catch { Fail "$ent type $type" $_; return $false }
}

$done = New-Object System.Collections.ArrayList
function Run([string]$ent, [int]$type, [scriptblock]$build, [string]$desc) {
    Step "$ent ($type)"
    try { $xml = & $build } catch { Fail "$ent build" $_; return }
    if (Upsert-Form $ent $type $xml $desc) { [void]$done.Add($ent) }
}

# ---------------------------------------------------------------- definitions
Run 'edu_student' 2 {
    Main-Xml @(
        (FieldTab 'edu_student' 'Summary' @('edu_name','edu_studentcode','edu_dateofbirth','edu_gender','edu_nationalid','edu_currentgrade!','edu_currentsection!','edu_enrolmentdate','edu_feeconcessionpercent','edu_sourceapplicant','ownerid')),
        (GridTab 'Guardians' @(Cell-Grid 'edu_studentguardian_student' 'edu_studentguardian' 'Guardians')),
        (GridTab 'Enrolment history' @(Cell-Grid 'edu_enrolment_student' 'edu_enrolment' 'Enrolment history')),
        (GridTab 'Attendance' @((Cell-Grid 'edu_attendancesummary_student' 'edu_attendancesummary' 'Attendance summary'), (Cell-Grid 'edu_attendance_student' 'edu_attendance' 'Attendance records'))),
        (GridTab 'Marks and reports' @((Cell-Grid 'edu_studentmark_student' 'edu_studentmark' 'Marks'), (Cell-Grid 'edu_reportcard_student' 'edu_reportcard' 'Report cards'))),
        (GridTab 'Fees' @(Cell-Grid 'edu_invoice_student' 'edu_invoice' 'Invoices'))
    )
} 'EduCore student main form'

Run 'edu_applicant' 2 {
    Main-Xml @((FieldTab 'edu_applicant' 'Summary' @('edu_name','edu_applicantnumber','edu_dateofbirth','edu_academicyear','edu_applyinggrade','edu_previousschool','edu_primaryguardian','edu_applicationdate','edu_offerdate','edu_decisionreason','statuscode','ownerid')))
} 'EduCore applicant main form'

Run 'edu_invoice' 2 {
    Main-Xml @(
        (FieldTab 'edu_invoice' 'Summary' @('edu_name','edu_invoicenumber','edu_student','edu_billtoguardian','edu_term','edu_invoicestatus','edu_duedate','edu_totalamount!','edu_paidamount!','edu_dueamount!','ownerid')),
        (GridTab 'Lines' @(Cell-Grid 'edu_invoiceline_invoice' 'edu_invoiceline' 'Invoice lines')),
        (GridTab 'Payments' @(Cell-Grid 'edu_payment_invoice' 'edu_payment' 'Payments'))
    )
} 'EduCore invoice main form'

Run 'edu_reportcard' 2 {
    Main-Xml @(
        (FieldTab 'edu_reportcard' 'Summary' @('edu_name','edu_student','edu_term','edu_reportstatus','edu_overallpercent','edu_overallgrade','edu_attendancepercent','edu_generatedon','edu_publishedon','ownerid')),
        (GridTab 'Lines' @(Cell-Grid 'edu_reportcardline_reportcard' 'edu_reportcardline' 'Report card lines'))
    )
} 'EduCore report card main form'

Run 'edu_payment' 7 { Main-Xml @((FieldTab 'edu_payment' 'General' @('edu_name','edu_invoice','edu_amount','edu_paymentdate','edu_method','edu_reference'))) } 'EduCore payment quick create'
Run 'edu_attendance' 7 { Main-Xml @((FieldTab 'edu_attendance' 'General' @('edu_student','edu_date','edu_attendancestatus','edu_attendancetype','edu_absencereason'))) } 'EduCore attendance quick create'

# ---------------------------------------------------------------- publish
Step 'Publish'
try {
    $ents = (@($done | Select-Object -Unique) | ForEach-Object { "<entity>$_</entity>" }) -join ''
    Dv POST 'PublishXml' @{ ParameterXml = "<importexportxml><entities>$ents</entities></importexportxml>" } -NoSolution | Out-Null
    Write-Host 'published'
} catch { Fail 'publish' $_ }
Write-Host "Failures: $($script:failures.Count)"
$script:failures
