# ITToolkit

PowerShell commands for the checks the IT team runs every day, on your own PC or on a
user's PC over the network. Every command returns the same kind of results, and
`ConvertTo-ITTicketNote` turns any of them into text you can paste into an ITHub ticket.

ITHub is where tickets, changes and records live. ITToolkit is what you run at the
keyboard to find out what is wrong. It complements ITHub rather than duplicating it.

## Commands

| Command | Answers | Changes anything? |
| --- | --- | --- |
| `Get-ITDeviceHealth` | Is this PC healthy? Uptime, pending restart, disk space, BitLocker, antivirus, firewall, updates, Secure Boot, domain/Entra/Intune join | No |
| `Get-ITPendingReboot` | Does it need a restart, and why? | No |
| `Get-ITLocalAdmin` | Who has local admin rights, and are they local, domain or Entra ID accounts? | No |
| `Get-ITInstalledSoftware` | What is installed, which version, and how do I uninstall it silently? | No |
| `Get-ITEventSummary` | What went wrong recently? Crashes, blue screens, unexpected restarts, disk and hardware errors | No |
| `Get-ITLoggedOnUser` | Who is signed in, and are there disconnected sessions? | No |
| `Test-ITNetwork` | Is the network the problem? Adapter, DHCP, gateway, DNS, Microsoft 365, proxy, time sync | No |
| `Test-ITPort` | Can this PC (or that PC) reach a server on a port? | No |
| `Clear-ITTempFile` | Free disk space by removing old temp files (supports `-WhatIf`) | **Yes** |
| `Get-ITUserStatus` | Why can't this user sign in? AD enabled, locked out, password expiry; Entra ID sync, sign-in block, licenses, MFA methods | No |
| `Get-ITLockoutSource` | Which computer keeps locking this account? | No |
| `Reset-ITUserPassword` | Reset to a readable passphrase, require a change, unlock (asks first, supports `-WhatIf`) | **Yes** |
| `New-ITPassphrase` | A temporary password that is easy to read out over the phone | No |
| `ConvertTo-ITTicketNote` | Turn any result into a note for the ticket | No |
| `Get-ITToolkitCommand` | What can ITToolkit do? (also exports a catalog for the command cookbook) | No |
| `Get-ITToolkitSetting` | Which thresholds and test targets are in effect? | No |

Every command has full help with examples: `Get-Help Get-ITDeviceHealth -Examples`.

## Everyday use

```powershell
# "My PC is slow / acting up"
Get-ITDeviceHealth -ComputerName PC0142
Get-ITEventSummary -ComputerName PC0142 -Hours 72

# Put the result in the ticket
Get-ITDeviceHealth -ComputerName PC0142 | ConvertTo-ITTicketNote -Clipboard

# "I can't get to the S: drive / printer"
Test-ITNetwork -ComputerName PC0142 -TcpTarget 'fs01:445'
Test-ITPort printsrv -Preset Printer -Source PC0142

# Disk full
Clear-ITTempFile -ComputerName PC0142 -WhatIf
Clear-ITTempFile -ComputerName PC0142

# Before restarting a server
Get-ITLoggedOnUser -ComputerName RDS01
Get-ITPendingReboot -ComputerName RDS01

# "I can't sign in"
Get-ITUserStatus jlee
Get-ITLockoutSource jlee
Reset-ITUserPassword jlee              # shows the new passphrase to read out
Get-ITUserStatus jlee | ConvertTo-ITTicketNote -Clipboard

# Check many PCs at once
Get-Content .\lab-pcs.txt | Get-ITDeviceHealth -Summary | Where-Object Fail -gt 0
Get-ADComputer -Filter 'Name -like "FS*"' | Get-ITPendingReboot | Where-Object RebootPending
```

Results are objects, so `Where-Object`, `Sort-Object`, `Export-Csv` and `Format-List *`
all work. The default view shows the useful columns; `Select-Object *` shows everything
(for example the `QuietUninstallString` of installed software).

## Requirements

- Windows 10, Windows 11, or Windows Server 2016 or later.
- Windows PowerShell 5.1 (built into Windows) or PowerShell 7, 64-bit. Nothing to install.
  The 32-bit "Windows PowerShell (x86)" window is refused, because it sees redirected
  system folders and would report wrong results.
