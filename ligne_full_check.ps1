#!/usr/bin/env pwsh
#############################################################################
# ligne_full_check.ps1
# Port Windows / PowerShell de ligne_full_check.sh
#
# Verifie peppol, Harmony-connector et legalRef pour un SIREN_SUFIX donne.
#
# Le check Harmony verifie aussi que l'environmentId renvoye par Harmony
# correspond a celui attendu pour le client. Le mapping est compose a partir
# de :
#   - gis_siren_testpilote (env, client, siren_testpilote)  -> SIREN -> Client
#   - gis_clients          (client_name, env, env_id)        -> Client -> envId attendu
# Ces tables sont lues dans le fichier gis_mappings.json local (GIS_MAPPINGS_FILE).
# Si l'envId reel != envId attendu : Harmony = MISMATCH.
# Si le mapping est incomplet (SIREN absent ou client absent de gis_clients) :
# Harmony = UNVERIFIED.
#
# Mode mono-SIREN (sortie console) :
#   .\ligne_full_check.ps1 432526903_TESTPILOTE             # mode DEBUG (defaut)
#   .\ligne_full_check.ps1 432526903_TESTPILOTE false       # mode ERROR_ONLY
#
# Mode batch (rapport markdown) :
#   .\ligne_full_check.ps1 -InputFile sirens.txt -OutputMarkdown rapport.md
#   .\ligne_full_check.ps1 -Sirens 123_TEST,456_TEST -OutputMarkdown rapport.md
#
# Le fichier d'entree accepte une ligne par SIREN. Les lignes vides, commentaires
# (#) et formats bruites (texte autour, parentheses de fin, espaces internes) sont
# tolerees : la regex extrait le pattern SIREN_SUFIX automatiquement.
#
# Les secrets sont charges automatiquement depuis script.env (meme dossier).
# Une variable deja definie dans l'environnement du processus n'est pas ecrasee.
#############################################################################

