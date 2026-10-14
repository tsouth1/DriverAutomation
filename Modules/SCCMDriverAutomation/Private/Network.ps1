#region Network
<#
    All vendor traffic goes through a single System.Net.Http.HttpClient configured here. Design points:

    * TLS 1.2 (and TLS 1.3 where the OS supports it) only, HTTPS only. Certificate validation is never
      relaxed - if a TLS-inspecting proxy re-signs traffic, its root CA must be trusted in the
      LocalMachine store (that is how the platform is meant to work, and it is what security teams
      expect to see).
    * Proxy selection designed for a SYSTEM-context scheduled task. SYSTEM has no interactive user
      proxy settings, so the default mode reads the machine-wide WinHTTP proxy
      ('netsh winhttp set proxy ...'), which is where server proxy configuration belongs.
    * Proxy authentication via the computer account (Kerberos / NTLM negotiate - no stored secret), or
      an explicitly stored credential protected with DPAPI (LocalMachine scope) plus a SYSTEM/Administrators
      ACL.
    * A fixed, descriptive User-Agent so proxy / SWG / EDR rules can recognise and allow the traffic,
      and a domain allow-list enforced on the final (post-redirect) URL.
    * Resumable downloads with stall detection, retry with back-off and Retry-After support.
#>

$script:SDAHttp = @{
    Client   = $null
    Handler  = $null
    Settings = $null
}

