#!/usr/bin/env pwsh
#############################################################################
# ligne_full_check.ps1
# Port Windows / PowerShell de ligne_full_check.sh
#
# Verifie peppol, Harmony-connector et legalRef pour un SIREN_SUFIX donne.
#
# Usage :
#   .\ligne_full_check.ps1 432526903_TESTPILOTE          # mode DEBUG (defaut)
#   .\ligne_full_check.ps1 432526903_TESTPILOTE false    # mode ERROR_ONLY
#
# Les secrets sont charges automatiquement depuis script.env (meme dossier).
# Une variable deja definie dans l'environnement du processus n'est pas ecrasee.
#############################################################################

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Siren,

    [Parameter(Position = 1)]
    [string]$DebugMode = 'true'
)

$ErrorActionPreference = 'Stop'

# TLS 1.2 (requis pour Windows PowerShell 5.1)
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Equivalent du trap ERR du script bash
trap {
    $Host.UI.WriteErrorLine('')
    $Host.UI.WriteErrorLine("ERROR: $($_.Exception.Message)")
    exit 1
}

$ShowDebug = ($DebugMode -eq 'true')

#############################################################################
# Fonctions utilitaires
#############################################################################

function Write-Log {
    param([string]$Message)
    if ($ShowDebug) { Write-Host "`n$Message" -ForegroundColor Cyan }
}

function Write-Json {
    param($Data)
    if ($ShowDebug) { Write-Host ($Data | ConvertTo-Json -Depth 20) }
}

function Write-Err {
    param([string]$Message)
    $Host.UI.WriteErrorLine('')
    $Host.UI.WriteErrorLine("ERROR: $Message")
}

# Charge un fichier de type .env (lignes "export KEY='VALUE'") dans l'environnement.
function Import-EnvFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $t = $t -replace '^\s*export\s+', ''
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $t.Substring(0, $eq).Trim()
        $val = $t.Substring($eq + 1).Trim()
        if ($val.Length -ge 2) {
            $f = $val[0]; $l = $val[-1]
            if (($f -eq "'" -and $l -eq "'") -or ($f -eq '"' -and $l -eq '"')) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        if (-not [Environment]::GetEnvironmentVariable($key, 'Process')) {
            [Environment]::SetEnvironmentVariable($key, $val, 'Process')
        }
    }
}

# Encodage Base32 RFC 4648 (remplace la commande Unix "base32").
function ConvertTo-Base32 {
    param([byte[]]$Bytes)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $sb = New-Object System.Text.StringBuilder
    $buffer = 0
    $bitsLeft = 0
    foreach ($b in $Bytes) {
        $buffer = ($buffer -shl 8) -bor ([int]$b)
        $bitsLeft += 8
        while ($bitsLeft -ge 5) {
            $bitsLeft -= 5
            $idx = ($buffer -shr $bitsLeft) -band 0x1F
            [void]$sb.Append($alphabet[$idx])
        }
        if ($bitsLeft -gt 0) {
            $buffer = $buffer -band ((1 -shl $bitsLeft) - 1)
        } else {
            $buffer = 0
        }
    }
    if ($bitsLeft -gt 0) {
        $idx = ($buffer -shl (5 - $bitsLeft)) -band 0x1F
        [void]$sb.Append($alphabet[$idx])
    }
    return $sb.ToString()
}

# Resolution DNS NAPTR via DNS-over-HTTPS (Google) : Windows ne fournit aucun
# outil natif capable d'interroger les enregistrements NAPTR (ni nslookup ni
# Resolve-DnsName). Renvoie l'URL du SMP portee par le service "Meta:SMP".
function Get-PeppolSmpUrl {
    param([string]$DnsName)
    $resp = Invoke-RestMethod -Uri "https://dns.google/resolve?name=$DnsName&type=35"
    if (-not $resp.Answer) { return $null }
    foreach ($answer in $resp.Answer) {
        if ($answer.type -ne 35) { continue }
        if ($answer.data -notmatch 'Meta:SMP') { continue }
        # champ regexp NAPTR : !ere!replacement! -> l'URL est le 3e champ
        $parts = $answer.data -split '!'
        if ($parts.Count -ge 3) { return $parts[2].Trim() }
    }
    return $null
}

# Equivalent de xmllint --xpath 'string(...)' : texte d'un noeud, '' si absent.
function Get-XmlText {
    param([xml]$Xml, [string]$XPath)
    $node = $Xml.SelectSingleNode($XPath)
    if ($null -ne $node) { return ([string]$node.InnerText).Trim() }
    return ''
}

