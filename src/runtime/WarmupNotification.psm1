# WarmupNotification.psm1
# Light native Windows Toast notification helper for real background Codex warmup.
# Strictly best-effort: failure isolation ensures warmup execution is never blocked or failed.

function Show-WarmupNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Starting", "Success", "Failure")]
        [string]$Kind
    )

    try {
        $title = "Codex Warmup"
        $body = switch ($Kind) {
            "Starting" { "&#x6B63;&#x5728;&#x540E;&#x53F0;&#x9884;&#x70ED;&#x2026;" }
            "Success"  { "&#x9884;&#x70ED;&#x5B8C;&#x6210;&#x3002;" }
            "Failure"  { "&#x9884;&#x70ED;&#x5931;&#x8D25;&#xFF0C;&#x7CFB;&#x7EDF;&#x5C06;&#x5728; 5 &#x5206;&#x949F;&#x540E;&#x91CD;&#x8BD5;&#x3002;" }
        }

        $xmlString = "<toast><visual><binding template=`"ToastGeneric`"><text>$title</text><text>$body</text></binding></visual></toast>"

        $winRTType = [System.Type]::GetType("Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime")
        $appId = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"

        if ($null -ne $winRTType) {
            # In-process native WinRT toast (Windows PowerShell 5.1 interactive runtime)
            $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
            $doc.LoadXml($xmlString)
            $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        } else {
            # Fallback for PowerShell Core (pwsh) or environments where WinRT projection is missing:
            # Delegate to Windows PowerShell 5.1 asynchronously without blocking
            $winPs = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
            if (Test-Path $winPs) {
                $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(@"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
`$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
`$doc.LoadXml('$xmlString')
`$toast = New-Object Windows.UI.Notifications.ToastNotification `$doc
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('$appId').Show(`$toast)
"@))
                Start-Process -FilePath $winPs -ArgumentList "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encodedCommand -WindowStyle Hidden
            }
        }
    } catch {
        # Strictly best-effort: notification failure ≠ warmup failure
    }
}

Export-ModuleMember -Function Show-WarmupNotification