function Initialize-SDANetwork {
    <#
    .SYNOPSIS
        Builds the shared HttpClient according to the Network section of the configuration.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    Add-Type -AssemblyName System.Net.Http

    # TLS 1.3 in SChannel is only available on Windows Server 2022 / Windows 11 (build 20348+). Asking
    # for it on older builds can break handshakes, so only add it where the OS supports it.
    $protocols = [System.Net.SecurityProtocolType]::Tls12
    $osBuild = [System.Environment]::OSVersion.Version.Build
    if ($osBuild -ge 20348 -and ([Enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'Tls13')) {
        $protocols = $protocols -bor [System.Net.SecurityProtocolType]::Tls13
    }
    [System.Net.ServicePointManager]::SecurityProtocol = $protocols
    [System.Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max([System.Net.ServicePointManager]::DefaultConnectionLimit, 8)

    $net = $Config.Network
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $handler.MaxAutomaticRedirections = 10
    $handler.UseCookies = $false
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None

    $proxyDescription = Set-SDAHandlerProxy -Handler $handler -Config $Config

    $client = New-Object System.Net.Http.HttpClient($handler, $true)
    $client.Timeout = [TimeSpan]::FromSeconds([int]$net.TimeoutSeconds)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', [string]$net.UserAgent)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', '*/*')

    $script:SDAHttp.Client   = $client
    $script:SDAHttp.Handler  = $handler
    $script:SDAHttp.Settings = $Config

    Write-SDALog "Network initialised: TLS=[$protocols], Proxy=[$proxyDescription], UserAgent=[$($net.UserAgent)]"
}

function Close-SDANetwork {
    [CmdletBinding()]
    param ()
    if ($script:SDAHttp.Client) {
        try { $script:SDAHttp.Client.Dispose() } catch { }
    }
    $script:SDAHttp.Client  = $null
    $script:SDAHttp.Handler = $null
}

function Get-SDAWinHttpProxy {
    <#
    .SYNOPSIS
        Reads the machine-wide WinHTTP proxy ('netsh winhttp show proxy') from the registry.
    .DESCRIPTION
        Parses the WinHttpSettings binary value directly so the result does not depend on the
        localised text output of netsh. Layout: [int32 struct size][int32 counter][int32 flags]
        [int32 proxyLen][proxy ASCII][int32 bypassLen][bypass ASCII]. Flag 0x2 = proxy configured.
    .OUTPUTS
        Hashtable: Server (string or $null), Bypass (string[]).
    #>
    [CmdletBinding()]
    param ()

    $result = @{ Server = $null; Bypass = @() }
    $keyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
    try {
        $bytes = (Get-ItemProperty -Path $keyPath -Name 'WinHttpSettings' -ErrorAction Stop).WinHttpSettings
    } catch {
        return $result
    }
    if ($null -eq $bytes -or $bytes.Length -lt 16) { return $result }

    $flags    = [BitConverter]::ToInt32($bytes, 8)
    $proxyLen = [BitConverter]::ToInt32($bytes, 12)
    if (($flags -band 0x2) -eq 0 -or $proxyLen -le 0 -or (16 + $proxyLen) -gt $bytes.Length) { return $result }

    $proxy  = [System.Text.Encoding]::ASCII.GetString($bytes, 16, $proxyLen)
    $offset = 16 + $proxyLen
    $bypass = ''
    if (($offset + 4) -le $bytes.Length) {
        $bypassLen = [BitConverter]::ToInt32($bytes, $offset)
        if ($bypassLen -gt 0 -and ($offset + 4 + $bypassLen) -le $bytes.Length) {
            $bypass = [System.Text.Encoding]::ASCII.GetString($bytes, $offset + 4, $bypassLen)
        }
    }

    $result.Server = ConvertTo-SDAProxyUri -ProxyString $proxy
    $result.Bypass = @($bypass -split '[;\s]+' | Where-Object { $_ -and $_ -ne '<local>' })
    return $result
}

function ConvertTo-SDAProxyUri {
    <#
    .SYNOPSIS
        Normalises WinHTTP/WinINET proxy strings ('host:port' or 'http=h:p;https=h:p') to a single URI.
    #>
    [CmdletBinding()]
    param ([string]$ProxyString)

    if ([string]::IsNullOrWhiteSpace($ProxyString)) { return $null }
    $entries = @($ProxyString -split ';' | Where-Object { $_ })
    $chosen = $entries | Where-Object { $_ -match '^https=' } | Select-Object -First 1
    if (-not $chosen) { $chosen = $entries | Where-Object { $_ -match '^http=' } | Select-Object -First 1 }
    if (-not $chosen) { $chosen = $entries[0] }
    $chosen = $chosen -replace '^[a-z]+=', ''
    if ($chosen -notmatch '^[a-z]+://') { $chosen = "http://$chosen" }
    return $chosen
}

function ConvertTo-SDABypassRegex {
    <#
    .SYNOPSIS
        Converts WinHTTP-style host patterns ('*.corp.local', '10.*') into WebProxy bypass regexes.
    #>
    [CmdletBinding()]
    param ([string[]]$Patterns)

    foreach ($p in @($Patterns | Where-Object { $_ })) {
        '^(https?://)?' + ([regex]::Escape($p.Trim()) -replace '\\\*', '.*') + '(:\d+)?/?$'
    }
}

function Set-SDAHandlerProxy {
    <#
    .SYNOPSIS
        Applies proxy mode and authentication to an HttpClientHandler. Returns a log-safe description.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Net.Http.HttpClientHandler]$Handler,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    $net = $Config.Network
    $proxy = $null
    $description = ''

    switch ($net.ProxyMode) {
        'None' {
            $Handler.UseProxy = $false
            return 'None (direct connection)'
        }
        'System' {
            # WinINET settings of the executing account (honours PAC / WPAD). For SYSTEM this is usually
            # empty, which is why WinHttp is the default mode.
            $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
            $description = 'System (WinINET / WPAD of executing account)'
        }
        'WinHttp' {
            $winHttp = Get-SDAWinHttpProxy
            if (-not $winHttp.Server) {
                $Handler.UseProxy = $false
                return 'WinHttp (no machine proxy configured - direct connection)'
            }
            $proxy = New-Object System.Net.WebProxy($winHttp.Server, $true, [string[]]@(ConvertTo-SDABypassRegex -Patterns $winHttp.Bypass))
            $description = "WinHttp ($($winHttp.Server))"
        }
        'Manual' {
            $proxy = New-Object System.Net.WebProxy([string]$net.ProxyUrl, $true, [string[]]@(ConvertTo-SDABypassRegex -Patterns @($net.ProxyBypass)))
            $description = "Manual ($($net.ProxyUrl))"
        }
    }

    switch ($net.ProxyAuthentication) {
        'None' {
            $proxy.Credentials = $null
            $description += ', auth: none'
        }
        'DefaultCredentials' {
            # Computer account (DOMAIN\SERVER$) via Negotiate/Kerberos when running as SYSTEM.
            $proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
            $description += ", auth: integrated ($([System.Security.Principal.WindowsIdentity]::GetCurrent().Name))"
        }
        'StoredCredential' {
            $cred = Get-SDAProxyCredential -Config $Config
            $proxy.Credentials = $cred
            $description += ", auth: stored credential ($($cred.UserName))"
        }
    }

    $Handler.UseProxy = $true
    $Handler.Proxy = $proxy
    return $description
}

