<#
  Phase 9 (LLD section 6) in the EduCore DEV solution. Idempotent; deletes nothing.
    1. Security roles per persona, built from the Basic User role's base privileges plus the table matrix below.
    2. Teams (one per persona) with their role.
    3. Column security (EDU Identity, EDU Finance) on student.edu_nationalid and student.edu_feeconcessionpercent.
    4. Auditing on the tables the LLD lists.
  -Verify only compares each role's privileges with the matrix and reports differences.
  Usage: .\New-Security.ps1 -OrgUrl https://<your-dev>.crm8.dynamics.com -TokenFile <file from Get-DvToken.ps1> [-Verify]
#>
param(
    [Parameter(Mandatory)][string]$OrgUrl,
    [Parameter(Mandatory)][string]$TokenFile,
    [string]$Solution = 'EduCore',
    [switch]$Verify
)
$ErrorActionPreference = 'Stop'
$api = "$OrgUrl/api/data/v9.2"
$h = @{ Authorization = "Bearer $((Get-Content $TokenFile -Raw).Trim())"; 'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0'; Accept = 'application/json' }
function Dv($m, $p, $b = $null, $extra = @{}) {
    $a = @{ Method = $m; Uri = "$api/$p"; Headers = ($h + $extra) }
    if ($null -ne $b) { $a.Body = ($b | ConvertTo-Json -Depth 40 -Compress); $a.ContentType = 'application/json; charset=utf-8' }
    for ($try = 1; $try -le 3; $try++) {
        try { return Invoke-RestMethod @a } catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($try -lt 3 -and ($code -ge 500 -or $code -eq 429)) { Start-Sleep -Seconds (5 * $try); continue }
            throw "HTTP $code $m $p :: $($_.ErrorDetails.Message)"
        }
    }
}
$sol = @{ 'MSCRM.SolutionUniqueName' = $Solution }
$script:problems = New-Object System.Collections.ArrayList

# ------------------------------------------------------------------ the matrix (LLD section 6)
# Spec: 'CRWD:O' = those rights at that scope (O organisation, U owner only); several parts joined with ';'.
$groups = [ordered]@{
    reference  = 'edu_academicyear', 'edu_term', 'edu_calendarday', 'edu_grade', 'edu_course', 'edu_period', 'edu_gradeband'
    applicants = 'edu_applicant'
    people     = 'edu_student', 'contact', 'edu_studentguardian'
    enrolment  = 'edu_enrolment'
    structure  = 'edu_section', 'edu_subjectassignment', 'edu_staff'
    schedule   = 'edu_classschedule'
    attendance = 'edu_attendance'
    attsummary = 'edu_attendancesummary'
    marks      = 'edu_assessment', 'edu_studentmark'
    reportcard = 'edu_reportcard', 'edu_reportcardline'
    finance    = 'edu_feestructure', 'edu_invoice', 'edu_invoiceline', 'edu_payment'
    notiflog   = 'edu_notificationlog'
}
$roles = [ordered]@{
    'EDU - Front Office' = @{ reference = 'R:O'; applicants = 'CRW:O'; people = 'CRW:O'; enrolment = 'CRW:O'; structure = 'R:O'; schedule = 'R:O'; attendance = 'CRW:O'; attsummary = 'R:O'; notiflog = 'R:O' }
    'EDU - Teacher' = @{ reference = 'R:O'; people = 'R:O'; enrolment = 'R:O'; structure = 'R:O'; schedule = 'R:O'; attendance = 'R:O;CW:U'; attsummary = 'R:O'; marks = 'CRWD:U'; reportcard = 'R:O;W:U'; notiflog = 'R:O' }
    'EDU - Academic Coordinator' = @{ reference = 'CRWD:O'; applicants = 'R:O'; people = 'RW:O'; enrolment = 'CRWD:O'; structure = 'CRWD:O'; schedule = 'CRWD:O'; attendance = 'CRWD:O'; attsummary = 'R:O'; marks = 'R:O'; reportcard = 'CRWD:O'; notiflog = 'R:O' }
    'EDU - Finance Officer' = @{ reference = 'R:O'; people = 'R:O'; enrolment = 'R:O'; finance = 'CRW:O'; notiflog = 'R:O' }
    'EDU - Principal' = @{ reference = 'R:O'; applicants = 'R:O'; people = 'R:O'; enrolment = 'R:O'; structure = 'R:O'; schedule = 'R:O'; attendance = 'R:O'; attsummary = 'R:O'; marks = 'R:O'; reportcard = 'R:O'; finance = 'R:O'; notiflog = 'R:O' }
}
$rightName = @{ C = 'Create'; R = 'Read'; W = 'Write'; D = 'Delete' }
$depthName = @{ O = 'Global'; U = 'Basic' }
$depthRank = @{ Basic = 0; Local = 1; Deep = 2; Global = 3 }

