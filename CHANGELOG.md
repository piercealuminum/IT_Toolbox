# Changelog

## 1.2.0

- ITHub web interface, phase 1 (read-only):
  - `Invoke-ITHubTool` checks a JSON request against the tool list and each parameter's rule,
    runs the tool and returns one JSON envelope: results in camelCase with their type,
    a summary for checks, warnings, errors and a ticket note.
  - `Get-ITHubToolCatalog` lists the 10 phase 1 tools with their parameters and rules, for
    ITHub's forms.
  - `RoleCapabilities/ITHubTools.psrc`: the JEA role that exposes only those two functions.
  - `ITHub/Install-ITHubEndpoint.ps1` registers the endpoint (gMSA, transcripts) and installs
    the client script at a fixed path. `ITHub/Invoke-ITHubRequest.ps1` is that client script:
    a request on standard input, the envelope on standard output, and always valid JSON.
  - App-only Microsoft Graph sign-in for user checks run through ITHub (`ITHub` settings).
  - Sample envelopes in `docs/ithub/samples`, checked against the code by the tests.
- Commands load the modules they need (CIM, Defender, firewall, network, event log, Active
  Directory, Microsoft Graph) themselves, since a JEA endpoint loads nothing automatically.
  Module code calls Select-Object, Get-Command and Get-Help module-qualified, because the
  endpoint replaces those with restricted versions.
- `ConvertTo-ITTicketNote -CollectedBy` names the person in the note, since ITHub's runs
  execute as a service account.
- CI registers a real JEA endpoint on Windows PowerShell 5.1 and calls it through the client
  script.

## 1.1.0

- `Get-ITUserStatus`: Active Directory account check (enabled, locked out, bad passwords,
  password and account expiry, last logon) plus Entra ID sync, sign-in block, licenses and
  MFA methods through Microsoft Graph when connected.
- `Get-ITLockoutSource`: lockout events (4740) from the PDC emulator with the caller computer.
- `Reset-ITUserPassword`: passphrase reset with change at next sign-in and unlock; confirms
  first, supports `-WhatIf`, and always returns the new passphrase even if a later step fails.
- `ConvertTo-ITTicketNote` handles user checks and never includes a reset passphrase.
- `Test-ITPort` waits 3 seconds by default (was 2), because Windows takes about 2 seconds to
  report a refused port.
- Tests: fixed two failures on Windows PowerShell 5.1 (port timing, link cleanup).

## 1.0.0

First release.

- `Get-ITDeviceHealth`: uptime, pending restart, disks, memory, BitLocker, antivirus,
  firewall, Windows updates, update scan, Secure Boot, device join and Intune enrollment.
  `-Summary` gives one line per computer for sweeps.
- `Get-ITPendingReboot`, `Get-ITLocalAdmin`, `Get-ITInstalledSoftware`,
  `Get-ITEventSummary`, `Get-ITLoggedOnUser`.
- `Test-ITNetwork` (adapters, gateway, DNS, Microsoft 365 reachability, proxy, time sync,
  clock difference) and `Test-ITPort` (presets, run from another computer with `-Source`).
- `Clear-ITTempFile` with `-WhatIf` and `-Confirm` support, local and remote.
- `New-ITPassphrase` for temporary passwords.
- `ConvertTo-ITTicketNote` for ITHub tickets.
- `Get-ITToolkitCommand` (catalog for the command cookbook) and `Get-ITToolkitSetting`.
- Organization settings file at `C:\ProgramData\ITToolkit\Settings.psd1`.
- Installer, signing script, Pester tests, Windows PowerShell 5.1 compatibility check, CI.