function Set-SDAProxyCredential {
    <#
    .SYNOPSIS
        Stores a proxy credential encrypted with DPAPI (LocalMachine scope) in <DataRoot>\Secrets.
    .DESCRIPTION
        LocalMachine scope lets the SYSTEM scheduled task decrypt a credential entered by an
        administrator. Confidentiality relies on the file ACL (SYSTEM + Administrators only), which this
        function enforces. Prefer ProxyAuthentication = DefaultCredentials (computer account) where the
        proxy supports Kerberos/NTLM - then no secret is stored at all.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )

    Add-Type -AssemblyName System.Security
    $dir = $Config.Paths.Secrets
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    Set-SDAProtectedAcl -Path $dir

    $payload = @{ UserName = $Credential.UserName; Password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json -Compress
    $plain   = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $entropy = [System.Text.Encoding]::UTF8.GetBytes('SCCMDriverAutomation.ProxyCredential.v1')
    try {
        $cipher = [System.Security.Cryptography.ProtectedData]::Protect($plain, $entropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    } finally {
        [Array]::Clear($plain, 0, $plain.Length)
    }

    $file = Join-Path $dir 'proxy.credential'
    [System.IO.File]::WriteAllText($file, [Convert]::ToBase64String($cipher))
    Set-SDAProtectedAcl -Path $file
    Write-SDALog "Proxy credential for '$($Credential.UserName)' stored in $file (DPAPI LocalMachine, ACL SYSTEM/Administrators)."
}

function Get-SDAProxyCredential {
    [CmdletBinding()]
    param ([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    Add-Type -AssemblyName System.Security
    $file = Join-Path $Config.Paths.Secrets 'proxy.credential'
    if (-not (Test-Path -LiteralPath $file)) {
        throw "ProxyAuthentication is StoredCredential but no credential is stored. Run Set-DriverAutomationProxyCredential.ps1 first."
    }
    $entropy = [System.Text.Encoding]::UTF8.GetBytes('SCCMDriverAutomation.ProxyCredential.v1')
    $cipher  = [Convert]::FromBase64String((Get-Content -LiteralPath $file -Raw).Trim())
    $plain   = [System.Security.Cryptography.ProtectedData]::Unprotect($cipher, $entropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    try {
        $data = [System.Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
    } finally {
        [Array]::Clear($plain, 0, $plain.Length)
    }
    return (New-Object System.Net.NetworkCredential($data.UserName, $data.Password))
}

function Test-SDAAllowedHost {
    <#
    .SYNOPSIS
        $true when the URI host is one of (or a sub-domain of) Network.AllowedDomains.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][Uri]$Uri,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    $hostName = $Uri.Host.ToLowerInvariant()
    foreach ($domain in @($Config.Network.AllowedDomains)) {
        $d = ([string]$domain).Trim().TrimStart('.').ToLowerInvariant()
        if ($hostName -eq $d -or $hostName.EndsWith(".$d")) { return $true }
    }
    return $false
}

function ConvertTo-SDASecureUri {
    <#
    .SYNOPSIS
        Validates a vendor URL: absolute, allow-listed host, HTTPS (http:// links from vendor catalogs
        are upgraded - all three vendors serve the same content over HTTPS).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri)) { throw "Invalid URL: '$Url'" }
    if (-not (Test-SDAAllowedHost -Uri $uri -Config $Config)) {
        throw "Host '$($uri.Host)' is not in Network.AllowedDomains - refusing to download '$Url'."
    }
    if ($uri.Scheme -eq 'http') {
        $builder = New-Object System.UriBuilder($uri)
        $builder.Scheme = 'https'
        $builder.Port = -1
        $uri = $builder.Uri
    }
    if ($uri.Scheme -ne 'https') { throw "Only HTTPS downloads are permitted: '$Url'" }
    return $uri
}

function New-SDANoRetryException {
    param ([string]$Message)
    $ex = New-Object System.InvalidOperationException($Message)
    $ex.Data['SDANoRetry'] = $true
    return $ex
}

function Test-SDANoRetry {
    param ($Exception)
    $e = $Exception
    while ($null -ne $e) {
        if ($e.Data -and $e.Data.Contains('SDANoRetry')) { return $true }
        $e = $e.InnerException
    }
    return $false
}

function Invoke-SDADownload {
    <#
    .SYNOPSIS
        Downloads a file over HTTPS with resume, stall detection, retries and allow-list enforcement.
    .PARAMETER ExpectedSize
        Size published by the vendor catalog. When > 0 the final file must match exactly.
    .OUTPUTS
        Full path of the downloaded file.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int64]$ExpectedSize = 0
    )

    if ($null -eq $script:SDAHttp.Client) { throw 'Initialize-SDANetwork must be called before downloading.' }
    $config = $script:SDAHttp.Settings
    $net = $config.Network
    $uri = ConvertTo-SDASecureUri -Url $Url -Config $config

    $dir = Split-Path -Parent $DestinationPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    # Reuse a complete file from an earlier interrupted run when the size is known and matches.
    if ($ExpectedSize -gt 0 -and (Test-Path -LiteralPath $DestinationPath) -and (Get-Item -LiteralPath $DestinationPath).Length -eq $ExpectedSize) {
        Write-SDALog "Reusing previously downloaded file (size matches catalog): $DestinationPath"
        return $DestinationPath
    }

    $partial     = "$DestinationPath.partial"
    $maxAttempts = [int]$net.RetryCount + 1
    $stallMs     = [int]$net.StallTimeoutSeconds * 1000

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $response = $null
        $fileStream = $null
        $retryAfter = 0
        try {
            $existing = [int64]0
            if (Test-Path -LiteralPath $partial) { $existing = (Get-Item -LiteralPath $partial).Length }

            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $uri)
            if ($existing -gt 0) {
                $request.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue([System.Nullable[long]]$existing, [System.Nullable[long]]$null)
            }

            Write-SDALog ("Downloading {0} (attempt {1}/{2}{3})" -f $uri.AbsoluteUri, $attempt, $maxAttempts, $(if ($existing -gt 0) { ", resuming at $existing bytes" } else { '' }))
            $response = $script:SDAHttp.Client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()

            # Redirect targets must also be HTTPS and allow-listed (Dell, for example, redirects to dl.dell.com).
            $finalUri = $response.RequestMessage.RequestUri
            if ($finalUri.Scheme -ne 'https' -or -not (Test-SDAAllowedHost -Uri $finalUri -Config $config)) {
                throw (New-SDANoRetryException "Redirected to a non-HTTPS or non-allow-listed location: $($finalUri.AbsoluteUri)")
            }

            $status = [int]$response.StatusCode
            if ($status -eq 407) {
                throw (New-SDANoRetryException ("Proxy authentication required (HTTP 407) for identity '{0}'. Either allow the computer account through the proxy for the vendor domains, or set Network.ProxyAuthentication to StoredCredential." -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name))
            }
            if ($status -eq 416) {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                throw "Server rejected resume range (HTTP 416) - restarting download from zero."
            }
            if ($status -eq 429 -or $status -eq 408 -or $status -ge 500) {
                if ($response.Headers.RetryAfter -and $response.Headers.RetryAfter.Delta) {
                    $retryAfter = [int][Math]::Min(600, $response.Headers.RetryAfter.Delta.Value.TotalSeconds)
                }
                throw "Transient HTTP $status ($($response.ReasonPhrase))."
            }
            if (-not $response.IsSuccessStatusCode) {
                throw (New-SDANoRetryException "HTTP $status ($($response.ReasonPhrase)) for $($finalUri.AbsoluteUri)")
            }

            $append = ($existing -gt 0 -and $status -eq 206)
            if (-not $append) { $existing = 0 }
            $contentLength = $response.Content.Headers.ContentLength
            $total = if ($contentLength) { [int64]$contentLength + $existing } else { [int64]0 }
            if ($ExpectedSize -gt 0 -and $total -gt 0 -and $total -ne $ExpectedSize) {
                Write-SDALog "Server reports $total bytes but catalog says $ExpectedSize bytes - will verify after download." -Severity Warning
            }

            $mode = if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
            $fileStream = New-Object System.IO.FileStream($partial, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1MB)
            $netStream  = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $buffer     = New-Object byte[] (1MB)
            $written    = $existing
            $nextReport = 10
            $nextBytes  = 250MB
            $timer      = [System.Diagnostics.Stopwatch]::StartNew()

            while ($true) {
                $readTask = $netStream.ReadAsync($buffer, 0, $buffer.Length)
                if (-not $readTask.Wait($stallMs)) {
                    throw "Download stalled - no data received for $($net.StallTimeoutSeconds) seconds."
                }
                $read = $readTask.Result
                if ($read -le 0) { break }
                $fileStream.Write($buffer, 0, $read)
                $written += $read

                if ($total -gt 0) {
                    $pct = [int](($written * 100) / $total)
                    if ($pct -ge $nextReport) {
                        Write-SDALog ("  {0}% ({1:N0} MB of {2:N0} MB)" -f $pct, ($written / 1MB), ($total / 1MB))
                        $nextReport = ([int]($pct / 10) + 1) * 10
                    }
                } elseif ($written -ge $nextBytes) {
                    Write-SDALog ("  {0:N0} MB received" -f ($written / 1MB))
                    $nextBytes += 250MB
                }
            }
            $fileStream.Flush()
            $fileStream.Dispose()
            $fileStream = $null
            $timer.Stop()

            $finalSize = (Get-Item -LiteralPath $partial).Length
            if ($total -gt 0 -and $finalSize -ne $total) {
                throw "Connection closed early: received $finalSize of $total bytes."
            }
            if ($ExpectedSize -gt 0 -and $finalSize -ne $ExpectedSize) {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                throw "Downloaded size $finalSize does not match catalog size $ExpectedSize."
            }

            Move-Item -LiteralPath $partial -Destination $DestinationPath -Force
            $seconds = [Math]::Max(1, $timer.Elapsed.TotalSeconds)
            Write-SDALog ("Download complete: {0} ({1:N1} MB in {2:N0}s, {3:N1} MB/s)" -f $DestinationPath, ($finalSize / 1MB), $seconds, (($finalSize - $existing) / 1MB / $seconds))
            return $DestinationPath
        } catch {
            $message = Format-SDAError -ErrorRecord $_
            if ((Test-SDANoRetry -Exception $_.Exception) -or $attempt -ge $maxAttempts) {
                Write-SDALog "Download failed: $message" -Severity Error
                throw "Download of '$($uri.AbsoluteUri)' failed: $message"
            }
            $delay = if ($retryAfter -gt 0) { $retryAfter } else { [int]$net.RetryDelaySeconds * [Math]::Pow(2, $attempt - 1) }
            $delay = [int][Math]::Min($delay, 900)
            Write-SDALog "Download attempt $attempt failed: $message - retrying in $delay s." -Severity Warning
            Start-Sleep -Seconds $delay
        } finally {
            if ($fileStream) { try { $fileStream.Dispose() } catch { } }
            if ($response) { try { $response.Dispose() } catch { } }
        }
    }
}

