# Changelog

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