# Expected privilege name -> depth for one role.
function Get-Expected($spec) {
    $want = @{}
    foreach ($tables in $groups.Keys) {
        if (-not $spec.ContainsKey($tables)) { continue }
        foreach ($t in $groups[$tables]) {
            $top = -1
            foreach ($part in $spec[$tables].Split(';')) {
                $rights, $scope = $part.Split(':'); $d = $depthName[$scope]
                foreach ($r in $rights.ToCharArray()) {
                    $key = "prv$($rightName[[string]$r])$t"
                    if (-not $want.ContainsKey($key) -or $depthRank[$d] -gt $depthRank[$want[$key]]) { $want[$key] = $d }
                    if ('CW'.Contains([string]$r) -and $depthRank[$d] -gt $top) { $top = $depthRank[$d] }
                }
            }
            # Lookups need Append on the source and AppendTo on the target; readers get AppendTo so others can point at them.
            $writeDepth = if ($top -ge 0) { @('Basic', 'Local', 'Deep', 'Global')[$top] } else { $null }
            if ($writeDepth) { $want["prvAppend$t"] = $writeDepth }
            $want["prvAppendTo$t"] = 'Global'
        }
    }
    return $want
}

# ------------------------------------------------------------------ resolve the business unit and Basic User base
$bu = (Dv GET "businessunits?`$filter=parentbusinessunitid eq null&`$select=businessunitid").value[0].businessunitid
$basic = (Dv GET "roles?`$filter=name eq 'Basic User' and businessunitid/businessunitid eq $bu&`$select=roleid").value[0]
$privCache = @{}
function Get-PrivId($name) {
    if (-not $privCache.ContainsKey($name)) { $privCache[$name] = (Dv GET "privileges?`$filter=name eq '$name'&`$select=privilegeid").value | Select-Object -First 1 -ExpandProperty privilegeid }
    return $privCache[$name]
}