function Test-SDAVendorHash {
    <#
    .SYNOPSIS
        Compares a file against a vendor-published hex digest; the algorithm is inferred from its length.
    .OUTPUTS
        Hashtable: Algorithm ($null if the digest format is not recognised), Expected, Actual, Match.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedHash
    )

    $expected = ($ExpectedHash -replace '[\s:-]', '').ToUpperInvariant()
    $algorithm = $null
    if ($expected -match '^[0-9A-F]+$') {
        $algorithm = switch ($expected.Length) { 32 { 'MD5' } 40 { 'SHA1' } 64 { 'SHA256' } 96 { 'SHA384' } 128 { 'SHA512' } default { $null } }
    }
    if (-not $algorithm) { return @{ Algorithm = $null; Expected = $expected; Actual = $null; Match = $false } }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm $algorithm).Hash.ToUpperInvariant()
    return @{ Algorithm = $algorithm; Expected = $expected; Actual = $actual; Match = ($actual -eq $expected) }
}

function Test-SDAAuthenticode {
    <#
    .SYNOPSIS
        Checks a file's Authenticode signature against the trusted publisher list.
    .OUTPUTS
        Hashtable: Status (Valid | NotSigned | Untrusted | Invalid), Signer, Message.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$TrustedPublishers
    )

    # Only these formats can carry an embedded Authenticode signature. For anything else (e.g. .zip)
    # Get-AuthenticodeSignature reports UnknownError, which must not be mistaken for tampering.
    $signable = @('.exe', '.dll', '.sys', '.cab', '.msi', '.msu', '.cat', '.ps1', '.psm1', '.psd1')
    if ($signable -notcontains [System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        return @{ Status = 'NotSigned'; Signer = $null; Message = 'File type cannot carry an Authenticode signature' }
    }

    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
    } catch {
        return @{ Status = 'Invalid'; Signer = $null; Message = $_.Exception.Message }
    }

    if ($sig.Status -eq 'NotSigned') { return @{ Status = 'NotSigned'; Signer = $null; Message = $sig.StatusMessage } }
    if ($sig.Status -ne 'Valid' -or $null -eq $sig.SignerCertificate) {
        return @{ Status = 'Invalid'; Signer = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject }); Message = "$($sig.Status): $($sig.StatusMessage)" }
    }

    $subject = $sig.SignerCertificate.Subject
    $cn = $null
    if ($subject -match '(?i)CN\s*=\s*"([^"]+)"') { $cn = $Matches[1] }
    elseif ($subject -match '(?i)CN\s*=\s*([^,]+)') { $cn = $Matches[1].Trim() }

    foreach ($pattern in $TrustedPublishers) {
        if ($cn -and $cn -like $pattern) { return @{ Status = 'Valid'; Signer = $cn; Message = "Signed by '$cn'" } }
    }
    return @{ Status = 'Untrusted'; Signer = $cn; Message = "Valid signature but signer '$cn' is not a trusted publisher" }
}

