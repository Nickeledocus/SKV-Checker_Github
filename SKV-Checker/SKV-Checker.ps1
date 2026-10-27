<#
    SKV Certificaat Checker
    -----------------------
    Controleert 1 UBN (Uniek Bedrijfsnummer) met 1 tot 5 AM91-nummers bij de SKV API.

    Werkt met Windows PowerShell 5.1 (standaard aanwezig op Windows 10/11).
    Start via "Start SKV Checker.bat" (dubbelklikken).

    Instellingen (adressen, gebruikersnaam, wachtwoord) staan in appsettings.json
    in dezelfde map als dit script.
#>

$ErrorActionPreference = 'Stop'
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:ScriptDir 'appsettings.json'

# ---------------------------------------------------------------------------
#  Algemene instellingen voor internetverkeer
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Net.Http
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }
try {
    # Zorgt dat een eventuele bedrijfsproxy je Windows-login gebruikt
    if ([System.Net.WebRequest]::DefaultWebProxy) {
        [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    }
} catch { }

# Wordt tijdens wachten aangeroepen zodat het scherm niet "bevriest"
$script:UiPump = $null

$script:Token = $null
$script:TokenExpires = [datetime]::MinValue
$script:HttpClient = $null
$script:Config = $null
$script:UserAgent = 'SKV-Checker/1.0'

# ---------------------------------------------------------------------------
#  Hulpfuncties
# ---------------------------------------------------------------------------
function Get-ErrorText($err) {
    $ex = $err
    if ($err -is [System.Management.Automation.ErrorRecord]) { $ex = $err.Exception }
    $msgs = New-Object System.Collections.Generic.List[string]
    while ($ex) {
        if ($ex -isnot [System.Management.Automation.MethodInvocationException] -and
            $ex -isnot [System.AggregateException]) {
            if (-not $msgs.Contains($ex.Message)) { $msgs.Add($ex.Message) }
        }
        $ex = $ex.InnerException
    }
    if ($msgs.Count -eq 0) { return [string]$err }
    return ($msgs -join ' -> ')
}

function Wait-Task($Task) {
    while (-not $Task.IsCompleted) {
        if ($script:UiPump) { & $script:UiPump }
        Start-Sleep -Milliseconds 30
    }
    return $Task.GetAwaiter().GetResult()
}

function Read-Config {
    if (-not (Test-Path $script:ConfigPath)) {
        $voorbeeld = Join-Path $script:ScriptDir 'appsettings.example.json'
        if (Test-Path $voorbeeld) {
            Copy-Item $voorbeeld $script:ConfigPath
            throw "appsettings.json is zojuist aangemaakt (kopie van appsettings.example.json).`nVul daarin de URL's, je gebruikersnaam en je wachtwoord in:`n$($script:ConfigPath)`n`n(Rechtermuisknop > Openen met > Kladblok)"
        }
        throw "Configuratiebestand niet gevonden: $($script:ConfigPath)"
    }
    $raw = [IO.File]::ReadAllText($script:ConfigPath, [Text.Encoding]::UTF8)
    try { $cfg = $raw | ConvertFrom-Json }
    catch { throw "appsettings.json is geen geldige JSON. Controleer komma's en aanhalingstekens.`n$(Get-ErrorText $_)" }

    foreach ($veld in @('TokenUrl', 'CertificaatUrl', 'Username', 'Password')) {
        if (-not $cfg.$veld -or [string]::IsNullOrWhiteSpace([string]$cfg.$veld)) {
            throw "In appsettings.json ontbreekt de waarde voor '$veld'."
        }
    }
    $voorbeeldWaarden = @('Gebruikersnaam', 'Wachtwoord', 'VUL-HIER-JE-GEBRUIKERSNAAM-IN', 'VUL-HIER-JE-WACHTWOORD-IN')
    if ([string]$cfg.TokenUrl -notmatch '^https?://' -or [string]$cfg.CertificaatUrl -notmatch '^https?://') {
        throw "Vul in appsettings.json bij TokenUrl en CertificaatUrl een volledig adres in (beginnend met https://):`n$($script:ConfigPath)"
    }
    if ($voorbeeldWaarden -contains [string]$cfg.Username -or $voorbeeldWaarden -contains [string]$cfg.Password) {
        throw "Vul eerst je SKV-gebruikersnaam en -wachtwoord in, in appsettings.json:`n$($script:ConfigPath)`n`n(Rechtermuisknop > Openen met > Kladblok)"
    }
    if (-not $cfg.TokenMethod) { $cfg | Add-Member -NotePropertyName TokenMethod -NotePropertyValue 'AUTO' -Force }
    if (-not $cfg.TimeoutSeconds) { $cfg | Add-Member -NotePropertyName TimeoutSeconds -NotePropertyValue 30 -Force }
    return $cfg
}

function Get-HttpClient {
    if (-not $script:HttpClient) {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $script:HttpClient = New-Object System.Net.Http.HttpClient($handler)
        $script:HttpClient.Timeout = [TimeSpan]::FromSeconds([int]$script:Config.TimeoutSeconds)
        [void]$script:HttpClient.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $script:UserAgent)
    }
    return $script:HttpClient
}