foreach ($roleName in $roles.Keys) {
    $want = Get-Expected $roles[$roleName]
    $role = (Dv GET "roles?`$filter=name eq '$roleName' and businessunitid/businessunitid eq $bu&`$select=roleid").value | Select-Object -First 1

    if ($Verify) {
        if (-not $role) { [void]$script:problems.Add("$roleName is missing"); continue }
        $have = @{}
        foreach ($p in (Dv GET "roles($($role.roleid))/roleprivileges_association?`$select=name").value) { $have[$p.name] = $true }
        $levels = (Dv GET "RetrieveRolePrivilegesRole(RoleId=$($role.roleid))").RolePrivileges
        $depthOf = @{}; foreach ($l in $levels) { $depthOf[$l.PrivilegeId] = $l.Depth }
        foreach ($k in $want.Keys) {
            $id = Get-PrivId $k
            if (-not $id) { continue }   # table not in DEV (for example the notification log)
            if (-not $depthOf.ContainsKey($id)) { [void]$script:problems.Add("$roleName lacks $k") }
            elseif ($depthOf[$id] -ne $want[$k]) { [void]$script:problems.Add("$roleName $k is $($depthOf[$id]), expected $($want[$k])") }
        }
        # Denials: no edu table privilege beyond the matrix.
        $allowed = $want.Keys
        foreach ($l in $levels) {
            $pn = (Dv GET "privileges($($l.PrivilegeId))?`$select=name").name
            if ($pn -match '^prv(Create|Read|Write|Delete)edu_' -and $allowed -notcontains $pn) { [void]$script:problems.Add("$roleName has unexpected $pn") }
        }
        Write-Host "checked $roleName"
        continue
    }

    if (-not $role) {
        $role = Dv POST 'roles' @{ name = $roleName; 'businessunitid@odata.bind' = "/businessunits($bu)" } $sol
        $role = (Dv GET "roles?`$filter=name eq '$roleName' and businessunitid/businessunitid eq $bu&`$select=roleid").value[0]
        Write-Host "+ role $roleName"
    } else { Write-Host "= role $roleName exists" }
    # Base privileges from Basic User so the app opens (re-added every run; Add never removes anything).
    $base = (Dv GET "RetrieveRolePrivilegesRole(RoleId=$($basic.roleid))").RolePrivileges
    $baseList = @($base | ForEach-Object { @{ PrivilegeId = $_.PrivilegeId; Depth = $_.Depth; BusinessUnitId = $bu } })
    Dv POST "roles($($role.roleid))/Microsoft.Dynamics.CRM.AddPrivilegesRole" @{ Privileges = $baseList } | Out-Null

    $list = @()
    foreach ($k in $want.Keys) {
        $id = Get-PrivId $k
        if (-not $id) { Write-Host "  - skip $k (not in this environment)"; continue }
        $list += @{ PrivilegeId = $id; Depth = $want[$k]; BusinessUnitId = $bu }
    }
    # Removing first keeps a re-run exact: drop edu privileges that are not in the matrix.
    $current = (Dv GET "RetrieveRolePrivilegesRole(RoleId=$($role.roleid))").RolePrivileges
    foreach ($c in $current) {
        $pn = (Dv GET "privileges($($c.PrivilegeId))?`$select=name").name
        if ($pn -match '^prv(Create|Read|Write|Delete|Append|AppendTo|Assign|Share)edu_' -and -not $want.ContainsKey($pn)) {
            Dv POST "roles($($role.roleid))/Microsoft.Dynamics.CRM.RemovePrivilegeRole" @{ PrivilegeId = $c.PrivilegeId } | Out-Null
            Write-Host "  - removed $pn"
        }
    }
    Dv POST "roles($($role.roleid))/Microsoft.Dynamics.CRM.AddPrivilegesRole" @{ Privileges = $list } | Out-Null
    Write-Host "  set $($list.Count) edu privileges on $roleName"
}

if ($Verify) {
    if ($script:problems.Count) { Write-Host "`n$($script:problems.Count) difference(s):" -ForegroundColor Red; $script:problems | ForEach-Object { Write-Host "  $_" }; exit 1 }
    Write-Host "`nAll roles match the matrix." -ForegroundColor Green; return
}

# ------------------------------------------------------------------ teams (one per persona), each holding its role
$teamFor = [ordered]@{ 'EDU Front Office' = 'EDU - Front Office'; 'EDU Teachers' = 'EDU - Teacher'; 'EDU Coordinators' = 'EDU - Academic Coordinator'; 'EDU Finance Officers' = 'EDU - Finance Officer'; 'EDU Principals' = 'EDU - Principal' }
$teamIds = @{}
foreach ($t in $teamFor.Keys) {
    $team = (Dv GET "teams?`$filter=name eq '$t'&`$select=teamid").value | Select-Object -First 1
    if (-not $team) {
        Dv POST 'teams' @{ name = $t; teamtype = 0; membershiptype = 0; 'businessunitid@odata.bind' = "/businessunits($bu)" } | Out-Null
        $team = (Dv GET "teams?`$filter=name eq '$t'&`$select=teamid").value[0]
        Write-Host "+ team $t"
    } else { Write-Host "= team $t exists" }
    $teamIds[$t] = $team.teamid
    $roleId = (Dv GET "roles?`$filter=name eq '$($teamFor[$t])' and businessunitid/businessunitid eq $bu&`$select=roleid").value[0].roleid
    try { Dv POST "teams($($team.teamid))/teamroles_association/`$ref" @{ '@odata.id' = "$api/roles($roleId)" } | Out-Null; Write-Host "  role linked" } catch { if ("$_" -notmatch 'already exists|duplicate|0x80040237') { throw } }
}