- The execution policy must allow scripts (`RemoteSigned` or `AllSigned`; see
  [Code signing](#code-signing)). The Windows client default, `Restricted`, blocks all modules.
- **Remote computers**: PowerShell remoting (WinRM) enabled on the target, and you must be
  an administrator on it. On domain PCs WinRM is usually enabled by Group Policy;
  otherwise run `Enable-PSRemoting` on the target once.
- **Your own PC**: run PowerShell as administrator to include BitLocker and other users'
  temp folders. Without it those checks report *Info: run as administrator*
  instead of failing.

## User accounts (hybrid AD and Entra ID)

`Get-ITUserStatus`, `Get-ITLockoutSource` and `Reset-ITUserPassword` work against Active
Directory from the tech's PC. They read and write on the **PDC emulator** by default,
because it has the most current lockout and bad-password data and a reset there takes
effect at once. Use `-Server` to pick another domain controller.

What each tech needs:

- **ActiveDirectory module (RSAT)**. On Windows 10/11, from an elevated window:
  `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`
- **Reset and unlock rights** on the users' OUs, for `Reset-ITUserPassword`.
- **For `Get-ITLockoutSource`**: PowerShell remoting to the PDC emulator, as a domain admin
  or as a member of both *Remote Management Users* and *Event Log Readers* on the DCs.
  The second option is the one to give help desk staff.
- **For the Entra ID part of `Get-ITUserStatus`** (optional): Microsoft Graph PowerShell,
  connected once per window:
  ```powershell
  Install-Module Microsoft.Graph.Users, Microsoft.Graph.Identity.SignIns -Scope CurrentUser
  Connect-MgGraph -Scopes User.Read.All, UserAuthenticationMethod.Read.All, AuditLog.Read.All
  ```
  The first connection needs an admin to consent to those permissions for the tenant. Last
  sign-in time also needs Entra ID P1. Without Graph, the command checks AD only and
  says how to connect.

Things to know in a hybrid domain:

- After a reset, Entra Connect's password hash sync sends the new password to Microsoft 365
  within a few minutes. Microsoft 365 only forces the user to change it if Entra Connect has
  `ForcePasswordChangeOnLogOn` turned on. Otherwise the change happens at the next Windows
  sign-in or with Ctrl+Alt+Del, *Change a password*.
- Failed Microsoft 365 sign-ins do not lock the AD account (Entra ID has its own smart
  lockout), so `Get-ITLockoutSource` shows on-premises lockouts only.
- Enabling or disabling a user in AD reaches Microsoft 365 at the next sync (up to 30 minutes).
  `Get-ITUserStatus` flags the gap when the two disagree.
- `Reset-ITUserPassword` output shows the passphrase once. `ConvertTo-ITTicketNote` leaves it
  out, so it never ends up in ITHub.

## ITHub web interface

ITHub's Tools page runs ITToolkit through a locked-down PowerShell endpoint (JEA) on the
ITHub server. ITHub can call only `Invoke-ITHubTool` and `Get-ITHubToolCatalog`. The
endpoint runs as a group managed service account (gMSA) and records a transcript of every
call. The full design is in the *ITHub Tools* spec. The JSON that ITHub reads is shown in
[`docs/ithub/samples`](docs/ithub/samples).

Setting it up on the ITHub server (once):

1. **Create the gMSA** (needs the domain's KDS root key) and allow the ITHub server to use it:
   ```powershell
   New-ADServiceAccount -Name svc-ittoolkit -DNSHostName svc-ittoolkit.corp.example.com -PrincipalsAllowedToRetrieveManagedPassword 'ITHUB01$'
   Install-ADServiceAccount svc-ittoolkit      # on the ITHub server
   ```
2. **Give the gMSA its rights:** local admin on workstations by GPO, plus the domain's
   *Event Log Readers* and *Remote Management Users* groups for lockout lookups. Never
   Domain Admins. Deny it interactive and Remote Desktop sign-in by GPO.
3. **Install ITToolkit for all users** on the ITHub server: `.\Install-ITToolkit.ps1`.
4. **Register the endpoint** from an elevated Windows PowerShell 5.1 window:
   ```powershell
   & "$env:ProgramFiles\WindowsPowerShell\Modules\ITToolkit\1.2.0\ITHub\Install-ITHubEndpoint.ps1" -ITHubAccount CORP\svc-ithub -GmsaAccount 'CORP\svc-ittoolkit$'
   ```
   This also copies the client script to `C:\Program Files\ITToolkit\Invoke-ITHubRequest.ps1`.
5. **Point ITHub at it:** set `TOOLS_RUNNER_PATH` in ITHub's `.env` to that path.
6. **Optional, for the Entra ID part of user checks:** register an Entra app with the
   Microsoft Graph application permissions `User.Read.All`, `UserAuthenticationMethod.Read.All`
   and `AuditLog.Read.All`. Put its certificate in the server's `Cert:\LocalMachine\My`,
   give the gMSA read access to the private key, and set `GraphTenantId`, `GraphClientId`
   and `GraphCertificateThumbprint` under `ITHub` in `C:\ProgramData\ITToolkit\Settings.psd1`.

After each ITToolkit update, run step 3 and then step 4 again.

To check it works, sign in as the ITHub service account and run:
```powershell
'{"action":"catalog"}' | powershell.exe -NoProfile -File "C:\Program Files\ITToolkit\Invoke-ITHubRequest.ps1"
```

## Installing for the team

1. Put a copy of this repository on the IT share, for example `\\fs01\it$\ITToolkit`.
2. On each tech's PC, from an elevated PowerShell window:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File \\fs01\it$\ITToolkit\Install-ITToolkit.ps1
   ```
3. Open a new PowerShell window and run `Get-ITToolkitCommand`.

The installer copies the module to `C:\Program Files\WindowsPowerShell\Modules\ITToolkit\<version>`.
Both Windows PowerShell 5.1 and PowerShell 7 find it there. Without admin rights, use
`-Scope CurrentUser`.

**Updating.** Change `ModuleVersion` in `src\ITToolkit\ITToolkit.psd1`, add a line to
`CHANGELOG.md`, copy to the share and run the installer again. The previous version stays
installed, so you can go back with `Import-Module ITToolkit -RequiredVersion 1.0.0`.
`-RemoveOldVersions` cleans up old ones.

To push it to every tech PC automatically, run the installer from an Intune platform
script or a Group Policy startup script.

The target PCs you check do **not** need ITToolkit installed. Commands send their checks over
PowerShell remoting and bring back the results.

## Settings

Thresholds (disk space, uptime, patch age) and network test targets have defaults that
suit most PCs. To change them for everyone on a PC, create
`C:\ProgramData\ITToolkit\Settings.psd1` with only the values you want to change:

```powershell
@{
    Network = @{
        # Checked by every Test-ITNetwork run. Add a DC, file server and ITHub.
        InternalDnsNames = @('dc01.corp.example.com', 'fs01.corp.example.com')
        TcpTargets       = @('login.microsoftonline.com:443', 'outlook.office365.com:443', 'fs01.corp.example.com:445')
    }
    Health  = @{ UptimeDaysWarn = 7 }
}
```

`Get-ITToolkitSetting` shows every setting, its value and where the value came from.
Misspelled names produce a warning instead of being silently ignored. The file is read as data
(`Import-PowerShellDataFile`), so it cannot run code. Deploy it with Group Policy Preferences or
Intune so every tech uses the same values.

## Safety

- Everything except `Clear-ITTempFile` and `Reset-ITUserPassword` is read-only.
  `Reset-ITUserPassword` asks before every reset unless you add `-Confirm:$false`.
- `Clear-ITTempFile` only touches `C:\Windows\Temp` and each profile's `AppData\Local\Temp`,
  and only removes files created and last changed more than 7 days ago (configurable).
  Files in use are skipped. It never follows links or junctions, and skips a temp folder
  that is a link (or sits under one) with a warning, so a user cannot point it at other data.
  It supports `-WhatIf` and `-Confirm`, and the confirmation works for remote PCs too.
- Commands report what they could not check instead of hiding it: an event log that could
  not be read is a warning, not an empty (healthy-looking) result.
- Nothing is sent anywhere except to the computer you are checking. The network test only
  connects to the names and ports in its settings.
- For audit trails (NIST SP 800-171 3.3.1), turn on PowerShell Script Block Logging with
  Group Policy. It records every ITToolkit command and what it ran, on both your PC and the
  target.

## Code signing

If your PCs use the `AllSigned` execution policy, sign the module with your internal code
signing certificate before copying it to the share:

```powershell
.\build\Sign-ITToolkit.ps1
```

Sign again after every change, because editing a signed file invalidates its signature.

## ITHub and the command cookbook

- **Tickets**: pipe any result to `ConvertTo-ITTicketNote -Clipboard` and paste. Health and
  network notes start with a result count and a *Needs attention* list.
- **Cookbook**: `Get-ITToolkitCommand` returns every command with its synopsis, parameters
  and examples, taken from the help. Export it as the cookbook's starting catalog:
  ```powershell
  Get-ITToolkitCommand | ConvertTo-Json -Depth 5 | Set-Content .\ittoolkit-commands.json
  ```
  Cookbook entries can then call ITToolkit commands rather than repeat their logic.
- **Stable output**: each result has a type name (`ITToolkit.CheckResult`,
  `ITToolkit.Software`, and so on) and fixed properties. Other tools can rely on them, so
  add properties freely but treat renaming or removing one as a breaking change.

## Development

```
src/ITToolkit/
  ITToolkit.psd1            manifest: version and exported commands
  ITToolkit.psm1            loads Private/ then Public/
  ITToolkit.Defaults.psd1   default settings
  ITToolkit.Format.ps1xml   default table views
  Public/                   one exported command per file, file name = command name
  Private/Collectors.ps1    code that runs ON the target PC and returns raw facts
  Private/Converters.ps1    turns raw facts into OK/Warn/Fail results (runs on your PC)
  Private/Parsers.ps1       reads dsregcmd, quser, w32tm and netsh output
  Private/Directory.ps1     Active Directory and Microsoft Graph lookups (user commands)
  Private/UserConverters.ps1  turns AD and Entra ID data into user results
  Private/ITHub.ps1         the ITHub contract: tool list, parameter rules, JSON conversion
  RoleCapabilities/         the JEA role ITHub's account gets (two functions)
  ITHub/                    endpoint installer and the client script ITHub runs
docs/ithub/samples/         JSON envelopes and catalog, as ITHub receives them
  Data/Words.txt            word list for New-ITPassphrase
tests/                      Pester 5 tests
build/                      test runner, 5.1 compatibility check, signing
```

**How a command works.** `Open-ITTarget` connects to the PC: locally, or through a
remoting session. `Invoke-ITCollector` runs a collector there, a self-contained script
block that gathers raw facts. A `ConvertTo-IT*` function then judges those facts on your
PC. Keeping thresholds and wording out of the collectors means local and remote results
are identical, and the judging logic can be tested without Windows.

**Adding a command.**
1. Add a collector to `Private/Collectors.ps1` if you need new data. It must be
   self-contained: no ITToolkit functions or `$script:` variables (a test enforces this),
   5.1-compatible, and it should catch its own errors.
2. Add a converter to `Private/Converters.ps1` and tests for it in `tests/Converters.Tests.ps1`.
3. Add `Public/Verb-ITNoun.ps1` with comment-based help: synopsis, description, every
   parameter, at least one example (a test enforces this). Copy the
   `Open-ITTarget` / `try` / `finally Close-ITTarget` pattern from an existing command.
4. Add the name to `FunctionsToExport` in the manifest, a view to the format file if the
   output is a new type, and a line to `CHANGELOG.md`.

**Testing.**
```powershell
pwsh ./build/Invoke-Tests.ps1                        # any OS with PowerShell 7
powershell.exe -File .\build\Invoke-Tests.ps1        # Windows PowerShell 5.1
$env:ITTOOLKIT_TEST_REMOTE = 'PC0142'; pwsh ./build/Invoke-Tests.ps1   # also test remoting
```
The tests need Pester 5 (`Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck`).
On Windows, `tests/Windows.Tests.ps1` runs every command against the PC itself, so run
it from an elevated window. `build/Test-Compatibility.ps1` fails the run on PowerShell 7-only
syntax and on non-ASCII characters, which Windows PowerShell 5.1 misreads. CI on GitHub
(`.github/workflows/test.yml`) runs all of it on Windows PowerShell 5.1, PowerShell 7 and Linux.

## Known limits

- `quser`, `w32tm`, `netsh` and `dsregcmd` output is parsed in English. On other Windows
  display languages those checks report *Info* instead of a verdict.
- Sweeps (`Get-Content pcs.txt | Get-ITDeviceHealth -Summary`) check one PC at a time.
  This is fine for dozens of PCs; for hundreds, parallel sweeps are on the list for a
  later version.
- `Get-ITLoggedOnUser` needs `quser.exe`, which Windows Home editions do not have.