function New-HttpResult($StatusCode, $Reason, $Body) {
    return [pscustomobject]@{
        StatusCode = [int]$StatusCode
        Reason     = [string]$Reason
        Body       = [string]$Body
        Ok         = ([int]$StatusCode -ge 200 -and [int]$StatusCode -lt 300)
    }
}

# Normale aanvraag via HttpClient
function Invoke-SkvHttp {
    param(
        [string]$Method,
        [string]$Url,
        [string]$BearerToken,
        [string]$FormBody
    )
    $client = Get-HttpClient
    $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), $Url)
    [void]$req.Headers.TryAddWithoutValidation('Accept', 'application/json')
    if ($BearerToken) {
        $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $BearerToken)
    }
    if ($FormBody) {
        $req.Content = New-Object System.Net.Http.StringContent($FormBody, [Text.Encoding]::UTF8, 'application/x-www-form-urlencoded')
    }
    $resp = Wait-Task ($client.SendAsync($req))
    $body = Wait-Task ($resp.Content.ReadAsStringAsync())
    return New-HttpResult ([int]$resp.StatusCode) $resp.ReasonPhrase $body
}

# Ontcijfert "chunked" antwoorden (stukjes met een lengte ervoor)
function ConvertFrom-ChunkedBytes([byte[]]$Data) {
    $out = New-Object System.IO.MemoryStream
    $pos = 0
    while ($pos -lt $Data.Length) {
        $lineEnd = $pos
        while ($lineEnd -lt $Data.Length - 1 -and -not ($Data[$lineEnd] -eq 13 -and $Data[$lineEnd + 1] -eq 10)) { $lineEnd++ }
        $sizeText = [Text.Encoding]::ASCII.GetString($Data, $pos, $lineEnd - $pos).Split(';')[0].Trim()
        if ($sizeText -eq '') { break }
        $size = [Convert]::ToInt32($sizeText, 16)
        if ($size -eq 0) { break }
        $start = $lineEnd + 2
        $out.Write($Data, $start, [Math]::Min($size, $Data.Length - $start))
        $pos = $start + $size + 2
    }
    return $out.ToArray()
}

# Kijkt of een "handmatig" ontvangen antwoord compleet is
function Find-HeaderEnd([byte[]]$Data) {
    for ($i = 0; $i -lt $Data.Length - 3; $i++) {
        if ($Data[$i] -eq 13 -and $Data[$i + 1] -eq 10 -and $Data[$i + 2] -eq 13 -and $Data[$i + 3] -eq 10) { return $i }
    }
    return -1
}

function Test-RawResponseComplete([byte[]]$Data) {
    $sep = Find-HeaderEnd $Data
    if ($sep -lt 0) { return $false }
    $head = [Text.Encoding]::ASCII.GetString($Data, 0, $sep)
    if ($head -match '(?im)^Content-Length:\s*(\d+)') {
        return ($Data.Length -ge ($sep + 4 + [int]$Matches[1]))
    }
    if ($head -match '(?im)^Transfer-Encoding:\s*chunked') {
        $staart = [Text.Encoding]::ASCII.GetString($Data, [Math]::Max($sep + 4, $Data.Length - 7), [Math]::Min(7, $Data.Length - $sep - 4))
        return $staart.EndsWith("0`r`n`r`n")
    }
    return $false
}

