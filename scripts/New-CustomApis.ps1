<#
  Creates Custom API definitions (with their request parameters and response properties) in a Dataverse environment from the
  unpacked source under solutions\EduCore\src\customapis. Idempotent: an API that already exists is skipped. Nothing is deleted.
  The APIs are created unbound to a plug-in; bind the plug-in type once the plug-in package is registered.
  Usage: .\New-CustomApis.ps1 -OrgUrl https://<your-dev>.crm8.dynamics.com -TokenFile <file from Get-DvToken.ps1> [-Names edu_GenerateInvoice,edu_GenerateReportCards]
#>
param(
    [Parameter(Mandatory)][string]$OrgUrl,
    [Parameter(Mandatory)][string]$TokenFile,
    [string[]]$Names = @('edu_GenerateInvoice', 'edu_GenerateReportCards'),
    [string]$Solution = 'EduCore'
)
$ErrorActionPreference = 'Stop'
$api = "$OrgUrl/api/data/v9.2"
$h = @{ Authorization = "Bearer $((Get-Content $TokenFile -Raw).Trim())"; 'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0'; Accept = 'application/json'; 'MSCRM.SolutionUniqueName' = $Solution }
function Dv($m, $p, $b = $null) {
    $a = @{ Method = $m; Uri = "$api/$p"; Headers = $h }
    if ($null -ne $b) { $a.Body = ($b | ConvertTo-Json -Depth 10 -Compress); $a.ContentType = 'application/json; charset=utf-8' }
    try { Invoke-RestMethod @a } catch { throw "HTTP $m $p :: $($_.ErrorDetails.Message)" }
}
function Text($node, $name) { $n = $node.SelectSingleNode($name); if ($n) { $n.InnerText } else { $null } }
function Label($node, $name) { $n = $node.SelectSingleNode("$name/@default"); if ($n) { $n.Value } else { $null } }

foreach ($name in $Names) {
    $dir = Join-Path $PSScriptRoot "..\solutions\EduCore\src\customapis\$name"
    [xml]$x = Get-Content (Join-Path $dir 'customapi.xml') -Raw
    $root = $x.DocumentElement
    $existing = (Dv GET "customapis?`$filter=uniquename eq '$name'&`$select=customapiid").value | Select-Object -First 1
    if ($existing) { Write-Host "= $name exists"; continue }

    Dv POST 'customapis' @{
        uniquename = $name; name = $name
        displayname = (Label $root 'displayname'); description = (Label $root 'description')
        bindingtype = [int](Text $root 'bindingtype'); isfunction = ((Text $root 'isfunction') -eq '1')
        isprivate = ((Text $root 'isprivate') -eq '1'); allowedcustomprocessingsteptype = [int](Text $root 'allowedcustomprocessingsteptype')
    } | Out-Null
    $id = (Dv GET "customapis?`$filter=uniquename eq '$name'&`$select=customapiid").value[0].customapiid
    Write-Host "+ $name"

    foreach ($f in Get-ChildItem (Join-Path $dir 'customapirequestparameters') -Recurse -Filter customapirequestparameter.xml -ErrorAction SilentlyContinue) {
        [xml]$p = Get-Content $f.FullName -Raw; $r = $p.DocumentElement
        $body = @{
            'CustomAPIId@odata.bind' = "/customapis($id)"
            uniquename = (Text $r 'name'); name = (Text $r 'name')
            displayname = (Label $r 'displayname'); description = (Label $r 'description')
            type = [int](Text $r 'type'); isoptional = ((Text $r 'isoptional') -eq '1')
        }
        $ent = Text $r 'logicalentityname'; if ($ent) { $body.logicalentityname = $ent }
        Dv POST 'customapirequestparameters' $body | Out-Null
        Write-Host "  + in  $($body.name)"
    }
    foreach ($f in Get-ChildItem (Join-Path $dir 'customapiresponseproperties') -Recurse -Filter customapiresponseproperty.xml -ErrorAction SilentlyContinue) {
        [xml]$p = Get-Content $f.FullName -Raw; $r = $p.DocumentElement
        $body = @{
            'CustomAPIId@odata.bind' = "/customapis($id)"
            uniquename = (Text $r 'name'); name = (Text $r 'name')
            displayname = (Label $r 'displayname'); description = (Label $r 'description')
            type = [int](Text $r 'type')
        }
        Dv POST 'customapiresponseproperties' $body | Out-Null
        Write-Host "  + out $($body.name)"
    }
}
Write-Host 'Done.'
