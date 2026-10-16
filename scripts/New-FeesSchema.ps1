<#
  Creates the Phase 6 fee tables in the EduCore DEV solution (idempotent). Amounts are Decimal(2) columns, not Currency:
  FeePlugins.cs reads and writes decimals, and a Money column would need Money values.
  Usage: .\New-FeesSchema.ps1 -TokenFile <file from Get-DvToken.ps1> -OrgUrl https://<your-dev>.crm8.dynamics.com
  Then export with export-solution.ps1.
#>
param(
    [Parameter(Mandatory)][string]$OrgUrl,
    [Parameter(Mandatory)][string]$TokenFile,
    [string]$Solution = 'EduCore',
    [string]$Prefix = 'edu'
)
$ErrorActionPreference = 'Stop'
$api = "$OrgUrl/api/data/v9.2"
$script:failures = New-Object System.Collections.ArrayList
$script:Opt = @{}
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

function L([string]$t) {
    @{ '@odata.type' = 'Microsoft.Dynamics.CRM.Label'
       LocalizedLabels = @(@{ '@odata.type' = 'Microsoft.Dynamics.CRM.LocalizedLabel'; Label = $t; LanguageCode = 1033 }) }
}
function Req([string]$v) { @{ Value = $v; CanBeChanged = $true; ManagedPropertyLogicalName = 'canmodifyrequirementlevelsettings' } }
function Step([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Fail([string]$what, $err) { Write-Host "  FAILED: $what -> $err" -ForegroundColor Red; [void]$script:failures.Add("$what :: $err") }

# ---------------------------------------------------------------- column constructors
function cStr($n, $d, $max = 200, $fmt = 'Text', $req = 'None') { @{ t = 'str'; n = $n; d = $d; max = $max; fmt = $fmt; req = $req } }
function cMemo($n, $d, $max = 4000) { @{ t = 'memo'; n = $n; d = $d; max = $max } }
function cInt($n, $d, $min, $max, $req = 'None') { @{ t = 'int'; n = $n; d = $d; min = $min; max = $max; req = $req } }
function cDec($n, $d, $prec = 2, $req = 'None') { @{ t = 'dec'; n = $n; d = $d; prec = $prec; req = $req } }
function cBool($n, $d, $def = $false) { @{ t = 'bool'; n = $n; d = $d; def = $def } }
function cDT($n, $d) { @{ t = 'dt'; n = $n; d = $d } }
function cDate($n, $d) { @{ t = 'date'; n = $n; d = $d } }
function cPick($n, $d, $opts, $req = 'None') { @{ t = 'pick'; n = $n; d = $d; opts = $opts; req = $req } }
function cAuto($n, $d, $fmt) { @{ t = 'str'; n = $n; d = $d; max = 100; fmt = 'Text'; auto = $fmt; req = 'None' } }

function Build-Attr($entity, $c) {
    $a = @{ SchemaName = "${Prefix}_$($c.n)"; DisplayName = (L $c.d); RequiredLevel = (Req $(if ($c.req) { $c.req } else { 'None' })) }
    switch ($c.t) {
        'str' {
            $a['@odata.type'] = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
            $a.MaxLength = $c.max; $a.FormatName = @{ Value = $c.fmt }
            if ($c.auto) { $a.AutoNumberFormat = $c.auto }
        }
        'memo' { $a['@odata.type'] = 'Microsoft.Dynamics.CRM.MemoAttributeMetadata'; $a.MaxLength = $c.max }
        'int' {
            $a['@odata.type'] = 'Microsoft.Dynamics.CRM.IntegerAttributeMetadata'
            $a.MinValue = $c.min; $a.MaxValue = $c.max; $a.Format = 'None'
        }
        'dec' {
            $a['@odata.type'] = 'Microsoft.Dynamics.CRM.DecimalAttributeMetadata'
            $a.Precision = $c.prec; $a.MinValue = -100000000000; $a.MaxValue = 100000000000
        }
        'bool' {
            $a['@odata.type'] = 'Microsoft.Dynamics.CRM.BooleanAttributeMetadata'
            $a.DefaultValue = [bool]$c.def
            $a.OptionSet = @{ TrueOption = @{ Value = 1; Label = (L 'Yes') }; FalseOption = @{ Value = 0; Label = (L 'No') }; OptionSetType = 'Boolean' }
        }
        'dt' {
            $a['@odata.type'] = 'Microsoft.Dynamics.CRM.DateTimeAttributeMetadata'
            $a.Format = 'DateAndTime'; $a.DateTimeBehavior = @{ Value = 'UserLocal' }
        }
        'date' {
            $a['@odata.type'] = 'Microsoft.Dynamics.CRM.DateTimeAttributeMetadata'
            $a.Format = 'DateOnly'; $a.DateTimeBehavior = @{ Value = 'DateOnly' }
        }
        'pick' {
            $a['@odata.type'] = 'Microsoft.Dynamics.CRM.PicklistAttributeMetadata'
            $opts = @(); $map = @{}
            for ($i = 0; $i -lt $c.opts.Count; $i++) {
                $v = 859680000 + $i; $map[$c.opts[$i]] = $v
                $opts += @{ Value = $v; Label = (L $c.opts[$i]) }
            }
            $script:Opt["$entity.${Prefix}_$($c.n)"] = $map
            $a.OptionSet = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.OptionSetMetadata'; IsGlobal = $false; OptionSetType = 'Picklist'; Options = $opts }
        }
    }
    $a
}

function Add-Column($entity, $c) {
    $logical = "${Prefix}_$($c.n)".ToLower()
    $exists = Dv GET "EntityDefinitions(LogicalName='$entity')/Attributes(LogicalName='$logical')?`$select=MetadataId" -NoSolution -Quiet404
    if ($exists) {
        if ($c.t -eq 'pick') {   # rebuild the option map for seed data
            $null = Build-Attr $entity $c
        }
        Write-Host "  = $entity.$logical exists"; return
    }
    try { Dv POST "EntityDefinitions(LogicalName='$entity')/Attributes" (Build-Attr $entity $c) | Out-Null; Write-Host "  + $entity.$logical" }
    catch { Fail "$entity.$logical" $_ }
}

$PK = @{ contact = 'contactid'; systemuser = 'systemuserid'; appointment = 'activityid'; account = 'accountid' }
function Pk($e) { if ($PK.ContainsKey($e)) { $PK[$e] } else { "${e}id" } }

function Add-Lookup($from, $to, $n, $d, $req = 'None', $del = 'RemoveLink') {
    $logical = "${Prefix}_$n".ToLower()
    $exists = Dv GET "EntityDefinitions(LogicalName='$from')/Attributes(LogicalName='$logical')?`$select=MetadataId" -NoSolution -Quiet404
    if ($exists) { Write-Host "  = $from.$logical exists"; return }
    $rel = "${Prefix}_" + ($from -replace "^${Prefix}_", '') + "_$n"
    $body = @{
        '@odata.type'         = 'Microsoft.Dynamics.CRM.OneToManyRelationshipMetadata'
        SchemaName            = $rel
        ReferencedEntity      = $to
        ReferencedAttribute   = (Pk $to)
        ReferencingEntity     = $from
        CascadeConfiguration  = @{ Assign = 'NoCascade'; Delete = $del; Merge = 'NoCascade'; Reparent = 'NoCascade'; Share = 'NoCascade'; Unshare = 'NoCascade' }
        AssociatedMenuConfiguration = @{ Behavior = 'UseCollectionName'; Group = 'Details'; Order = 10000; IsCustomizable = $true }
        Lookup                = @{
            '@odata.type' = 'Microsoft.Dynamics.CRM.LookupAttributeMetadata'
            AttributeType = 'Lookup'; AttributeTypeName = @{ Value = 'LookupType' }
            SchemaName = "${Prefix}_$n"; DisplayName = (L $d); RequiredLevel = (Req $req)
        }
    }
    try { Dv POST 'RelationshipDefinitions' $body | Out-Null; Write-Host "  + lookup $from.$logical -> $to" }
    catch { Fail "lookup $from.$logical" $_ }
}
function New-Table($n, $d, $plural, $owner, $auto = $null, $notes = $false, $primaryDisplay = 'Name') {
    $logical = "${Prefix}_$n".ToLower()
    $exists = Dv GET "EntityDefinitions(LogicalName='$logical')?`$select=MetadataId" -NoSolution -Quiet404
    if ($exists) { Write-Host "= table $logical exists"; return $logical }
    $prim = @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
        SchemaName = "${Prefix}_name"; IsPrimaryName = $true; DisplayName = (L $primaryDisplay)
        RequiredLevel = (Req 'None'); MaxLength = 200; FormatName = @{ Value = 'Text' }
    }
    if ($auto) { $prim.AutoNumberFormat = $auto }
    $body = @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.EntityMetadata'
        SchemaName = $logical; DisplayName = (L $d); DisplayCollectionName = (L $plural)
        Description = (L "EduCore - $d"); OwnershipType = $owner
        HasNotes = $notes; HasActivities = $false; IsActivity = $false
        PrimaryNameAttribute = "${Prefix}_name"
        IsAuditEnabled = @{ Value = $true; CanBeChanged = $true; ManagedPropertyLogicalName = 'canmodifyauditsettings' }
        Attributes = @($prim)
    }
    try { Dv POST 'EntityDefinitions' $body | Out-Null; Write-Host "+ table $logical" -ForegroundColor Green; Start-Sleep -Seconds 3 }
    catch { Fail "table $logical" $_ }
    return $logical
}