# Aanvraag "met de hand" voor GET + formulierdata (dat kan HttpClient in PowerShell 5.1 niet)
function Invoke-RawHttpWithBody {
    param(
        [string]$Method,
        [string]$Url,
        [string]$FormBody
    )
    $uri = [Uri]$Url
    $port = $uri.Port
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        Wait-Task ($tcp.ConnectAsync($uri.Host, $port)) | Out-Null
        $timeoutMs = [int]$script:Config.TimeoutSeconds * 1000
        $tcp.ReceiveTimeout = $timeoutMs
        $tcp.SendTimeout = $timeoutMs
        $stream = $tcp.GetStream()
        if ($uri.Scheme -eq 'https') {
            $ssl = New-Object System.Net.Security.SslStream($stream, $false)
            $ssl.AuthenticateAsClient($uri.Host, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
            $stream = $ssl
        }
        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($FormBody)
        $head = "$Method $($uri.PathAndQuery) HTTP/1.1`r`n" +
                "Host: $($uri.Host)`r`n" +
                "Accept: application/json`r`n" +
                "User-Agent: $($script:UserAgent)`r`n" +
                "Content-Type: application/x-www-form-urlencoded`r`n" +
                "Content-Length: $($bodyBytes.Length)`r`n" +
                "Connection: close`r`n`r`n"
        $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($headBytes, 0, $headBytes.Length)
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Flush()

        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 65536
        while ($true) {
            try { $read = Wait-Task ($stream.ReadAsync($buf, 0, $buf.Length)) }
            catch { if ($ms.Length -gt 0) { break } else { throw } }
            if ($read -le 0) { break }
            $ms.Write($buf, 0, $read)
            if (Test-RawResponseComplete $ms.ToArray()) { break }
        }
        $all = $ms.ToArray()
    }
    finally {
        $tcp.Close()
    }

    # Kop en inhoud scheiden
    $sep = Find-HeaderEnd $all
    if ($sep -lt 0) { throw "Onvolledig antwoord ontvangen van $($uri.Host)." }
    $headerText = [Text.Encoding]::ASCII.GetString($all, 0, $sep)
    $bodyRaw = New-Object byte[] ($all.Length - $sep - 4)
    [Array]::Copy($all, $sep + 4, $bodyRaw, 0, $bodyRaw.Length)

    $lines = $headerText -split "`r`n"
    $statusParts = $lines[0].Split(' ', 3)
    $code = [int]$statusParts[1]
    $reason = ''
    if ($statusParts.Length -gt 2) { $reason = $statusParts[2] }
    if ($headerText -match '(?im)^Transfer-Encoding:\s*chunked') {
        $bodyRaw = ConvertFrom-ChunkedBytes $bodyRaw
    }
    return New-HttpResult $code $reason ([Text.Encoding]::UTF8.GetString($bodyRaw))
}

# Haalt een foutmelding uit een antwoord (JSON-tekst, error_description, Message, of ruwe tekst)
function Get-ResponseMessage([string]$Body) {
    if ([string]::IsNullOrWhiteSpace($Body)) { return '' }
    try {
        $parsed = $Body | ConvertFrom-Json
        if ($parsed -is [string]) { return $parsed }
        foreach ($veld in @('error_description', 'Message', 'message', 'error', 'title')) {
            if ($parsed.PSObject.Properties[$veld] -and $parsed.$veld) { return [string]$parsed.$veld }
        }
    } catch { }
    $t = $Body.Trim()
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300) + '...' }
    return $t
}

# ---------------------------------------------------------------------------
#  Bearer-token
# ---------------------------------------------------------------------------
function Get-SkvToken([switch]$Force) {
    if (-not $Force -and $script:Token -and (Get-Date) -lt $script:TokenExpires) {
        return $script:Token
    }
    $cfg = $script:Config
    $form = 'grant_type=password&username=' + [Uri]::EscapeDataString([string]$cfg.Username) +
            '&password=' + [Uri]::EscapeDataString([string]$cfg.Password)

    $methode = ([string]$cfg.TokenMethod).ToUpperInvariant()
    $pogingen = @()
    switch ($methode) {
        'POST'  { $pogingen = @('POST') }
        'GET'   { $pogingen = @('GET') }
        default { $pogingen = @('POST', 'GET') }   # AUTO: eerst de standaard (POST), anders GET zoals in Postman
    }

    $fouten = New-Object System.Collections.Generic.List[string]
    foreach ($m in $pogingen) {
        try {
            if ($m -eq 'GET') { $r = Invoke-RawHttpWithBody -Method 'GET' -Url $cfg.TokenUrl -FormBody $form }
            else { $r = Invoke-SkvHttp -Method 'POST' -Url $cfg.TokenUrl -FormBody $form }
        }
        catch {
            $fouten.Add("$m : $(Get-ErrorText $_)")
            continue
        }
        if ($r.Ok) {
            $json = $null
            try { $json = $r.Body | ConvertFrom-Json } catch { }
            if ($json -and $json.access_token) {
                $script:Token = [string]$json.access_token
                $seconden = 0
                if ($json.PSObject.Properties['expires_in'] -and $json.expires_in) { [void][int]::TryParse([string]$json.expires_in, [ref]$seconden) }
                if ($seconden -gt 120) { $script:TokenExpires = (Get-Date).AddSeconds($seconden - 60) }
                else { $script:TokenExpires = (Get-Date).AddHours(23) }
                $script:TokenMethodUsed = $m
                return $script:Token
            }
            $fouten.Add("$m : antwoord bevat geen access_token")
        }
        else {
            $fouten.Add("$m : HTTP $($r.StatusCode) $($r.Reason) $(Get-ResponseMessage $r.Body)".Trim())
        }
    }
    throw "Token ophalen mislukt.`n" + ($fouten -join "`n")
}

# ---------------------------------------------------------------------------
#  Certificaat-controle
# ---------------------------------------------------------------------------
function ConvertTo-Datum($v) {
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { return $null }
    if ($v -is [datetime]) { return $v }
    if ($v -is [datetimeoffset]) { return $v.DateTime }
    $dto = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dto)) {
        return $dto.DateTime
    }
    return $null
}

