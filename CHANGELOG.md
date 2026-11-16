# Changelog

## 1.4.0

- The ITHub catalog has a `resultTypes` section: the default columns for each result type
  (field, label, format, whether it may wrap, fallback field), the same short set PowerShell
  shows. ITHub can show compact result cards without choosing fields itself, and long
  technical fields such as SIDs and uninstall strings stay out of the card.

## 1.3.1

- Fixed: ITHub runs failed when the tech's name (`requestedBy`) held anything but letters,
  digits, spaces and `. @ ' _ \ -`, for example brackets or accented letters. Any name of 1
  to 128 characters is accepted now; only line breaks, control characters and `< >` are
  refused. It is display text only and never reaches a command.
- A refused request now echoes `requestedBy` too, like `tool`.

## 1.3.0

- ITHub phase 2 tools in the catalog: `user-lookup` (read), `account-unlock` and
  `temp-cleanup` (change, need `tools.change`). Every catalog tool now has a `kind`
  (`read` or `change`); `temp-cleanup` has a `preview` flag and a `previewResultType`.
- `Get-ITUserAccount`: an AD account as plain fields (`ITToolkit.UserAccount`).
- `Unlock-ITUser`: unlocks on the PDC emulator and returns the account before and after.
- `Clear-ITTempFile -Preview`: returns what each temp folder would free
  (`ITToolkit.TempScan`) and deletes nothing.
- `ITHub.DisabledTools` setting: tools refused at the endpoint whatever ITHub allows.
- Change tools run through ITHub with `-Confirm:$false`: ITHub asks the tech first.
- Fixed: a result property or request parameter named `Keys` was mistaken for the list of
  keys while building or checking JSON.
- Fixed: an ITHub run that found nothing (nobody signed in, nothing to clean) could be
  reported as failed with an unrelated error that had been silenced along the way. Only a
  tool's own errors now fail a run.

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
