# PoshAcmeIisServer — Let's Encrypt certificates for IIS

Location: `C:\SCRIPTS\Applications\OpenSource\PoshAcme\IisServer`
Version: 1.0.0 (`Data\PoshAcmeIisServer.json`)

The IIS role of PoshAcme (next to `ExchangeServer`). It renews the server's Let's Encrypt
certificates with Posh-ACME and binds each one to its IIS bindings with Posh-ACME.Deploy's
`Set-IISCertificate`. A server can have **several certificates**, and **one certificate can serve
several sites and bindings**.

## The mapping

`Data\Deployments\IisCertificates.json` (on the server only — never copied, synced or published)
says which certificate goes to which bindings:

```json
{
  "Certificates": [
    {
      "MainDomain": "srv010010037055.generationsgaither.com",
      "Names": [ "srv010010037055.generationsgaither.com" ],
      "Enabled": true,
      "Bindings": [
        { "SiteName": "Default Web Site", "IPAddress": "*", "Port": 443, "HostHeader": "", "RequireSNI": false },
        { "SiteName": "Default Web Site", "IPAddress": "*", "Port": 443, "HostHeader": "srv010010037055.generationsgaither.com", "RequireSNI": true }
      ]
    }
  ]
}
```

`MainDomain` is the Posh-ACME order. Each save keeps the previous version in `Data\Deployments\Backups`.

## Scripts

| Script | What it does |
|---|---|
| `Add-IisCertificate.ps1` | **Interactive.** Pick an existing certificate or enter a new name (+ extra names); pick IIS site(s) from the list; use their existing HTTPS bindings and/or add bindings (host name, port, IP, Require SNI). Requests a new certificate when needed, copying the DNS settings of an existing order. Offers to deploy at once. `-List` shows the mapping, `-Remove` takes an entry out. |
| `Renew-IisLE.ps1` | The nightly task. Renews each certificate when due, binds it to all its bindings, re-binds any binding that drifted, removes the old certificate only when no HTTPS binding still uses it, verifies. `-DeployCurrent`, `-ForceRenewal`, `-MainDomain`. |
| `Install-IisLE.ps1` | Creates the mapping (`-ImportCurrent`: from the bindings that already use Posh-ACME certificates), registers `\IIS\LetsEncrypt\RenewIisCertificates` (daily 01:00) as RunAs, records the install. |
| `Test-IisLEPrerequisites.ps1` | PASS/WARN/FAIL check; changes nothing. |

## Install (or move an existing C:\POSHACME setup)

1. SetupApplications → **PoshAcmeIisServer** → the server → Preview, Copy (fixes the modules too).
2. On the server, Windows PowerShell 5.1, elevated, **as GENERATIONSGAIT\Administrator**:
   ```powershell
   $Core = 'C:\SCRIPTS\Applications\OpenSource\PoshAcme'
   & "$Core\Test-PoshAcmePrerequisites.ps1"
   & "$Core\Install-PoshAcme.ps1"                          # moves C:\POSHACME\certs, disables the old task
   & "$Core\IisServer\Test-IisLEPrerequisites.ps1"
   & "$Core\IisServer\Install-IisLE.ps1" -ImportCurrent    # mapping from the current bindings + task
   & "$Core\IisServer\Renew-IisLE.ps1" -DeployCurrent      # bind and verify now
   ```
3. Add more certificates or sites any time: `Add-IisCertificate.ps1`.

Logs: `C:\SCRIPTS\Logs\IisLetsEncrypt.log`; transcripts in `Logs\Transcripts` (90 days); warnings
and errors also in the **Managed Powershell Scripts** event log.

## Notes

- Needs Posh-ACME, Posh-ACME.Deploy 2.x, IISAdministration 1.1+ (built into Server 2016+), WebAdministration.
- The task must run as the account that owns the Posh-ACME data (its DNS plugin arguments are
  encrypted for that account).
- Requesting a new certificate counts against Let's Encrypt's rate limits; Add-IisCertificate asks first.