# Recupere un access_token Keycloak (grant_type=client_credentials).
function Get-AccessToken {
    param([string]$ClientId, [string]$ClientSecret)
    $resp = Invoke-RestMethod -Method Post `
        -Uri 'https://auth.apps.generix.biz/auth/realms/bo-generix/protocol/openid-connect/token' `
        -ContentType 'application/x-www-form-urlencoded' `
        -Headers @{ accept = 'application/json' } `
        -Body @{
            grant_type    = 'client_credentials'
            client_id     = $ClientId
            client_secret = $ClientSecret
        }
    if (-not $resp.access_token) {
        throw "access_token absent de la reponse du serveur d'authentification"
    }
    return $resp.access_token
}

#############################################################################
# Chargement des secrets et verification des prerequis
#############################################################################

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-EnvFile -Path (Join-Path $ScriptDir 'script.env')

foreach ($v in @(
        'HARMONY_CONNECTOR_CLIENT_ID',
        'HARMONY_CONNECTOR_CLIENT_SECRET',
        'LEGALREF_CLIENT_ID',
        'LEGALREF_CLIENT_SECRET')) {
    if (-not [Environment]::GetEnvironmentVariable($v, 'Process')) {
        Write-Err "Variable d'environnement manquante : $v"
        Write-Host "Definissez-la dans script.env (meme dossier) ou dans l'environnement."
        exit 1
    }
}

$Scheme = 'iso6523-actorid-upis'
$Participant = "0225:$Siren"

Write-Log "------------------- Checking $Siren -------------------"

#############################################################################
# Check peppol
#############################################################################

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Participant.ToLowerInvariant()))
} finally {
    $sha.Dispose()
}
$hash = (ConvertTo-Base32 $hashBytes).ToLowerInvariant().Replace('=', '')

$dnsName = "$hash.$Scheme.participant.sml.test.tech.peppol.org"

$smpUrl = Get-PeppolSmpUrl $dnsName
if ([string]::IsNullOrWhiteSpace($smpUrl)) {
    Write-Err "No Meta:SMP record found for `"$Participant`" "
    exit 1
}

[xml]$smpXml = (Invoke-WebRequest -Uri "$smpUrl/$Scheme::$Participant" -UseBasicParsing).Content

$refNodes = $smpXml.SelectNodes("//*[local-name()='ServiceMetadataReference']")
$docNumber = $refNodes.Count
if ($docNumber -lt 1) {
    Write-Err "No ServiceMetadataReference found for `"$Participant`""
    exit 1
}
$firstDoc = $refNodes[0].GetAttribute('href')

[xml]$firstDocXml = (Invoke-WebRequest -Uri $firstDoc -UseBasicParsing).Content

$apUrl          = Get-XmlText $firstDocXml "//*[local-name()='EndpointReference']/*[local-name()='Address']"
$smpCertificate = Get-XmlText $firstDocXml "//*[local-name()='X509SubjectName']"
$certB64        = Get-XmlText $firstDocXml "//*[local-name()='Certificate']"

$apCertSubject = ''
if ($certB64 -ne '') {
    $certBytes = [Convert]::FromBase64String(($certB64 -replace '\s', ''))
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $certBytes)
    $apCertSubject = $cert.Subject
}

Write-Log "# Peppol informations for `"$Participant`""
Write-Json ([ordered]@{
    SMP_URL                = $smpUrl
    SMP_CERTIFICATE        = $smpCertificate
    DOC_NUMBER             = $docNumber
    AP_URL                 = $apUrl
    AP_CERTIFICATE_SUBJECT = $apCertSubject
})

#############################################################################
# Guessing ENV and PA
#############################################################################

$tmp = $apUrl -replace '^https://', ''
$subDomain = ($tmp -split '/', 2)[0]
$dotIdx = $subDomain.IndexOf('.')
$domain = if ($dotIdx -ge 0) { $subDomain.Substring($dotIdx + 1) } else { $subDomain }

if ($tmp.Contains('/')) {
    $urlPath = '/' + $tmp.Substring($tmp.IndexOf('/') + 1)
} else {
    $urlPath = '/' + $tmp
}

$envName = $apUrl -replace '^https://gis-platform-', ''
$envName = ($envName -split '\.', 2)[0]

switch ($domain) {
    'generix.biz'             { $pa = 'gnx' }
    'fulll.house'             { $pa = 'fulll' }
    'pbis.qa-mypbconnect.com' { $pa = 'pitney-bowes' }
    'treso2.com'              { $pa = 'pytheas' }
    default {
        Write-Err "Unknown domain: `"$domain`""
        exit 1
    }
}

$firstLevel = $urlPath -replace '/harmonypdpap/services/msh$', ''
if ($firstLevel -ne '') {
    $pa = $firstLevel -replace '^/', ''
}