# ================================================================ 1. TABLES + COLUMNS
Step '== Custom tables =='

function Add-Key($entity, $columns) {
    $name = "${Prefix}_" + ($entity -replace "^${Prefix}_", '') + '_key'
    $exists = Dv GET "EntityDefinitions(LogicalName='$entity')/Keys?`$select=SchemaName" -NoSolution
    if ($exists.value | Where-Object { $_.SchemaName -eq $name }) { Write-Host "  = key $name exists"; return }
    try {
        Dv POST "EntityDefinitions(LogicalName='$entity')/Keys" @{
            '@odata.type' = 'Microsoft.Dynamics.CRM.EntityKeyMetadata'; SchemaName = $name; DisplayName = (L 'Unique key'); KeyAttributes = $columns } | Out-Null
        Write-Host "  + key $name"
    } catch { Fail "key $name" $_ }
}

# Fee type is a local choice (Tuition, Transport, Activity) on fee structure and invoice line, not a table.
$fStruct = New-Table 'feestructure' 'Fee Structure' 'Fee Structures' 'OrganizationOwned'
Add-Column $fStruct (cDec 'amount' 'Amount' 2 'ApplicationRequired')
Add-Column $fStruct (cPick 'feetype' 'Fee Type' @('Tuition','Transport','Activity') 'ApplicationRequired')
Add-Column $fStruct (cStr 'uniquekey' 'Unique Key' 200)