param(
    [Parameter(Position = 0)]
    [string]$Siren,

    [Parameter(Position = 1)]
    [string]$DebugMode = 'true',

    [string]$InputFile,
    [string]$OutputMarkdown,
    [string[]]$Sirens
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

# Mode batch si -InputFile, -OutputMarkdown ou -Sirens fourni
$BatchMode = (-not [string]::IsNullOrWhiteSpace($InputFile)) `
             -or (-not [string]::IsNullOrWhiteSpace($OutputMarkdown)) `
             -or ($Sirens -and $Sirens.Count -gt 0)

#############################################################################
# Fonctions utilitaires
#############################################################################

function Write-Log {
    param([string]$Message)
    if ($ShowDebug -and -not $BatchMode) { Write-Host "`n$Message" -ForegroundColor Cyan }
}

function Write-Json {
    param($Data)
    if ($ShowDebug -and -not $BatchMode) { Write-Host ($Data | ConvertTo-Json -Depth 20) }
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

# Nettoie une ligne d'entree (parens de fin, espaces internes, texte parasite)
# et renvoie le SIREN_SUFIX si trouve, sinon $null.
function Get-CleanSiren {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $t = $Line.Trim()
    if ($t.StartsWith('#')) { return $null }
    # Strip trailing parenthesised label (ex : "... (Delpeyrat)")
    $t = $t -replace '\s*\([^)]*\)\s*$', ''
    # Strip non-ASCII/control noise (valeurs siren_testpilote parfois corrompues)
    $t = $t -replace '[^\x20-\x7E]', ''
    # Strip trailing non-alnum noise (?, ?? etc.)
    $t = $t -replace '[^A-Za-z0-9_]+$', ''
    # Match \d{9,10}\s*_<non-space-suite>, tolere un espace parasite avant _
    if ($t -match '(\d{9,10})\s*_(\S+)') {
        return $Matches[1] + '_' + $Matches[2]
    }
    return $null
}

# Lit les mappings dans le fichier JSON local $env:GIS_MAPPINGS_FILE (défaut: à côté du script).
# Renvoie les lignes (objets : propriétés = colonnes), depuis le fichier gis_mappings.json local.
function Get-MappingRows {
    param([string]$Sql, [object[]]$Params = @())
    $file = $env:GIS_MAPPINGS_FILE
    if ([string]::IsNullOrWhiteSpace($file)) { $file = Join-Path $PSScriptRoot 'gis_mappings.json' }
    if (-not (Test-Path $file)) { throw "GIS_MAPPINGS_FILE introuvable : $file" }
    $data = Get-Content -Raw -Path $file | ConvertFrom-Json
    if ($Sql -match 'gis_siren_testpilote') { return @($data.gis_siren_testpilote) }
    elseif ($Sql -match 'gis_clients')      { return @($data.gis_clients) }
    return @()
}

# Charge gis_clients (client_name, env_id) et gis_siren_testpilote (client, siren_testpilote)
# depuis le fichier gis_mappings.json local et compose un map SIREN_SUFIX -> envId attendu (via le client).
function Import-SirenMappings {
    $cmp                  = [System.StringComparer]::OrdinalIgnoreCase
    $clientToEnvId        = New-Object 'System.Collections.Generic.Dictionary[string,string]' $cmp
    $sirenToClient        = New-Object 'System.Collections.Generic.Dictionary[string,string]' $cmp
    $sirenToExpectedEnvId = New-Object 'System.Collections.Generic.Dictionary[string,string]' $cmp

    try {
        $rows = Get-MappingRows 'SELECT client_name, env_id FROM gis_clients'
        foreach ($row in $rows) {
            $client = ([string]$row.client_name -replace '[^\x20-\x7E]', '').Trim()
            $envId  = ([string]$row.env_id      -replace '[^\x20-\x7E]', '').Trim()
            if ([string]::IsNullOrWhiteSpace($client) -or [string]::IsNullOrWhiteSpace($envId)) { continue }
            if (-not $clientToEnvId.ContainsKey($client)) {
                $clientToEnvId[$client] = $envId
            }
        }
    } catch {
        Write-Host "Avertissement : lecture de gis_clients impossible ($($_.Exception.Message))" -ForegroundColor Yellow
    }

    try {
        $rows = Get-MappingRows 'SELECT client, siren_testpilote FROM gis_siren_testpilote'
        foreach ($row in $rows) {
            $client    = ([string]$row.client -replace '[^\x20-\x7E]', '').Trim()
            $sirenCell = [string]$row.siren_testpilote
            if ([string]::IsNullOrWhiteSpace($client) -or [string]::IsNullOrWhiteSpace($sirenCell)) { continue }
            foreach ($raw in ($sirenCell -split '[\r\n]+')) {
                $cleaned = Get-CleanSiren $raw
                if ($cleaned -and -not $sirenToClient.ContainsKey($cleaned)) {
                    $sirenToClient[$cleaned] = $client
                }
            }
        }
    } catch {
        Write-Host "Avertissement : lecture de gis_siren_testpilote impossible ($($_.Exception.Message))" -ForegroundColor Yellow
    }

    foreach ($siren in $sirenToClient.Keys) {
        $client = $sirenToClient[$siren]
        if ($clientToEnvId.ContainsKey($client)) {
            $sirenToExpectedEnvId[$siren] = $clientToEnvId[$client]
        }
    }

    return [pscustomobject]@{
        ClientToEnvId        = $clientToEnvId
        SirenToClient        = $sirenToClient
        SirenToExpectedEnvId = $sirenToExpectedEnvId
    }
}

# Formate une liste de requetes HTTP capturees en markdown (puces + sous-puces).
function Format-Requests {
    param($Requests)
    if (-not $Requests -or $Requests.Count -eq 0) { return $null }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($req in $Requests) {
        $label = if ($req.Label) { "**$($req.Label)** : " } else { '' }
        [void]$lines.Add("- $label``$($req.Method) $($req.Url)``")
        if ($req.Body)   { [void]$lines.Add("  - body : ``$($req.Body)``") }
        if ($req.Header) { [void]$lines.Add("  - header : ``$($req.Header)``") }
    }
    return ($lines -join "`n")
}

#############################################################################
# Coeur du check pour un SIREN (renvoie un objet structure)
#############################################################################

function Invoke-LigneCheck {
    param(
        [string]$TargetSiren,
        [string]$ExpectedClient,
        [string]$ExpectedEnvId
    )

    $result = [ordered]@{
        Siren     = $TargetSiren
        Peppol    = [ordered]@{ Status = 'NOT_RUN'; Data = $null; Error = $null; Requests = (New-Object System.Collections.ArrayList) }
        Inference = [ordered]@{ Status = 'NOT_RUN'; Data = $null; Error = $null }
        Harmony   = [ordered]@{
            Status         = 'NOT_RUN'
            Url            = $null
            Data           = $null
            Error          = $null
            Requests       = (New-Object System.Collections.ArrayList)
            ExpectedClient = $ExpectedClient
            ExpectedEnvId  = $ExpectedEnvId
            ActualEnvId    = $null
            EnvIdCheck     = 'NOT_RUN'
        }
        LegalRef  = [ordered]@{ Status = 'NOT_RUN'; SubDomain = $null; Data = $null; Error = $null; Requests = (New-Object System.Collections.ArrayList) }
    }

    $scheme      = 'iso6523-actorid-upis'
    $participant = "0225:$TargetSiren"

    # ----- Peppol -----
    $apUrl = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($participant.ToLowerInvariant()))
        } finally {
            $sha.Dispose()
        }
        $hash    = (ConvertTo-Base32 $hashBytes).ToLowerInvariant().Replace('=', '')
        $dnsName = "$hash.$scheme.participant.sml.test.tech.peppol.org"

        [void]$result.Peppol.Requests.Add([ordered]@{
            Label = 'DNS NAPTR (DNS-over-HTTPS)'
            Method = 'GET'
            Url = "https://dns.google/resolve?name=$dnsName&type=35"
        })
        $smpUrl = Get-PeppolSmpUrl $dnsName
        if ([string]::IsNullOrWhiteSpace($smpUrl)) {
            throw "No Meta:SMP record found for `"$participant`""
        }

        $smpEndpoint = "$smpUrl/$scheme::$participant"
        [void]$result.Peppol.Requests.Add([ordered]@{
            Label = 'SMP racine'
            Method = 'GET'
            Url = $smpEndpoint
        })
        [xml]$smpXml = (Invoke-WebRequest -Uri $smpEndpoint -UseBasicParsing).Content
        $refNodes  = $smpXml.SelectNodes("//*[local-name()='ServiceMetadataReference']")
        $docNumber = $refNodes.Count
        if ($docNumber -lt 1) {
            throw "No ServiceMetadataReference found for `"$participant`""
        }
        $firstDoc = $refNodes[0].GetAttribute('href')

        [void]$result.Peppol.Requests.Add([ordered]@{
            Label = 'SMP doc'
            Method = 'GET'
            Url = $firstDoc
        })
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

        $result.Peppol.Status = 'OK'
        $result.Peppol.Data = [ordered]@{
            SMP_URL                = $smpUrl
            SMP_CERTIFICATE        = $smpCertificate
            DOC_NUMBER             = $docNumber
            AP_URL                 = $apUrl
            AP_CERTIFICATE_SUBJECT = $apCertSubject
        }
    } catch {
        $result.Peppol.Status = 'ERROR'
        $result.Peppol.Error  = $_.Exception.Message
        return $result
    }

    # ----- Inference ENV / PA -----
    $envName = $null
    $pa      = $null
    try {
        $tmp       = $apUrl -replace '^https://', ''
        $subDomain = ($tmp -split '/', 2)[0]
        $dotIdx    = $subDomain.IndexOf('.')
        $domain    = if ($dotIdx -ge 0) { $subDomain.Substring($dotIdx + 1) } else { $subDomain }

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
            default { throw "Unknown domain: `"$domain`"" }
        }

        $firstLevel = $urlPath -replace '/harmonypdpap/services/msh$', ''
        if ($firstLevel -ne '') {
            $pa = $firstLevel -replace '^/', ''
        }

        $result.Inference.Status = 'OK'
        $result.Inference.Data = [ordered]@{
            ENV        = $envName
            SUB_DOMAIN = $subDomain
            DOMAIN     = $domain
            PA         = $pa
        }
    } catch {
        $result.Inference.Status = 'ERROR'
        $result.Inference.Error  = $_.Exception.Message
        return $result
    }

    # ----- Harmony-connector -----
    $harmonyConnectorUrl = "$pa-harmonyconnector-fr-$envName.apps.prd.openshift.vmwr/$pa"
    $result.Harmony.Url  = $harmonyConnectorUrl
    try {
        [void]$result.Harmony.Requests.Add([ordered]@{
            Label = 'Token Keycloak'
            Method = 'POST'
            Url = 'https://auth.apps.generix.biz/auth/realms/bo-generix/protocol/openid-connect/token'
            Body = 'grant_type=client_credentials&client_id=$env:HARMONY_CONNECTOR_CLIENT_ID&client_secret=***'
        })
        $harmonyToken = Get-AccessToken $env:HARMONY_CONNECTOR_CLIENT_ID $env:HARMONY_CONNECTOR_CLIENT_SECRET
        $harmonyEndpoint = "https://$harmonyConnectorUrl/harmonyconnector-fr/v1/participants/$participant"
        [void]$result.Harmony.Requests.Add([ordered]@{
            Label = 'Routing'
            Method = 'GET'
            Url = $harmonyEndpoint
            Header = 'Authorization: Bearer <token>'
        })
        $routing = Invoke-RestMethod -Uri $harmonyEndpoint -Headers @{
            Accept        = 'application/json'
            Authorization = "Bearer $harmonyToken"
        }
        $result.Harmony.Data   = $routing

        $actualEnvId = $null
        if ($routing -and $routing.PSObject.Properties['environmentId']) {
            $actualEnvId = [string]$routing.environmentId
        }
        $result.Harmony.ActualEnvId = $actualEnvId

        if ([string]::IsNullOrWhiteSpace($ExpectedEnvId)) {
            $result.Harmony.EnvIdCheck = 'UNKNOWN'
            $result.Harmony.Status     = 'UNVERIFIED'
        } elseif (-not [string]::IsNullOrWhiteSpace($actualEnvId) -and
                  [string]::Equals($actualEnvId, $ExpectedEnvId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $result.Harmony.EnvIdCheck = 'MATCH'
            $result.Harmony.Status     = 'OK'
        } else {
            $result.Harmony.EnvIdCheck = 'MISMATCH'
            $result.Harmony.Status     = 'MISMATCH'
            $result.Harmony.Error      = "envId attendu '$ExpectedEnvId' != envId recu '$actualEnvId'"
        }
    } catch {
        $result.Harmony.Status = 'ERROR'
        $result.Harmony.Error  = $_.Exception.Message
    }

    # ----- legalRef -----
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
            $result.LegalRef.Status = 'ERROR'
            $result.LegalRef.Error  = "Unsupported ENV/PA combination: `"$envName/$pa`""
            return $result
        }
    }

    $result.LegalRef.SubDomain = $legalRefSubDomain

    if ($legalRefSubDomain -eq 'N/A') {
        $result.LegalRef.Status = 'N/A'
        return $result
    }

    try {
        [void]$result.LegalRef.Requests.Add([ordered]@{
            Label = 'Token Keycloak'
            Method = 'POST'
            Url = 'https://auth.apps.generix.biz/auth/realms/bo-generix/protocol/openid-connect/token'
            Body = 'grant_type=client_credentials&client_id=$env:LEGALREF_CLIENT_ID&client_secret=***'
        })
        $legalRefToken = Get-AccessToken $env:LEGALREF_CLIENT_ID $env:LEGALREF_CLIENT_SECRET
        $legalRefEndpoint = "https://$legalRefSubDomain/ppf/annuaire-public/v2/ligne-annuaire/code:$TargetSiren"
        [void]$result.LegalRef.Requests.Add([ordered]@{
            Label = 'Ligne annuaire'
            Method = 'GET'
            Url = $legalRefEndpoint
            Header = 'Authorization: Bearer <token>'
        })
        $legalRefLigne = Invoke-RestMethod -Uri $legalRefEndpoint -Headers @{
            accept        = 'application/json'
            Authorization = "Bearer $legalRefToken"
        }
        $result.LegalRef.Status = 'OK'
        $result.LegalRef.Data   = $legalRefLigne
    } catch {
        $result.LegalRef.Status = 'ERROR'
        $result.LegalRef.Error  = $_.Exception.Message
    }

    return $result
}