Write-Log "# Inferring ENV: `"$envName`" and PA: `"$pa`" from peppol infos for `"$Participant`""
Write-Json ([ordered]@{
    ENV        = $envName
    SUB_DOMAIN = $subDomain
    DOMAIN     = $domain
    PA         = $pa
})

#############################################################################
# Check Harmony-connector routing is done
#############################################################################

$harmonyToken = Get-AccessToken $env:HARMONY_CONNECTOR_CLIENT_ID $env:HARMONY_CONNECTOR_CLIENT_SECRET

$harmonyConnectorUrl = "$pa-harmonyconnector-fr-$envName.apps.prd.openshift.vmwr/$pa"
$harmonyConnectorEndpoint = "https://$harmonyConnectorUrl/harmonyconnector-fr/v1/participants/$Participant"

Write-Log "# Harmony-connector routing for `"$Participant`" from `"$harmonyConnectorUrl`""
try {
    $routing = Invoke-RestMethod -Uri $harmonyConnectorEndpoint -Headers @{
        Accept        = 'application/json'
        Authorization = "Bearer $harmonyToken"
    }
    Write-Json $routing
} catch {
    Write-Err "No Harmony-connector routing found for `"$Participant`"`n       $harmonyConnectorUrl"
}

#############################################################################
# Check legalRef
#############################################################################

$legalRefToken = Get-AccessToken $env:LEGALREF_CLIENT_ID $env:LEGALREF_CLIENT_SECRET

$legalRefSubDomain = $null
switch ("${envName}:${pa}") {
    'uat:gnx'          { $legalRefSubDomain = 'legalref-api-uat-ppd.staging.apps.generix.biz'; break }
    'uat:pitney-bowes' { $legalRefSubDomain = 'legalref-api-uat-pitneybowes.staging.apps.generix.biz'; break }
    'uat:fulll'        { $legalRefSubDomain = 'N/A'; break }
    'uat:pytheas'      { $legalRefSubDomain = 'N/A'; break }
    'uat:b4value'      { $legalRefSubDomain = 'N/A'; break }
    'uat:fiteco'       { $legalRefSubDomain = 'N/A'; break }
    'uat:spendesk'     { $legalRefSubDomain = 'N/A'; break }
    'pre:gnx'          { $legalRefSubDomain = 'legalref-api-ppd.staging.apps.generix.biz'; break }
    'pre:fulll'        { $legalRefSubDomain = 'legalref-api-pprd-fulll.staging.apps.generix.biz'; break }
    'pre:pitney-bowes' { $legalRefSubDomain = 'legalref-api-pprd-pitneybowes.staging.apps.generix.biz'; break }
    'pre:pytheas'      { $legalRefSubDomain = 'legalref-api-pprd-pytheas.staging.apps.generix.biz'; break }
    'pre:b4value'      { $legalRefSubDomain = 'legalref-api-pprd-b4value.staging.apps.generix.biz'; break }
    'pre:fiteco'       { $legalRefSubDomain = 'legalref-api-pprd-fiteco.staging.apps.generix.biz'; break }
    'pre:spendesk'     { $legalRefSubDomain = 'legalref-api-pprd-spendesk.staging.apps.generix.biz'; break }
    'prd:gnx'          { $legalRefSubDomain = 'legalref-api.apps.generix.biz'; break }
    'prd:fulll'        { $legalRefSubDomain = 'legalref-api-fulll.apps.generix.biz'; break }
    'prd:pitney-bowes' { $legalRefSubDomain = 'legalref-api-pitneybowes.apps.generix.biz'; break }
    'prd:pytheas'      { $legalRefSubDomain = 'legalref-api-pytheas.apps.generix.biz'; break }
    'prd:b4value'      { $legalRefSubDomain = 'legalref-api-b4value.apps.generix.biz'; break }
    'prd:fiteco'       { $legalRefSubDomain = 'legalref-api-fiteco.apps.generix.biz'; break }
    'prd:spendesk'     { $legalRefSubDomain = 'legalref-api-spendesk.apps.generix.biz'; break }
    default {
        Write-Err "Unsupported ENV/PA combination: `"$envName/$pa`""
        exit 1
    }
}

Write-Log "# legalRef informations for `"$Siren`" from `"$legalRefSubDomain`""
try {
    $legalRefLigne = Invoke-RestMethod `
        -Uri "https://$legalRefSubDomain/ppf/annuaire-public/v2/ligne-annuaire/code:$Siren" `
        -Headers @{
            accept        = 'application/json'
            Authorization = "Bearer $legalRefToken"
        }
    Write-Json $legalRefLigne
} catch {
    Write-Err "No legalRef line found for `"$Siren`""
}