# Beoordeelt een antwoord. Los van het scherm, zodat het te testen is.
function Get-CertificaatResultaat {
    param(
        [string]$Ubn,
        [string]$Am91,
        $Http,            # resultaat van Invoke-SkvHttp, of $null bij verbindingsfout
        [string]$Fout     # tekst bij verbindingsfout
    )
    $res = [pscustomobject]@{
        Ubn            = $Ubn
        Am91           = $Am91
        Uitkomst       = 'FOUT'     # OK / LET OP / FOUT
        Status         = ''
        GeldigTot      = ''
        Am91Type       = ''
        Certificaatnr  = ''
        AantalDieren   = ''
        Melding        = ''
        HttpCode       = ''
        RawJson        = ''
        Item           = $null
        Tijdstip       = Get-Date
    }

    if (-not $Http) {
        $res.Melding = ($Fout -replace "\s*`r?`n\s*", ' | ')
        return $res
    }

    $res.HttpCode = "$($Http.StatusCode) $($Http.Reason)".Trim()
    $res.RawJson = $Http.Body

    if (-not $Http.Ok) {
        $msg = Get-ResponseMessage $Http.Body
        $res.Melding = "HTTP $($res.HttpCode)"
        if ($msg) { $res.Melding += " - $msg" }
        return $res
    }

    $parsed = $null
    try { $parsed = $Http.Body | ConvertFrom-Json }
    catch {
        $res.Melding = 'Antwoord is geen geldige JSON'
        return $res
    }

    if ($parsed -is [string]) {
        $res.Melding = $parsed
        return $res
    }

    $items = @(@($parsed) | Where-Object { $null -ne $_ -and $_ -isnot [string] })
    if ($items.Count -eq 0) {
        $res.Melding = 'Geen certificaat gevonden (lege lijst [])'
        return $res
    }

    # Bij meerdere certificaten: het certificaat dat het langst geldig is
    $item = $items | Sort-Object -Property @{ Expression = { $d = ConvertTo-Datum $_.geldigTotDatum; if ($d) { $d } else { [datetime]::MinValue } } } -Descending | Select-Object -First 1
    $res.Item = $item
    $res.Status = [string]$item.status
    $datum = ConvertTo-Datum $item.geldigTotDatum
    if ($datum) { $res.GeldigTot = $datum.ToString('dd-MM-yyyy') } else { $res.GeldigTot = [string]$item.geldigTotDatum }
    $res.Am91Type = [string]$item.am91type
    $res.Certificaatnr = [string]$item.certificaatnummer
    if ($item.PSObject.Properties['stallijst'] -and $item.stallijst) { $res.AantalDieren = [string]@($item.stallijst).Count }

    $meldingen = New-Object System.Collections.Generic.List[string]
    $res.Uitkomst = 'OK'
    if ($res.Status -ne 'GECERTIFICEERD') {
        $res.Uitkomst = 'LET OP'
        $meldingen.Add('Status is niet GECERTIFICEERD')
    }
    if ($datum -and $datum.Date -lt (Get-Date).Date) {
        $res.Uitkomst = 'LET OP'
        $meldingen.Add('Certificaat is verlopen')
    }
    if ($items.Count -gt 1) { $meldingen.Add("$($items.Count) certificaten gevonden, langst geldige getoond") }
    $res.Melding = $meldingen -join '; '
    return $res
}

function Invoke-CertificaatControle([string]$Ubn, [string]$Am91) {
    $url = [string]$script:Config.CertificaatUrl
    if ($url.Contains('?')) { $url += '&' } else { $url += '?' }
    $url += 'UBN=' + [Uri]::EscapeDataString($Ubn) + '&AM91nummer=' + [Uri]::EscapeDataString($Am91)

    try {
        $token = Get-SkvToken
    }
    catch {
        return Get-CertificaatResultaat -Ubn $Ubn -Am91 $Am91 -Http $null -Fout (Get-ErrorText $_)
    }

    try {
        $r = Invoke-SkvHttp -Method 'GET' -Url $url -BearerToken $token
        if ($r.StatusCode -eq 401) {
            # Token verlopen of geweigerd: 1x opnieuw proberen met een nieuw token
            $token = Get-SkvToken -Force
            $r = Invoke-SkvHttp -Method 'GET' -Url $url -BearerToken $token
        }
        return Get-CertificaatResultaat -Ubn $Ubn -Am91 $Am91 -Http $r
    }
    catch {
        return Get-CertificaatResultaat -Ubn $Ubn -Am91 $Am91 -Http $null -Fout ('Geen verbinding: ' + (Get-ErrorText $_))
    }
}