#############################################################################
# Generation du rapport markdown
#############################################################################

function Format-MarkdownReport {
    param($Results)

    $statusIcon = {
        param($s)
        switch ($s) {
            'OK'         { 'OK' }
            'N/A'        { 'N/A' }
            'ERROR'      { 'KO' }
            'MISMATCH'   { 'MISMATCH' }
            'UNVERIFIED' { 'OK (?)' }
            'NOT_RUN'    { '-' }
            default      { $s }
        }
    }

    $sb = New-Object System.Text.StringBuilder

    $okCount = ($Results | Where-Object {
        $_.Peppol.Status -eq 'OK' -and
        $_.Harmony.Status -eq 'OK' -and
        ($_.LegalRef.Status -eq 'OK' -or $_.LegalRef.Status -eq 'N/A')
    }).Count
    $mismatchCount   = ($Results | Where-Object { $_.Harmony.Status -eq 'MISMATCH' }).Count
    $unverifiedCount = ($Results | Where-Object { $_.Harmony.Status -eq 'UNVERIFIED' }).Count
    $koCount         = $Results.Count - $okCount

    [void]$sb.AppendLine("# Rapport ligne d'adressage")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("- Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("- Total SIRENs : $($Results.Count)")
    [void]$sb.AppendLine("- Verts (3 checks OK + envId conforme) : $okCount")
    [void]$sb.AppendLine("- Harmony envId MISMATCH : $mismatchCount")
    [void]$sb.AppendLine("- Harmony envId non verifie (mapping absent) : $unverifiedCount")
    [void]$sb.AppendLine("- Avec au moins un KO/MISMATCH : $koCount")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Resume")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| # | SIREN | Peppol | Harmony | envId attendu | envId recu | LegalRef | ENV | PA |")
    [void]$sb.AppendLine("|---|-------|--------|---------|---------------|------------|----------|-----|----|")
    $i = 0
    foreach ($r in $Results) {
        $i++
        $env_      = if ($r.Inference.Data) { $r.Inference.Data.ENV } else { '-' }
        $pa_       = if ($r.Inference.Data) { $r.Inference.Data.PA }  else { '-' }
        $expected_ = if ($r.Harmony.ExpectedEnvId) { $r.Harmony.ExpectedEnvId } else { '-' }
        $actual_   = if ($r.Harmony.ActualEnvId)   { $r.Harmony.ActualEnvId }   else { '-' }
        [void]$sb.AppendLine("| $i | $($r.Siren) | $(& $statusIcon $r.Peppol.Status) | $(& $statusIcon $r.Harmony.Status) | $expected_ | $actual_ | $(& $statusIcon $r.LegalRef.Status) | $env_ | $pa_ |")
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Details")

    foreach ($r in $Results) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("### $($r.Siren)")
        [void]$sb.AppendLine("")

        # Peppol
        [void]$sb.AppendLine("**Peppol** : $($r.Peppol.Status)")
        if ($r.Peppol.Requests -and $r.Peppol.Requests.Count -gt 0) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("*Requetes effectuees* :")
            [void]$sb.AppendLine((Format-Requests $r.Peppol.Requests))
        }
        if ($r.Peppol.Status -eq 'ERROR') {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine($r.Peppol.Error)
            [void]$sb.AppendLine('```')
        } elseif ($r.Peppol.Data) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine('```json')
            [void]$sb.AppendLine(($r.Peppol.Data | ConvertTo-Json -Depth 10))
            [void]$sb.AppendLine('```')
        }

        # Inference
        if ($r.Inference.Status -ne 'NOT_RUN') {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**ENV / PA inferes** : $($r.Inference.Status)")
            if ($r.Inference.Status -eq 'ERROR') {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine('```')
                [void]$sb.AppendLine($r.Inference.Error)
                [void]$sb.AppendLine('```')
            } elseif ($r.Inference.Data) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine('```json')
                [void]$sb.AppendLine(($r.Inference.Data | ConvertTo-Json -Depth 10))
                [void]$sb.AppendLine('```')
            }
        }

        # Harmony
        if ($r.Harmony.Status -ne 'NOT_RUN') {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Harmony-connector** : $($r.Harmony.Status)")
            if ($r.Harmony.Url) { [void]$sb.AppendLine("- URL : $($r.Harmony.Url)") }
            if ($r.Harmony.ExpectedClient) { [void]$sb.AppendLine("- Client attendu (gis_siren_testpilote) : $($r.Harmony.ExpectedClient)") }
            if ($r.Harmony.ExpectedEnvId)  { [void]$sb.AppendLine("- envId attendu (gis_clients)           : $($r.Harmony.ExpectedEnvId)") }
            if ($r.Harmony.ActualEnvId)    { [void]$sb.AppendLine("- envId recu (Harmony)             : $($r.Harmony.ActualEnvId)") }
            if ($r.Harmony.EnvIdCheck -and $r.Harmony.EnvIdCheck -ne 'NOT_RUN') {
                [void]$sb.AppendLine("- Comparaison envId                : $($r.Harmony.EnvIdCheck)")
            }
            if ($r.Harmony.Requests -and $r.Harmony.Requests.Count -gt 0) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("*Requetes effectuees* :")
                [void]$sb.AppendLine((Format-Requests $r.Harmony.Requests))
            }
            if ($r.Harmony.Status -eq 'ERROR' -or $r.Harmony.Status -eq 'MISMATCH') {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine('```')
                [void]$sb.AppendLine($r.Harmony.Error)
                [void]$sb.AppendLine('```')
            }
            if ($r.Harmony.Data) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine('```json')
                [void]$sb.AppendLine(($r.Harmony.Data | ConvertTo-Json -Depth 10))
                [void]$sb.AppendLine('```')
            }
        }

        # LegalRef
        if ($r.LegalRef.Status -ne 'NOT_RUN') {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**legalRef** : $($r.LegalRef.Status)")
            if ($r.LegalRef.SubDomain) { [void]$sb.AppendLine("- Sous-domaine : $($r.LegalRef.SubDomain)") }
            if ($r.LegalRef.Requests -and $r.LegalRef.Requests.Count -gt 0) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("*Requetes effectuees* :")
                [void]$sb.AppendLine((Format-Requests $r.LegalRef.Requests))
            }
            if ($r.LegalRef.Status -eq 'ERROR') {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine('```')
                [void]$sb.AppendLine($r.LegalRef.Error)
                [void]$sb.AppendLine('```')
            } elseif ($r.LegalRef.Data) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine('```json')
                [void]$sb.AppendLine(($r.LegalRef.Data | ConvertTo-Json -Depth 10))
                [void]$sb.AppendLine('```')
            }
        }
    }

    return $sb.ToString()
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