function Assert-SDAPayloadIntegrity {
    <#
    .SYNOPSIS
        Fail-closed integrity gate for a downloaded vendor payload.
    .DESCRIPTION
        * A vendor hash published in the (signature-verified) catalog must match when present.
        * If the file carries an Authenticode signature it must be Valid and from a trusted publisher -
          a broken or foreign signature is treated as tampering.
        * An unsigned file (e.g. some CAB driver packs) is accepted only when a vendor hash matched,
          which chains trust back to the signed catalog.
    .OUTPUTS
        Hashtable describing the verification (stored in the version ledger / manifest).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$CatalogEntry,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    $hashVerified = $false
    $hashAlgorithm = $null
    if ($CatalogEntry.Hash) {
        $h = Test-SDAVendorHash -Path $Path -ExpectedHash $CatalogEntry.Hash
        if ($h.Algorithm) {
            if (-not $h.Match) {
                throw "Integrity failure: $($h.Algorithm) of '$Path' is $($h.Actual) but the vendor catalog publishes $($h.Expected)."
            }
            $hashVerified = $true
            $hashAlgorithm = $h.Algorithm
            Write-SDALog "Vendor $($h.Algorithm) hash verified."
        } else {
            Write-SDALog "Catalog hash value '$($CatalogEntry.Hash)' is not a recognised digest format - relying on Authenticode." -Severity Warning
        }
    } else {
        Write-SDALog 'Catalog does not publish a hash for this payload - relying on Authenticode.' -Severity Warning
    }

    $sig = Test-SDAAuthenticode -Path $Path -TrustedPublishers @($Config.Security.TrustedPublishers)
    switch ($sig.Status) {
        'Valid'     { Write-SDALog "Authenticode verified: $($sig.Message)." }
        'NotSigned' {
            if (-not $hashVerified) { throw "Integrity failure: '$Path' is not signed and no vendor hash was available to verify it." }
            Write-SDALog 'Payload is not Authenticode-signed; accepted on the strength of the verified vendor hash from the signed catalog.'
        }
        default     { throw "Integrity failure: Authenticode check of '$Path' returned $($sig.Status) - $($sig.Message)." }
    }

    return @{
        Sha256          = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        VendorHashAlgo  = $hashAlgorithm
        VendorHashValid = $hashVerified
        Signature       = $sig.Status
        Signer          = $sig.Signer
    }
}

