<#
  End-to-end test of the EduCore business rules against a deployed environment (plug-ins and Custom APIs must be registered).
  It builds its own records (names start with E2E_<stamp>), walks one student from applicant to paid invoice and report card,
  and checks that the rules reject what they must. Nothing is deleted; run it on DEV, TEST or UAT, not PROD.
  Usage: .\Test-EndToEnd.ps1 -OrgUrl https://<env>.crm8.dynamics.com -TokenFile <file from Get-DvToken.ps1>
  Exit code is the number of failed checks.
#>
param(
    [Parameter(Mandatory)][string]$OrgUrl,
    [Parameter(Mandatory)][string]$TokenFile
)
$ErrorActionPreference = 'Stop'
$api = "$OrgUrl/api/data/v9.2"
$h = @{ Authorization = "Bearer $((Get-Content $TokenFile -Raw).Trim())"; 'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0'; Accept = 'application/json'; Prefer = 'return=representation' }
$stamp = Get-Date -Format 'MMddHHmmss'
$tag = "E2E_$stamp"
$pass = 0; $fail = 0

function Call($m, $p, $b = $null) {
    $a = @{ Method = $m; Uri = "$api/$p"; Headers = $h }
    if ($null -ne $b) { $a.Body = ($b | ConvertTo-Json -Depth 8 -Compress); $a.ContentType = 'application/json; charset=utf-8' }
    try { Invoke-RestMethod @a } catch { throw ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue).error.message }
}
function Check($name, $ok, $detail = '') {
    if ($ok) { $script:pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $name $detail" -ForegroundColor Red }
}
function Rejects($name, [scriptblock]$do, $contains) {
    try { & $do | Out-Null; Check $name $false '(was accepted)' }
    catch { Check $name ("$_" -like "*$contains*") "(got: $_)" }
}
$sets = @{}; $navs = @{}
function SetOf($e) { if (-not $sets[$e]) { $sets[$e] = (Call GET "EntityDefinitions(LogicalName='$e')?`$select=EntitySetName").EntitySetName }; $sets[$e] }
function NavOf($e, $attr) {
    if (-not $navs[$e]) {
        $navs[$e] = @{}
        foreach ($r in (Call GET "EntityDefinitions(LogicalName='$e')/ManyToOneRelationships?`$select=ReferencingAttribute,ReferencingEntityNavigationPropertyName").value) { $navs[$e][$r.ReferencingAttribute] = $r.ReferencingEntityNavigationPropertyName }
    }
    $navs[$e][$attr]
}
function Opt($e, $attr, $label) {
    $kind = if ($attr -in 'statuscode') { 'StatusAttributeMetadata' } else { 'PicklistAttributeMetadata' }
    $o = (Call GET "EntityDefinitions(LogicalName='$e')/Attributes(LogicalName='$attr')/Microsoft.Dynamics.CRM.$kind`?`$select=LogicalName&`$expand=OptionSet(`$select=Options)").OptionSet.Options
    if ($label) { return ($o | Where-Object { $_.Label.UserLocalizedLabel.Label -eq $label } | Select-Object -First 1).Value }
    return $o[0].Value
}
# Date-only columns reject a time part, so convert values for those columns using the column's own format.
$dateFmt = @{}
function FixDates($e, $f) {
    if (-not $dateFmt[$e]) {
        $dateFmt[$e] = @{}
        foreach ($a in (Call GET "EntityDefinitions(LogicalName='$e')/Attributes/Microsoft.Dynamics.CRM.DateTimeAttributeMetadata?`$select=LogicalName,Format").value) { $dateFmt[$e][$a.LogicalName] = $a.Format }
    }
    $out = @{}
    foreach ($k in $f.Keys) {
        $v = $f[$k]
        if ($v -is [string] -and $v -match '^\d{4}-\d\d-\d\dT00:00:00Z$' -and $dateFmt[$e][$k] -eq 'DateOnly') { $v = $v.Substring(0, 10) }
        $out[$k] = $v
    }
    return $out
}
# New record: fields plus binds @{ attribute = @('targetEntity', id) }; returns the id.
function New($e, $f, $binds = @{}) {
    $body = FixDates $e $f
    foreach ($k in $binds.Keys) { $body["$(NavOf $e $k)@odata.bind"] = "/$(SetOf $binds[$k][0])($($binds[$k][1]))" }
    $r = Call POST (SetOf $e) $body
    return $r."$e`id"
}
function Patch($e, $id, $f) { Call PATCH "$(SetOf $e)($id)" (FixDates $e $f) | Out-Null }
function Get1($e, $id, $cols) { Call GET "$(SetOf $e)($id)?`$select=$cols" }
function Ref($e, $id) { @{ '@odata.type' = "Microsoft.Dynamics.CRM.$e"; "${e}id" = $id } }
function D($s) { Get-Date $s -Format 'yyyy-MM-ddT00:00:00Z' }

Write-Host "E2E run $tag against $OrgUrl" -ForegroundColor Cyan

# ------------------------------------------------------------------ reference data
Write-Host "`n[1] Reference data"
$year = New 'edu_academicyear' @{ edu_name = "${tag}_Y1"; edu_startdate = (D '2026-06-01'); edu_enddate = (D '2027-05-31'); edu_iscurrent = $true }
$year2 = New 'edu_academicyear' @{ edu_name = "${tag}_Y2"; edu_startdate = (D '2027-06-01'); edu_enddate = (D '2028-05-31'); edu_iscurrent = $true }
Check 'only one current year' ((Get1 'edu_academicyear' $year 'edu_iscurrent').edu_iscurrent -eq $false)
Rejects 'term must sit inside its year' { New 'edu_term' @{ edu_name = "${tag}_bad"; edu_sequence = 9; edu_startdate = (D '2025-01-01'); edu_enddate = (D '2025-03-01') } @{ edu_academicyear = @('edu_academicyear', $year) } } ''
$term = New 'edu_term' @{ edu_name = "${tag}_T1"; edu_sequence = 1; edu_startdate = (D '2026-06-01'); edu_enddate = (D '2026-09-30') } @{ edu_academicyear = @('edu_academicyear', $year) }
$grade = New 'edu_grade' @{ edu_name = "${tag}_G"; edu_sequence = 30 }
$course = New 'edu_course' @{ edu_name = "${tag}_Maths"; edu_coursecode = "M$stamp" }
foreach ($b in @(@('A', 80), @('B', 65), @('C', 50), @('F', 0))) { New 'edu_gradeband' @{ edu_name = "${tag}_$($b[0])"; edu_letter = "$($b[0])$($stamp.Substring(7))"; edu_minpercent = $b[1] } | Out-Null }
$staff = New 'edu_staff' @{ edu_name = "${tag}_Teacher"; edu_staffcode = "T$stamp"; edu_stafftype = (Opt 'edu_staff' 'edu_stafftype' $null); edu_isactive = $true }
$section = New 'edu_section' @{ edu_name = "${tag}_S1"; edu_capacity = 1 } @{ edu_academicyear = @('edu_academicyear', $year); edu_grade = @('edu_grade', $grade); edu_classteacher = @('edu_staff', $staff) }
$assign = New 'edu_subjectassignment' @{ edu_name = "${tag}_Maths S1" } @{ edu_course = @('edu_course', $course); edu_section = @('edu_section', $section); edu_staff = @('edu_staff', $staff); edu_term = @('edu_term', $term) }
Check 'reference data created' ($assign -ne $null)

# ------------------------------------------------------------------ admissions
Write-Host "`n[2] Admissions"
$g1 = New 'contact' @{ firstname = $tag; lastname = 'Guardian1'; mobilephone = '555-0100' }
$g2 = New 'contact' @{ firstname = $tag; lastname = 'Guardian2'; mobilephone = '555-0101' }
function NewApplicant($n, $g) { New 'edu_applicant' @{ edu_name = "${tag}_Applicant$n"; edu_dateofbirth = (D '2018-04-04') } @{ edu_academicyear = @('edu_academicyear', $year); edu_applyinggrade = @('edu_grade', $grade); edu_primaryguardian = @('contact', $g) } }
$a1 = NewApplicant 1 $g1
$a2 = NewApplicant 2 $g2
$sAppUnderReview = Opt 'edu_applicant' 'statuscode' 'Under Review'; $sOffer = Opt 'edu_applicant' 'statuscode' 'Offer Made'
Rejects 'applicant cannot skip to Offer Made' { Patch 'edu_applicant' $a1 @{ statuscode = $sOffer } } ''
foreach ($a in $a1, $a2) { Patch 'edu_applicant' $a @{ statuscode = $sAppUnderReview }; Patch 'edu_applicant' $a @{ statuscode = $sOffer } }
Check 'applicants reach Offer Made' ((Get1 'edu_applicant' $a1 'statuscode').statuscode -eq $sOffer)
$enrol = Call POST 'edu_EnrolApplicant' @{ ApplicantId = (Ref 'edu_applicant' $a1); SectionId = (Ref 'edu_section' $section); StartDate = '2026-06-01T00:00:00Z' }
Check 'EnrolApplicant creates the student' ($enrol.Created -eq $true -and $enrol.StudentId)
$student = $enrol.StudentId
$again = Call POST 'edu_EnrolApplicant' @{ ApplicantId = (Ref 'edu_applicant' $a1); SectionId = (Ref 'edu_section' $section) }
Check 'EnrolApplicant is idempotent' ($again.Created -eq $false -and $again.StudentId -eq $student)
$st = Get1 'edu_student' $student '_edu_currentgrade_value,_edu_currentsection_value'
Check 'student placement is derived from the enrolment' ($st._edu_currentgrade_value -eq $grade -and $st._edu_currentsection_value -eq $section)
Rejects 'section capacity is enforced' { Call POST 'edu_EnrolApplicant' @{ ApplicantId = (Ref 'edu_applicant' $a2); SectionId = (Ref 'edu_section' $section) } } ''

# ------------------------------------------------------------------ attendance
Write-Host "`n[3] Attendance"
$daily = Opt 'edu_attendance' 'edu_attendancetype' 'Daily'; $period = Opt 'edu_attendance' 'edu_attendancetype' 'Period'
$sPresent = Opt 'edu_attendance' 'edu_attendancestatus' 'Present'; $sAbsent = Opt 'edu_attendance' 'edu_attendancestatus' 'Absent'; $sExcused = Opt 'edu_attendance' 'edu_attendancestatus' 'Excused'
function Mark($date, $status, $type = $daily) { New 'edu_attendance' @{ edu_name = "${tag} $date"; edu_date = (D $date); edu_attendancetype = $type; edu_attendancestatus = $status } @{ edu_student = @('edu_student', $student) } }
$first = Mark '2026-06-01' $sPresent
Mark '2026-06-02' $sPresent | Out-Null; Mark '2026-06-03' $sPresent | Out-Null; Mark '2026-06-04' $sAbsent | Out-Null; Mark '2026-06-05' $sExcused | Out-Null
Check 'attendance term is derived from the date' ((Get1 'edu_attendance' $first '_edu_term_value')._edu_term_value -eq $term)
Rejects 'duplicate attendance for the same day' { Mark '2026-06-01' $sAbsent } ''
Rejects 'period attendance needs a subject assignment' { Mark '2026-06-08' $sPresent $period } ''
$ref = Call POST 'edu_RefreshAttendanceSummary' @{ TermId = (Ref 'edu_term' $term); AsOf = '2026-06-12T00:00:00Z' }
$sum = (Call GET "edu_attendancesummaries?`$filter=_edu_student_value eq $student&`$select=edu_teachingdays,edu_present,edu_absent,edu_excused,edu_percentage").value[0]
Check 'summary: 10 teaching days, 3 present, 1 absent, 1 excused' ($sum.edu_teachingdays -eq 10 -and $sum.edu_present -eq 3 -and $sum.edu_absent -eq 1 -and $sum.edu_excused -eq 1) "($($sum | ConvertTo-Json -Compress))"
Check 'summary percentage is 3 / (10 - 1) = 33.33' ([math]::Round([decimal]$sum.edu_percentage, 2) -eq 33.33)

# ------------------------------------------------------------------ marks and report card
Write-Host "`n[4] Marks and report card"
$atype = Opt 'edu_assessment' 'edu_assessmenttype' $null
$as1 = New 'edu_assessment' @{ edu_name = "${tag}_Quiz"; edu_assessmenttype = $atype; edu_maxmarks = 20; edu_weightage = 40; edu_assessmentdate = (D '2026-06-10') } @{ edu_subjectassignment = @('edu_subjectassignment', $assign) }
$as2 = New 'edu_assessment' @{ edu_name = "${tag}_Exam"; edu_assessmenttype = $atype; edu_maxmarks = 10; edu_weightage = 60; edu_assessmentdate = (D '2026-06-11') } @{ edu_subjectassignment = @('edu_subjectassignment', $assign) }
Rejects 'marks above the maximum are rejected' { New 'edu_studentmark' @{ edu_name = "${tag}_m"; edu_marksobtained = 21 } @{ edu_assessment = @('edu_assessment', $as1); edu_student = @('edu_student', $student) } } 'exceed'
$m1 = New 'edu_studentmark' @{ edu_name = "${tag}_m1"; edu_marksobtained = 15 } @{ edu_assessment = @('edu_assessment', $as1); edu_student = @('edu_student', $student) }
New 'edu_studentmark' @{ edu_name = "${tag}_m2"; edu_marksobtained = 8 } @{ edu_assessment = @('edu_assessment', $as2); edu_student = @('edu_student', $student) } | Out-Null
$mk = Get1 'edu_studentmark' $m1 'edu_percentage,edu_gradeletter'
Check 'mark percentage is 75 and a letter is set' ([decimal]$mk.edu_percentage -eq 75 -and $mk.edu_gradeletter)
Rejects 'max marks cannot change once marks exist' { Patch 'edu_assessment' $as1 @{ edu_maxmarks = 25 } } ''
$gen = Call POST 'edu_GenerateReportCards' @{ TermId = (Ref 'edu_term' $term); SectionId = (Ref 'edu_section' $section) }
Check 'GenerateReportCards writes one card' ($gen.Generated -eq 1 -and $gen.Skipped -eq 0)
$card = (Call GET "edu_reportcards?`$filter=_edu_student_value eq $student&`$select=edu_reportcardid,edu_overallpercent,edu_overallgrade,edu_attendancepercent,edu_reportstatus").value[0]
Check 'card overall = (75 x 40 + 80 x 60) / 100 = 78' ([decimal]$card.edu_overallpercent -eq 78) "($($card.edu_overallpercent))"
Check 'card carries the attendance percentage' ([math]::Round([decimal]$card.edu_attendancepercent, 2) -eq 33.33)
$line = (Call GET "edu_reportcardlines?`$filter=_edu_reportcard_value eq $($card.edu_reportcardid)&`$select=edu_reportcardlineid,edu_finalpercent,edu_letter").value
Check 'one line with the subject percent and a letter' ($line.Count -eq 1 -and [decimal]$line[0].edu_finalpercent -eq 78 -and $line[0].edu_letter)
$published = Opt 'edu_reportcard' 'edu_reportstatus' 'Published'
Patch 'edu_reportcard' $card.edu_reportcardid @{ edu_reportstatus = $published }
Check 'a Draft card publishes and is stamped' ($null -ne (Get1 'edu_reportcard' $card.edu_reportcardid 'edu_publishedon').edu_publishedon)
Rejects 'a Published card cannot be changed' { Patch 'edu_reportcard' $card.edu_reportcardid @{ edu_overallgrade = 'X' } } 'published'
Rejects 'a Published card line cannot be changed' { Patch 'edu_reportcardline' $line[0].edu_reportcardlineid @{ edu_letter = 'X' } } 'published'
$gen2 = Call POST 'edu_GenerateReportCards' @{ TermId = (Ref 'edu_term' $term); SectionId = (Ref 'edu_section' $section) }
Check 'regenerating skips the Published card' ($gen2.Skipped -eq 1 -and $gen2.Generated -eq 0)

# ------------------------------------------------------------------ fees
Write-Host "`n[5] Fees"
$tuition = Opt 'edu_feestructure' 'edu_feetype' 'Tuition'; $transport = Opt 'edu_feestructure' 'edu_feetype' 'Transport'
foreach ($f in @(@($tuition, 1000), @($transport, 200))) { New 'edu_feestructure' @{ edu_name = "${tag}_fee$($f[0])"; edu_feetype = $f[0]; edu_amount = $f[1] } @{ edu_grade = @('edu_grade', $grade); edu_term = @('edu_term', $term) } | Out-Null }
Patch 'edu_student' $student @{ edu_feeconcessionpercent = 10 }
$inv = Call POST 'edu_GenerateInvoice' @{ StudentId = (Ref 'edu_student' $student); TermId = (Ref 'edu_term' $term) }
Check 'GenerateInvoice creates a Draft invoice' ($inv.Created -eq $true -and $inv.InvoiceId)
$iv = Get1 'edu_invoice' $inv.InvoiceId 'edu_totalamount,edu_paidamount,edu_dueamount,edu_invoicestatus'
Check 'total is (1000 + 200) less 10% = 1080' ([decimal]$iv.edu_totalamount -eq 1080 -and [decimal]$iv.edu_dueamount -eq 1080) "($($iv | ConvertTo-Json -Compress))"
Check 'invoice generation is idempotent' ((Call POST 'edu_GenerateInvoice' @{ StudentId = (Ref 'edu_student' $student); TermId = (Ref 'edu_term' $term) }).Created -eq $false)
$cleared = Opt 'edu_payment' 'edu_paymentstatus' 'Cleared'; $reversed = Opt 'edu_payment' 'edu_paymentstatus' 'Reversed'; $method = Opt 'edu_payment' 'edu_method' $null
function Pay($amt) { New 'edu_payment' @{ edu_name = "${tag}_pay$amt"; edu_amount = $amt; edu_paymentstatus = $cleared; edu_method = $method; edu_paymentdate = (D '2026-06-20') } @{ edu_invoice = @('edu_invoice', $inv.InvoiceId) } }
Rejects 'no payment on a Draft invoice' { Pay 100 } 'invoice'
$lineId = (Call GET "edu_invoicelines?`$filter=_edu_invoice_value eq $($inv.InvoiceId)&`$select=edu_invoicelineid&`$top=1").value[0].edu_invoicelineid
Patch 'edu_invoiceline' $lineId @{ edu_amount = 900 }   # still a Draft, so allowed
Check 'a Draft line can be edited and the total follows' ([decimal](Get1 'edu_invoice' $inv.InvoiceId 'edu_totalamount').edu_totalamount -ne 1080)
Patch 'edu_invoiceline' $lineId @{ edu_amount = (Get1 'edu_invoiceline' $lineId 'edu_amount').edu_amount }
$total = [decimal](Get1 'edu_invoice' $inv.InvoiceId 'edu_totalamount').edu_totalamount
Patch 'edu_invoice' $inv.InvoiceId @{ edu_invoicestatus = (Opt 'edu_invoice' 'edu_invoicestatus' 'Sent') }
Rejects 'lines are fixed once the invoice is sent' { Patch 'edu_invoiceline' $lineId @{ edu_amount = 1 } } 'draft'
$p1 = Pay 500
$iv = Get1 'edu_invoice' $inv.InvoiceId 'edu_paidamount,edu_dueamount,edu_invoicestatus'
Check 'part payment: Partially Paid, due follows' ($iv.edu_invoicestatus -eq (Opt 'edu_invoice' 'edu_invoicestatus' 'Partially Paid') -and [decimal]$iv.edu_paidamount -eq 500 -and [decimal]$iv.edu_dueamount -eq ($total - 500))
Rejects 'a payment above the amount due is rejected' { Pay ($total) } 'more than'
Pay ($total - 500) | Out-Null
Check 'full payment: Paid, nothing due' ((Get1 'edu_invoice' $inv.InvoiceId 'edu_invoicestatus,edu_dueamount').edu_invoicestatus -eq (Opt 'edu_invoice' 'edu_invoicestatus' 'Paid'))
Patch 'edu_payment' $p1 @{ edu_paymentstatus = $reversed }
$iv = Get1 'edu_invoice' $inv.InvoiceId 'edu_paidamount,edu_invoicestatus'
Check 'reversing a payment reopens the invoice' ($iv.edu_invoicestatus -eq (Opt 'edu_invoice' 'edu_invoicestatus' 'Partially Paid') -and [decimal]$iv.edu_paidamount -eq ($total - 500))
Rejects 'a payment cannot be deleted' { Call DELETE "edu_payments($p1)" } 'reverse'
Rejects 'a reversed payment cannot be reinstated' { Patch 'edu_payment' $p1 @{ edu_paymentstatus = $cleared } } 'reinstated'

Write-Host "`n$pass passed, $fail failed  ($tag)" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $fail