# ---------------------------------------------------------------------------
#  JSON netjes inspringen (zonder waarden aan te passen)
# ---------------------------------------------------------------------------
$script:JsonFormatterCode = @'
using System;
using System.Text;
public static class SkvJsonFormatter
{
    public static string Format(string json, bool shorten, int maxLen)
    {
        if (string.IsNullOrEmpty(json)) return "";
        StringBuilder sb = new StringBuilder(json.Length + 1024);
        int ind = 0;
        int n = json.Length;
        int i = 0;
        while (i < n)
        {
            char c = json[i];
            if (c == '"')
            {
                int j = i + 1;
                while (j < n)
                {
                    if (json[j] == '\\') { j += 2; continue; }
                    if (json[j] == '"') break;
                    j++;
                }
                if (j >= n) j = n - 1;
                int len = j - i + 1;
                if (shorten && len > maxLen)
                    sb.Append(json, i, 60).Append("... [").Append(len - 2).Append(" tekens ingekort]\"");
                else
                    sb.Append(json, i, len);
                i = j + 1;
                continue;
            }
            if (c == '{' || c == '[')
            {
                char close = (c == '{') ? '}' : ']';
                int k = i + 1;
                while (k < n && char.IsWhiteSpace(json[k])) k++;
                if (k < n && json[k] == close) { sb.Append(c).Append(close); i = k + 1; continue; }
                ind++;
                sb.Append(c).Append("\r\n").Append(' ', ind * 4);
            }
            else if (c == '}' || c == ']')
            {
                ind = Math.Max(0, ind - 1);
                sb.Append("\r\n").Append(' ', ind * 4).Append(c);
            }
            else if (c == ',') sb.Append(",\r\n").Append(' ', ind * 4);
            else if (c == ':') sb.Append(": ");
            else if (!char.IsWhiteSpace(c)) sb.Append(c);
            i++;
        }
        return sb.ToString();
    }
}
'@

# Zet JSON netjes onder elkaar (ingebouwde C#-code voor snelheid; waarden blijven ongewijzigd)
function Format-JsonText([string]$Json, [bool]$Inkorten, [int]$MaxLengte = 150) {
    if (-not ('SkvJsonFormatter' -as [type])) {
        Add-Type -TypeDefinition $script:JsonFormatterCode -Language CSharp
    }
    return [SkvJsonFormatter]::Format($Json, $Inkorten, $MaxLengte)
}

# ---------------------------------------------------------------------------
#  Export naar tekstbestand
# ---------------------------------------------------------------------------
function Get-ExportTekst($Ubn, $Resultaten) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('SKV certificaatcontrole')
    [void]$sb.AppendLine('Datum/tijd : ' + (Get-Date).ToString('dd-MM-yyyy HH:mm:ss'))
    [void]$sb.AppendLine('UBN        : ' + $Ubn)
    [void]$sb.AppendLine(('-' * 100))
    foreach ($r in $Resultaten) {
        $label = '[' + $r.Uitkomst + ']'
        [void]$sb.Append($label.PadRight(10)).Append('AM91 ').Append($r.Am91.PadRight(12))
        if ($r.Item) {
            [void]$sb.Append('STATUS: ').Append($r.Status.PadRight(16)).Append('GELDIGTOTDATUM: ').Append($r.GeldigTot)
            [void]$sb.AppendLine()
            [void]$sb.Append(' ' * 27).Append('Type: ').Append($r.Am91Type).Append('   Certificaatnr: ').Append($r.Certificaatnr)
            if ($r.AantalDieren) { [void]$sb.Append('   Dieren op stallijst: ').Append($r.AantalDieren) }
            if ($r.Melding) { [void]$sb.AppendLine().Append(' ' * 27).Append('Let op: ').Append($r.Melding) }
        }
        else {
            [void]$sb.Append($r.Melding)
        }
        [void]$sb.AppendLine()
    }
    [void]$sb.AppendLine(('-' * 100))
    return $sb.ToString()
}

# Testmodus: alleen de functies laden, geen scherm tonen
if ($env:SKV_TEST -eq '1') { return }

# ===========================================================================
#  SCHERM
# ===========================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:UiPump = { [System.Windows.Forms.Application]::DoEvents() }

function Show-Fout([string]$Tekst, [string]$Titel = 'SKV Checker') {
    [void][System.Windows.Forms.MessageBox]::Show($Tekst, $Titel, 'OK', 'Error')
}

try { $script:Config = Read-Config }
catch {
    Show-Fout ("Het programma kan niet starten.`n`n" + (Get-ErrorText $_))
    return
}

$fontNormaal = New-Object System.Drawing.Font('Segoe UI', 9)
$fontVet = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$kleurOk = [System.Drawing.Color]::FromArgb(0, 128, 0)
$kleurLetOp = [System.Drawing.Color]::FromArgb(214, 120, 0)
$kleurFout = [System.Drawing.Color]::FromArgb(200, 0, 0)
$teken = @{ 'OK' = [string][char]0x2713; 'LET OP' = '!'; 'FOUT' = '!' }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'SKV Certificaat Checker'
$form.Size = New-Object System.Drawing.Size(980, 560)
$form.MinimumSize = New-Object System.Drawing.Size(820, 400)
$form.StartPosition = 'CenterScreen'
$form.Font = $fontNormaal