function Get-SDADefenderCommand {
    [CmdletBinding()]
    param ()
    # Prefer the newest platform binary (updated monthly), fall back to the in-box copy.
    $platform = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
    if (Test-Path -LiteralPath $platform) {
        $latest = Get-ChildItem -LiteralPath $platform -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property { try { [version]($_.Name -replace '-.*$', '') } catch { [version]'0.0' } } -Descending |
            ForEach-Object { Join-Path $_.FullName 'MpCmdRun.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($latest) { return $latest }
    }
    $inbox = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    if (Test-Path -LiteralPath $inbox) { return $inbox }
    return $null
}

function Invoke-SDADefenderScan {
    <#
    .SYNOPSIS
        On-demand Microsoft Defender scan of a file or folder. Throws if a threat is found.
    .DESCRIPTION
        Scanning explicitly (rather than excluding paths from AV) is the approach security teams expect.
        If Defender is unavailable (e.g. third-party AV, which will have scanned the files on write) the
        scan is skipped with a warning.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string]$Path)

    $mpcmd = Get-SDADefenderCommand
    if (-not $mpcmd) {
        Write-SDALog 'Microsoft Defender command line not found - on-demand scan skipped (real-time AV still applies).' -Severity Warning
        return
    }

    Write-SDALog "Defender on-demand scan: $Path"
    $exit = Invoke-SDAProcess -FilePath $mpcmd -Arguments ('-Scan -ScanType 3 -File "{0}" -DisableRemediation' -f $Path.TrimEnd('\')) -TimeoutMinutes 60
    switch ($exit) {
        0       { Write-SDALog 'Defender scan clean.' }
        2       { throw "Microsoft Defender reported a threat in '$Path'. Content has NOT been imported - review Defender detection history." }
        default { Write-SDALog "Defender scan returned exit code $exit (scan could not complete - e.g. Defender in passive/disabled mode)." -Severity Warning }
    }
}

#endregion Network
