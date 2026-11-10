# Changelog

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
