<#
  Creates public views (savedquery) in the EduCore DEV solution (idempotent: matches on name + table, PATCHes if present; never deletes).
  Usage: .\New-AppViews.ps1 -TokenFile <file> -OrgUrl https://<your-dev>.crm8.dynamics.com
#>
param(
    [Parameter(Mandatory)][string]$OrgUrl,
    [Parameter(Mandatory)][string]$TokenFile,
    [string]$Solution = 'EduCore'
)
$ErrorActionPreference = 'Stop'
$api = "$OrgUrl/api/data/v9.2"
$script:failures = New-Object System.Collections.ArrayList
$script:token = (Get-Content $TokenFile -Raw).Trim()
function Dv {
    param([string]$Method, [string]$Path, $Body = $null, [switch]$NoSolution)
    $h = @{ Authorization = "Bearer $script:token"; 'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0'; Accept = 'application/json' }
    if (-not $NoSolution) { $h['MSCRM.SolutionUniqueName'] = $Solution }
    $p = @{ Method = $Method; Uri = "$api/$Path"; Headers = $h }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 40 -Compress); $p.ContentType = 'application/json; charset=utf-8' }
    for ($try = 1; $try -le 4; $try++) {
        try { return Invoke-RestMethod @p }
        catch {
            $msg = "$($_.ErrorDetails.Message)"; $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($try -lt 4 -and ($code -ge 500 -or $code -eq 429 -or $msg -match 'lock|in progress|timed out')) { Start-Sleep -Seconds (6 * $try); continue }
            throw "HTTP $code $Method $Path :: $msg"
        }
    }
}
function Step([string]$m) { Write-Host $m -ForegroundColor Cyan }

# Build a view. $cols: array of @(attr, width). $filter: inner <filter> xml. $order: attr.
function View($entity, $pk, $name, $desc, $cols, $filter, $orderAttr, [switch]$desc2) {
    $attrs = ($cols | ForEach-Object { "<attribute name=`"$($_[0])`" />" }) -join ''
    $fetch = "<fetch version=`"1.0`" mapping=`"logical`"><entity name=`"$entity`">$attrs<attribute name=`"$pk`" /><order attribute=`"$orderAttr`" descending=`"$(([string]([bool]$desc2)).ToLower())`" />$filter</entity></fetch>"
    $cells = ($cols | ForEach-Object { "<cell name=`"$($_[0])`" width=`"$($_[1])`" />" }) -join ''
    $layout = "<grid name=`"resultset`" object=`"0`" jump=`"$($cols[0][0])`" select=`"1`" icon=`"1`" preview=`"1`"><row name=`"result`" id=`"$pk`">$cells</row></grid>"
    $body = @{ name = $name; description = $desc; returnedtypecode = $entity; querytype = 0; fetchxml = $fetch; layoutxml = $layout }
    try {
        $q = [uri]::EscapeDataString("name eq '$($name -replace "'","''")' and returnedtypecode eq '$entity' and querytype eq 0")
        $ex = Dv GET "savedqueries?`$select=savedqueryid&`$filter=$q" -NoSolution
        if ($ex.value.Count -gt 0) {
            Dv PATCH "savedqueries($($ex.value[0].savedqueryid))" @{ description = $desc; fetchxml = $fetch; layoutxml = $layout } | Out-Null
            Write-Host "  updated: $name"
        } else {
            Dv POST 'savedqueries' $body | Out-Null
            Write-Host "  created: $name"
        }
    } catch { Write-Host "  FAILED: $name -> $_" -ForegroundColor Red; [void]$script:failures.Add("$name :: $_") }
}

Step '== Views =='
$active = '<condition attribute="statecode" operator="eq" value="0" />'
View 'edu_student' 'edu_studentid' 'Active Students' 'Students with Active status' `
    @(@('edu_name',200),@('edu_studentcode',110),@('edu_currentgrade',120),@('edu_currentsection',120),@('edu_enrolmentdate',110)) `
    "<filter type=`"and`">$active</filter>" 'edu_name'
View 'edu_applicant' 'edu_applicantid' 'Applicants by Status' 'Open applicants, grouped by status' `
    @(@('edu_name',200),@('edu_applicantnumber',120),@('statuscode',120),@('edu_applyinggrade',120),@('edu_applicationdate',110),@('edu_academicyear',120)) `
    "<filter type=`"and`">$active</filter>" 'statuscode'
View 'edu_attendancesummary' 'edu_attendancesummaryid' 'Students Below Attendance Threshold' 'Attendance percentage below 90' `
    @(@('edu_student',200),@('edu_term',120),@('edu_percentage',100),@('edu_present',80),@('edu_absent',80),@('edu_late',80),@('edu_teachingdays',100)) `
    "<filter type=`"and`">$active<condition attribute=`"edu_percentage`" operator=`"lt`" value=`"90`" /></filter>" 'edu_percentage'
View 'edu_invoice' 'edu_invoiceid' 'Overdue Invoices' 'Invoices with Overdue status' `
    @(@('edu_invoicenumber',130),@('edu_student',180),@('edu_term',110),@('edu_duedate',110),@('edu_totalamount',110),@('edu_paidamount',110),@('edu_dueamount',110)) `
    "<filter type=`"and`"><condition attribute=`"edu_invoicestatus`" operator=`"eq`" value=`"859680004`" /></filter>" 'edu_duedate'
View 'edu_reportcard' 'edu_reportcardid' 'Draft Report Cards' 'Report cards in Draft status' `
    @(@('edu_name',200),@('edu_student',180),@('edu_term',110),@('edu_overallpercent',100),@('edu_overallgrade',100),@('edu_generatedon',120)) `
    "<filter type=`"and`"><condition attribute=`"edu_reportstatus`" operator=`"eq`" value=`"859680000`" /></filter>" 'edu_generatedon' -desc2
View 'edu_invoice' 'edu_invoiceid' 'Unpaid Invoices' 'Sent, Partially Paid or Overdue invoices' `
    @(@('edu_invoicenumber',130),@('edu_student',180),@('edu_term',110),@('edu_invoicestatus',110),@('edu_duedate',110),@('edu_totalamount',110),@('edu_dueamount',110)) `
    "<filter type=`"and`"><condition attribute=`"edu_invoicestatus`" operator=`"in`"><value>859680001</value><value>859680002</value><value>859680004</value></condition></filter>" 'edu_duedate'
View 'edu_attendance' 'edu_attendanceid' "Today's Absences" 'Absent attendance records dated today' `
    @(@('edu_student',200),@('edu_date',110),@('edu_attendancetype',120),@('edu_absencereason',200),@('edu_subjectassignment',160),@('edu_recordedby',140)) `
    "<filter type=`"and`"><condition attribute=`"edu_attendancestatus`" operator=`"eq`" value=`"859680002`" /><condition attribute=`"edu_date`" operator=`"today`" /></filter>" 'edu_student'

Step '== Publish =='
try {
    $x = '<importexportxml><entities>' + ((@('edu_student','edu_applicant','edu_attendancesummary','edu_invoice','edu_reportcard','edu_attendance') | % { "<entity>$_</entity>" }) -join '') + '</entities></importexportxml>'
    Dv POST 'PublishXml' @{ ParameterXml = $x } -NoSolution | Out-Null; Write-Host '  published'
} catch { Write-Host "  FAILED publish -> $_" -ForegroundColor Red; [void]$script:failures.Add("publish :: $_") }

if ($script:failures.Count) { Write-Host "`n$($script:failures.Count) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nDone." -ForegroundColor Green