# --- UBN ---
$lblUbn = New-Object System.Windows.Forms.Label
$lblUbn.Text = 'UBN:'
$lblUbn.Location = New-Object System.Drawing.Point(12, 16)
$lblUbn.AutoSize = $true
$form.Controls.Add($lblUbn)

$txtUbn = New-Object System.Windows.Forms.TextBox
$txtUbn.Location = New-Object System.Drawing.Point(120, 12)
$txtUbn.Width = 140
$txtUbn.MaxLength = 15
$form.Controls.Add($txtUbn)

# --- AM91 ---
$lblAm = New-Object System.Windows.Forms.Label
$lblAm.Text = 'AM91-nummers:'
$lblAm.Location = New-Object System.Drawing.Point(12, 50)
$lblAm.AutoSize = $true
$form.Controls.Add($lblAm)

$alleenCijfers = {
    param($sender, $e)
    if (-not [char]::IsDigit($e.KeyChar) -and -not [char]::IsControl($e.KeyChar)) { $e.Handled = $true }
}
$txtUbn.Add_KeyPress($alleenCijfers)

$amVelden = @()
for ($k = 0; $k -lt 5; $k++) {
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point((120 + $k * 125), 46)
    $tb.Width = 115
    $tb.MaxLength = 10
    $tb.Add_KeyPress($alleenCijfers)
    $form.Controls.Add($tb)
    $amVelden += $tb
}

# --- Knoppen ---
$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = 'Controleer'
$btnCheck.Location = New-Object System.Drawing.Point(12, 84)
$btnCheck.Size = New-Object System.Drawing.Size(110, 30)
$form.Controls.Add($btnCheck)
$form.AcceptButton = $btnCheck

$btnWis = New-Object System.Windows.Forms.Button
$btnWis.Text = 'Wissen'
$btnWis.Location = New-Object System.Drawing.Point(130, 84)
$btnWis.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($btnWis)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = 'Exporteren...'
$btnExport.Location = New-Object System.Drawing.Point(228, 84)
$btnExport.Size = New-Object System.Drawing.Size(110, 30)
$btnExport.Enabled = $false
$form.Controls.Add($btnExport)

$lblTip = New-Object System.Windows.Forms.Label
$lblTip.Text = 'Tip: dubbelklik op een regel om het volledige resultaat (JSON) te bekijken.'
$lblTip.Location = New-Object System.Drawing.Point(350, 91)
$lblTip.AutoSize = $true
$lblTip.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblTip)

# --- Resultatenlijst ---
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(12, 124)
$grid.Size = New-Object System.Drawing.Size(940, 360)
$grid.Anchor = 'Top, Bottom, Left, Right'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.BackgroundColor = [System.Drawing.SystemColors]::Window
$grid.AutoSizeColumnsMode = 'None'

$kolommen = @(
    @{ Naam = 'Icoon';     Kop = '';               Breedte = 36 },
    @{ Naam = 'Am91';      Kop = 'AM91';           Breedte = 100 },
    @{ Naam = 'Uitkomst';  Kop = 'Resultaat';      Breedte = 80 },
    @{ Naam = 'Status';    Kop = 'STATUS';         Breedte = 140 },
    @{ Naam = 'GeldigTot'; Kop = 'GELDIGTOTDATUM'; Breedte = 120 },
    @{ Naam = 'Melding';   Kop = 'Melding';        Breedte = 300 }
)
foreach ($kol in $kolommen) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $kol.Naam
    $col.HeaderText = $kol.Kop
    $col.Width = $kol.Breedte
    $col.SortMode = 'NotSortable'
    [void]$grid.Columns.Add($col)
}
$grid.Columns['Melding'].AutoSizeMode = 'Fill'
$grid.Columns['Icoon'].DefaultCellStyle.Alignment = 'MiddleCenter'
$grid.Columns['Icoon'].DefaultCellStyle.Font = $fontVet
$form.Controls.Add($grid)

# --- Statusbalk ---
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Klaar. Vul een UBN en 1 tot 5 AM91-nummers in.'
[void]$statusStrip.Items.Add($statusLabel)
$form.Controls.Add($statusStrip)

$script:Resultaten = New-Object System.Collections.Generic.List[object]
$script:LaatsteUbn = ''

function Update-TokenStatus {
    if ($script:Token) {
        $statusLabel.Text += '   |   Token geldig tot ' + $script:TokenExpires.ToString('dd-MM HH:mm')
    }
}

function Add-ResultaatRegel($r) {
    $idx = $grid.Rows.Add($teken[$r.Uitkomst], $r.Am91, $r.Uitkomst, $r.Status, $r.GeldigTot, $r.Melding)
    $row = $grid.Rows[$idx]
    $row.Tag = $script:Resultaten.Count - 1
    $kleur = $kleurFout
    if ($r.Uitkomst -eq 'OK') { $kleur = $kleurOk }
    elseif ($r.Uitkomst -eq 'LET OP') { $kleur = $kleurLetOp }
    $row.Cells['Icoon'].Style.ForeColor = $kleur
    $row.Cells['Icoon'].Style.SelectionForeColor = $kleur
    $row.Cells['Uitkomst'].Style.ForeColor = $kleur
    if ($r.Uitkomst -eq 'FOUT') {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 235, 235)
    }
}