# Mappings gis_clients + gis_siren_testpilote (fichier gis_mappings.json local) pour la verification de l'envId Harmony
$Mappings = Import-SirenMappings

function Get-ExpectedHarmonyContext {
    param([string]$Siren)
    $client = $null
    $envId  = $null
    if ($Mappings.SirenToClient.ContainsKey($Siren)) {
        $client = $Mappings.SirenToClient[$Siren]
    }
    if ($Mappings.SirenToExpectedEnvId.ContainsKey($Siren)) {
        $envId = $Mappings.SirenToExpectedEnvId[$Siren]
    }
    return [pscustomobject]@{ Client = $client; EnvId = $envId }
}

#############################################################################
# Dispatch : mode mono-SIREN ou mode batch
#############################################################################

if (-not $BatchMode) {
    # Compat retro : un seul SIREN, sortie console comme avant
    if ([string]::IsNullOrWhiteSpace($Siren)) {
        Write-Err "Aucun SIREN fourni. Voir l'en-tete du script pour la syntaxe."
        exit 1
    }

    $cleanedSiren = Get-CleanSiren $Siren
    if ($cleanedSiren) { $Siren = $cleanedSiren }
    $ctx = Get-ExpectedHarmonyContext -Siren $Siren

    Write-Log "------------------- Checking $Siren -------------------"
    $r = Invoke-LigneCheck -TargetSiren $Siren -ExpectedClient $ctx.Client -ExpectedEnvId $ctx.EnvId

    if ($r.Peppol.Status -eq 'ERROR') { Write-Err $r.Peppol.Error; exit 1 }
    Write-Log "# Peppol informations for `"0225:$Siren`""
    Write-Json $r.Peppol.Data

    if ($r.Inference.Status -eq 'ERROR') { Write-Err $r.Inference.Error; exit 1 }
    Write-Log "# Inferring ENV: `"$($r.Inference.Data.ENV)`" and PA: `"$($r.Inference.Data.PA)`" from peppol infos for `"0225:$Siren`""
    Write-Json $r.Inference.Data

    Write-Log "# Harmony-connector routing for `"0225:$Siren`" from `"$($r.Harmony.Url)`""
    if ($r.Harmony.Status -eq 'ERROR') {
        Write-Err "No Harmony-connector routing found for `"0225:$Siren`"`n       $($r.Harmony.Url)"
    } else {
        Write-Json $r.Harmony.Data
        if ($r.Harmony.Status -eq 'MISMATCH') {
            Write-Err "Harmony envId MISMATCH pour `"0225:$Siren`" (client `"$($r.Harmony.ExpectedClient)`")`n       attendu : $($r.Harmony.ExpectedEnvId)`n       recu    : $($r.Harmony.ActualEnvId)"
        } elseif ($r.Harmony.Status -eq 'UNVERIFIED') {
            Write-Log "# Harmony envId non verifie : SIREN `"$Siren`" absent de gis_siren_testpilote ou client absent de gis_clients"
        }
    }

    Write-Log "# legalRef informations for `"$Siren`" from `"$($r.LegalRef.SubDomain)`""
    if ($r.LegalRef.Status -eq 'ERROR') {
        Write-Err "No legalRef line found for `"$Siren`""
    } elseif ($r.LegalRef.Status -eq 'OK') {
        Write-Json $r.LegalRef.Data
    }
    exit 0
}

# ----- Mode batch -----
$inputList = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($InputFile)) {
    if (-not (Test-Path -LiteralPath $InputFile)) {
        Write-Err "Fichier d'entree introuvable : $InputFile"
        exit 1
    }
    foreach ($line in (Get-Content -LiteralPath $InputFile)) { [void]$inputList.Add($line) }
}
if ($Sirens) {
    foreach ($s in $Sirens) { [void]$inputList.Add($s) }
}
if (-not [string]::IsNullOrWhiteSpace($Siren)) {
    [void]$inputList.Add($Siren)
}

# Nettoyage + dedup
$cleanList = New-Object System.Collections.Generic.List[string]
$seen      = New-Object System.Collections.Generic.HashSet[string]
$skipped   = New-Object System.Collections.Generic.List[string]
foreach ($line in $inputList) {
    $clean = Get-CleanSiren $line
    if ($null -eq $clean) {
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.Trim().StartsWith('#')) {
            [void]$skipped.Add($line)
        }
        continue
    }
    if ($seen.Add($clean)) { [void]$cleanList.Add($clean) }
}

if ($cleanList.Count -eq 0) {
    Write-Err "Aucun SIREN valide trouve apres nettoyage."
    exit 1
}

Write-Host ""
Write-Host "Mode batch : $($cleanList.Count) SIREN(s) a verifier."
if ($skipped.Count -gt 0) {
    Write-Host "  $($skipped.Count) ligne(s) ignoree(s) (format non reconnu)." -ForegroundColor Yellow
}
Write-Host ""

$results = New-Object System.Collections.Generic.List[object]
$idx = 0
foreach ($s in $cleanList) {
    $idx++
    $prefix = "[{0}/{1}] {2}" -f $idx, $cleanList.Count, $s
    $ctx = Get-ExpectedHarmonyContext -Siren $s
    try {
        $r = Invoke-LigneCheck -TargetSiren $s -ExpectedClient $ctx.Client -ExpectedEnvId $ctx.EnvId
    } catch {
        $r = [ordered]@{
            Siren     = $s
            Peppol    = [ordered]@{ Status = 'ERROR'; Error = "Unexpected: $($_.Exception.Message)" }
            Inference = [ordered]@{ Status = 'NOT_RUN' }
            Harmony   = [ordered]@{ Status = 'NOT_RUN'; ExpectedClient = $ctx.Client; ExpectedEnvId = $ctx.EnvId; ActualEnvId = $null; EnvIdCheck = 'NOT_RUN' }
            LegalRef  = [ordered]@{ Status = 'NOT_RUN' }
        }
    }
    [void]$results.Add($r)
    $summary = "peppol={0} harmony={1} legalref={2}" -f `
        $r.Peppol.Status, $r.Harmony.Status, $r.LegalRef.Status
    $color = if ($r.Peppol.Status -eq 'OK' -and $r.Harmony.Status -eq 'OK' -and ($r.LegalRef.Status -eq 'OK' -or $r.LegalRef.Status -eq 'N/A')) {
        'Green'
    } elseif ($r.Harmony.Status -eq 'MISMATCH') {
        'Red'
    } else {
        'Yellow'
    }
    Write-Host "$prefix  $summary" -ForegroundColor $color
}

if ([string]::IsNullOrWhiteSpace($OutputMarkdown)) {
    $OutputMarkdown = Join-Path $ScriptDir 'rapport.md'
}

$md = Format-MarkdownReport -Results $results
[System.IO.File]::WriteAllText($OutputMarkdown, $md, [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "Rapport ecrit : $OutputMarkdown"
if ($skipped.Count -gt 0) {
    Write-Host ""
    Write-Host "Lignes ignorees :" -ForegroundColor Yellow
    foreach ($l in $skipped) { Write-Host "  - $l" -ForegroundColor Yellow }
}
exit 0