# ------------------------------------------------------------------ column security
$secured = @(
    @{ Profile = 'EDU Identity'; Column = 'edu_nationalid'; Teams = 'EDU Front Office', 'EDU Coordinators' }
    @{ Profile = 'EDU Finance'; Column = 'edu_feeconcessionpercent'; Teams = 'EDU Finance Officers' }
)
foreach ($s in $secured) {
    $attr = Dv GET "EntityDefinitions(LogicalName='edu_student')/Attributes(LogicalName='$($s.Column)')"
    if (-not $attr.IsSecured) {
        $attr.IsSecured = $true
        Dv PUT "EntityDefinitions(LogicalName='edu_student')/Attributes(LogicalName='$($s.Column)')" $attr @{ 'MSCRM.MergeLabels' = 'true'; 'MSCRM.SolutionUniqueName' = $Solution } | Out-Null
        Write-Host "+ secured edu_student.$($s.Column)"
    }
    $prof = (Dv GET "fieldsecurityprofiles?`$filter=name eq '$($s.Profile)'&`$select=fieldsecurityprofileid").value | Select-Object -First 1
    if (-not $prof) {
        Dv POST 'fieldsecurityprofiles' @{ name = $s.Profile } $sol | Out-Null
        $prof = (Dv GET "fieldsecurityprofiles?`$filter=name eq '$($s.Profile)'&`$select=fieldsecurityprofileid").value[0]
        Write-Host "+ profile $($s.Profile)"
    }
    $perm = (Dv GET "fieldpermissions?`$filter=_fieldsecurityprofileid_value eq $($prof.fieldsecurityprofileid) and attributelogicalname eq '$($s.Column)'&`$select=fieldpermissionid").value | Select-Object -First 1
    if (-not $perm) {
        Dv POST 'fieldpermissions' @{ 'fieldsecurityprofileid@odata.bind' = "/fieldsecurityprofiles($($prof.fieldsecurityprofileid))"; entityname = 'edu_student'; attributelogicalname = $s.Column; canread = 4; cancreate = 4; canupdate = 4 } | Out-Null
        Write-Host "  permission on $($s.Column)"
    }
    foreach ($tn in $s.Teams) {
        try { Dv POST "fieldsecurityprofiles($($prof.fieldsecurityprofileid))/teamprofiles_association/`$ref" @{ '@odata.id' = "$api/teams($($teamIds[$tn]))" } | Out-Null; Write-Host "  $($s.Profile) -> $tn" }
        catch { if ("$_" -notmatch 'already exists|duplicate|0x80040237') { throw } }
    }
}

# ------------------------------------------------------------------ auditing
$audit = 'edu_student', 'edu_studentguardian', 'edu_applicant', 'edu_enrolment', 'edu_attendance', 'edu_studentmark', 'edu_reportcard', 'edu_invoice', 'edu_payment'
foreach ($t in $audit) {
    $e = Dv GET "EntityDefinitions(LogicalName='$t')"
    if ($e.IsAuditEnabled.Value) { Write-Host "= audit on $t"; continue }
    $e.IsAuditEnabled.Value = $true
    Dv PUT "EntityDefinitions($($e.MetadataId))" $e @{ 'MSCRM.MergeLabels' = 'true'; 'MSCRM.SolutionUniqueName' = $Solution } | Out-Null
    Write-Host "+ audit on $t"
}
Dv POST 'PublishAllXml' @{} | Out-Null
Write-Host 'Published. Run again with -Verify to compare the roles with the matrix.'