function Update-DetailTekst {
    $d = $script:Det
    if ([string]::IsNullOrEmpty($d.R.RawJson)) { $d.Txt.Text = '(geen antwoord ontvangen)' + "`r`n`r`n" + $d.R.Melding }
    else { $d.Txt.Text = Format-JsonText $d.R.RawJson $d.Chk.Checked }
    $d.Txt.SelectionStart = 0
    $d.Txt.SelectionLength = 0
}

function Save-Pdf([string]$Base64, [string]$Naam) {
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = 'PDF-bestand (*.pdf)|*.pdf'
    $sfd.FileName = $Naam
    if ($sfd.ShowDialog() -eq 'OK') {
        try {
            [IO.File]::WriteAllBytes($sfd.FileName, [Convert]::FromBase64String($Base64))
            $antw = [System.Windows.Forms.MessageBox]::Show("Opgeslagen:`n$($sfd.FileName)`n`nNu openen?", 'PDF opgeslagen', 'YesNo', 'Information')
            if ($antw -eq 'Yes') { Start-Process $sfd.FileName }
        }
        catch { Show-Fout ("PDF opslaan mislukt.`n" + (Get-ErrorText $_)) }
    }
}

# --- Detailvenster ---
function Show-Detail($r) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Resultaat  UBN $($r.Ubn)  -  AM91 $($r.Am91)"
    $dlg.Size = New-Object System.Drawing.Size(900, 650)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = $fontNormaal

    $info = New-Object System.Windows.Forms.Label
    $info.Location = New-Object System.Drawing.Point(10, 10)
    $info.Size = New-Object System.Drawing.Size(860, 36)
    $info.Anchor = 'Top, Left, Right'
    $t = "Resultaat: $($r.Uitkomst)     HTTP: $($r.HttpCode)     Opgevraagd: $($r.Tijdstip.ToString('dd-MM-yyyy HH:mm:ss'))"
    if ($r.AantalDieren) { $t += "     Dieren op stallijst: $($r.AantalDieren)" }
    if ($r.Melding) { $t += "`n$($r.Melding)" }
    $info.Text = $t
    $dlg.Controls.Add($info)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = 'Lange velden inkorten (PDF-data)'
    $chk.Checked = $true
    $chk.AutoSize = $true
    $chk.Location = New-Object System.Drawing.Point(10, 52)
    $dlg.Controls.Add($chk)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = 'Kopieer JSON'
    $btnCopy.Location = New-Object System.Drawing.Point(260, 48)
    $btnCopy.Size = New-Object System.Drawing.Size(110, 28)
    $dlg.Controls.Add($btnCopy)

    $btnPdf = New-Object System.Windows.Forms.Button
    $btnPdf.Text = 'Certificaat-PDF opslaan'
    $btnPdf.Location = New-Object System.Drawing.Point(378, 48)
    $btnPdf.Size = New-Object System.Drawing.Size(170, 28)
    $dlg.Controls.Add($btnPdf)

    $btnStal = New-Object System.Windows.Forms.Button
    $btnStal.Text = 'Stallijst-PDF opslaan'
    $btnStal.Location = New-Object System.Drawing.Point(556, 48)
    $btnStal.Size = New-Object System.Drawing.Size(160, 28)
    $dlg.Controls.Add($btnStal)

    $item = $r.Item
    $btnPdf.Enabled = [bool]($item -and $item.PSObject.Properties['certificaatPDF'] -and $item.certificaatPDF)
    $btnStal.Enabled = [bool]($item -and $item.PSObject.Properties['stallijstPDF'] -and $item.stallijstPDF)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true
    $txt.ReadOnly = $true
    $txt.ScrollBars = 'Both'
    $txt.WordWrap = $false
    $txt.MaxLength = [int]::MaxValue
    $txt.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $txt.BackColor = [System.Drawing.SystemColors]::Window
    $txt.Location = New-Object System.Drawing.Point(10, 84)
    $txt.Size = New-Object System.Drawing.Size(862, 515)
    $txt.Anchor = 'Top, Bottom, Left, Right'
    $dlg.Controls.Add($txt)

    # Het venster is "modaal" (blokkeert het hoofdscherm), dus deze gedeelde variabelen zijn veilig
    $script:Det = @{ R = $r; Item = $item; Txt = $txt; Chk = $chk }
    Update-DetailTekst
    $chk.Add_CheckedChanged({ Update-DetailTekst })

    $btnCopy.Add_Click({
        if ($script:Det.R.RawJson) { [System.Windows.Forms.Clipboard]::SetText((Format-JsonText $script:Det.R.RawJson $false)) }
    })

    $btnPdf.Add_Click({
        $d = $script:Det
        $naam = "$($d.R.Ubn)_$($d.R.Am91)_certificaat.pdf"
        if ($d.Item.PSObject.Properties['bestandnaam'] -and $d.Item.bestandnaam) { $naam = [string]$d.Item.bestandnaam }
        Save-Pdf ([string]$d.Item.certificaatPDF) $naam
    })

    $btnStal.Add_Click({
        $d = $script:Det
        Save-Pdf ([string]$d.Item.stallijstPDF) "$($d.R.Ubn)_$($d.R.Am91)_stallijst.pdf"
    })

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