# User-owned transactions
$inv = New-Table 'invoice' 'Invoice' 'Invoices' 'UserOwned' 'INV-{SEQNUM:6}' $false 'Invoice Number'
foreach ($c in @(
    (cDec 'totalamount' 'Total Amount'), (cDec 'paidamount' 'Paid Amount'), (cDec 'dueamount' 'Due Amount'),
    (cDate 'duedate' 'Due Date'),
    (cPick 'invoicestatus' 'Status' @('Draft','Sent','Partially Paid','Paid','Overdue') 'ApplicationRequired'),
    (cStr 'uniquekey' 'Unique Key' 200))) { Add-Column $inv $c }

$line = New-Table 'invoiceline' 'Invoice Line' 'Invoice Lines' 'UserOwned'
foreach ($c in @((cDec 'quantity' 'Quantity'), (cDec 'amount' 'Amount'), (cPick 'feetype' 'Fee Type' @('Tuition','Transport','Activity')))) { Add-Column $line $c }

$pay = New-Table 'payment' 'Payment' 'Payments' 'UserOwned'
foreach ($c in @(
    (cDec 'amount' 'Amount' 2 'ApplicationRequired'), (cDate 'paymentdate' 'Payment Date'),
    (cPick 'method' 'Method' @('Cash','Card','Bank Transfer','Cheque','Online')),
    (cStr 'reference' 'Reference' 100),
    (cPick 'paymentstatus' 'Status' @('Cleared','Reversed') 'ApplicationRequired'))) { Add-Column $pay $c }

Step '== Lookups =='
Add-Lookup $fStruct 'edu_grade' 'grade' 'Grade' 'ApplicationRequired'
Add-Lookup $fStruct 'edu_term' 'term' 'Term' 'ApplicationRequired'
Add-Lookup $inv 'edu_student' 'student' 'Student' 'ApplicationRequired'
Add-Lookup $inv 'edu_term' 'term' 'Term' 'ApplicationRequired'
Add-Lookup $line $inv 'invoice' 'Invoice' 'ApplicationRequired' 'Cascade'
Add-Lookup $pay $inv 'invoice' 'Invoice' 'ApplicationRequired' 'Restrict'
Add-Lookup $pay 'edu_staff' 'recordedby' 'Recorded By'

Step '== Alternate keys =='
Start-Sleep -Seconds 10
Add-Key $fStruct @('edu_uniquekey')
Add-Key $inv @('edu_uniquekey')

if ($script:failures.Count) { Write-Host "`n$($script:failures.Count) failure(s):" -ForegroundColor Red; $script:failures | ForEach-Object { Write-Host "  $_" }; exit 1 }
Write-Host "`nDone." -ForegroundColor Green