# --- Acties ---
$btnCheck.Add_Click({
    $ubn = $txtUbn.Text.Trim()
    if ($ubn -notmatch '^\d+$') {
        Show-Fout 'Vul een geldig UBN in (alleen cijfers).'
        [void]$txtUbn.Focus()
        return
    }
    $lijst = New-Object System.Collections.Generic.List[string]
    foreach ($tb in $amVelden) {
        $v = $tb.Text.Trim()
        if ($v -eq '') { continue }
        if ($v -notmatch '^\d{1,10}$') {
            Show-Fout "AM91-nummer '$v' is ongeldig (alleen cijfers, maximaal 10)."
            [void]$tb.Focus()
            return
        }
        if (-not $lijst.Contains($v)) { $lijst.Add($v) }
    }
    if ($lijst.Count -eq 0) {
        Show-Fout 'Vul minimaal 1 AM91-nummer in.'
        [void]$amVelden[0].Focus()
        return
    }

    $btnCheck.Enabled = $false
    $btnWis.Enabled = $false
    $btnExport.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $grid.Rows.Clear()
    $script:Resultaten.Clear()
    $script:LaatsteUbn = $ubn

    try {
        # Eerst het token ophalen. Lukt dat niet, dan heeft doorgaan geen zin.
        $statusLabel.Text = 'Token ophalen...'
        [System.Windows.Forms.Application]::DoEvents()
        try { [void](Get-SkvToken) }
        catch {
            $statusLabel.Text = 'Token ophalen mislukt.'
            Show-Fout ((Get-ErrorText $_) + "`n`nControleer de gebruikersnaam, het wachtwoord en TokenUrl in appsettings.json.")
            return
        }

        $nr = 0
        foreach ($am in $lijst) {
            $nr++
            $statusLabel.Text = "Bezig met $nr van $($lijst.Count): AM91 $am ..."
            [System.Windows.Forms.Application]::DoEvents()
            $r = Invoke-CertificaatControle -Ubn $ubn -Am91 $am
            $script:Resultaten.Add($r)
            Add-ResultaatRegel $r
            [System.Windows.Forms.Application]::DoEvents()
        }
        $ok = @($script:Resultaten | Where-Object { $_.Uitkomst -eq 'OK' }).Count
        $statusLabel.Text = "Klaar: $ok van $($lijst.Count) gelukt."
        Update-TokenStatus
    }
    catch {
        Show-Fout ("Onverwachte fout.`n" + (Get-ErrorText $_))
        $statusLabel.Text = 'Er ging iets mis.'
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnCheck.Enabled = $true
        $btnWis.Enabled = $true
        $btnExport.Enabled = ($script:Resultaten.Count -gt 0)
    }
})

$btnWis.Add_Click({
    $txtUbn.Clear()
    foreach ($tb in $amVelden) { $tb.Clear() }
    $grid.Rows.Clear()
    $script:Resultaten.Clear()
    $btnExport.Enabled = $false
    $statusLabel.Text = 'Klaar. Vul een UBN en 1 tot 5 AM91-nummers in.'
    Update-TokenStatus
    [void]$txtUbn.Focus()
})

$btnExport.Add_Click({
    if ($script:Resultaten.Count -eq 0) { return }
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = 'Tekstbestand (*.txt)|*.txt'
    $sfd.FileName = 'SKV_controle_' + $script:LaatsteUbn + '_' + (Get-Date).ToString('yyyyMMdd_HHmm') + '.txt'
    $sfd.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if ($sfd.ShowDialog() -eq 'OK') {
        try {
            $tekst = Get-ExportTekst $script:LaatsteUbn $script:Resultaten
            [IO.File]::WriteAllText($sfd.FileName, $tekst, (New-Object System.Text.UTF8Encoding($true)))
            $statusLabel.Text = "Geexporteerd naar $($sfd.FileName)"
        }
        catch { Show-Fout ("Exporteren mislukt.`n" + (Get-ErrorText $_)) }
    }
})

$grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0) { return }
    $idx = [int]$grid.Rows[$e.RowIndex].Tag
    Show-Detail $script:Resultaten[$idx]
})

$form.Add_Shown({ [void]$txtUbn.Focus() })
$form.Add_FormClosed({ if ($script:HttpClient) { $script:HttpClient.Dispose() } })

[void]$form.ShowDialog()
$form.Dispose()
