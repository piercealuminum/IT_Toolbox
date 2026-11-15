# ITHub samples

What ITHub receives from the client script (`Invoke-ITHubRequest.ps1`), produced by the
real ITToolkit code. ITHub's fake runner can return these, so ITHub is built and tested
against the same JSON the ITHub server will produce.

| File | Request | Status |
| --- | --- | --- |
| `catalog.json` | `{"action":"catalog"}` | (catalog) |
| `device-health.json` | `device-health` on PC0142 | completed, with a summary |
| `user-status.json` | `user-status` for jlee | completed, with a summary |
| `lockout-source.json` | `lockout-source` for jlee | completed |
| `port-test.json` | `port-test` to two ports | completed |
| `failed-unreachable.json` | `local-admins` on a PC that does not answer | failed |
| `failed-validation.json` | `device-health` with a bad computer name | failed, nothing ran |
| `user-lookup.json` | `user-lookup` for jlee (phase 2) | completed, one `ITToolkit.UserAccount` (`state` Current) |
| `account-unlock.json` | `account-unlock` for jlee (phase 2) | completed, `state` Before then After |
| `temp-cleanup-preview.json` | `temp-cleanup` with `"preview": true` (phase 2) | completed, `ITToolkit.TempScan` rows, nothing deleted |
| `temp-cleanup.json` | `temp-cleanup` (phase 2) | completed, `ITToolkit.TempCleanup` rows |

Every catalog tool has a `kind`: `read` changes nothing; `change` changes a computer or an
account and needs `tools.change`. A change tool runs without a prompt on the server, so
ITHub must ask the tech first: for `account-unlock`, show `user-lookup`'s `displayName`; for
`temp-cleanup`, show the preview.

Timestamps are fixed so the files change only when the envelope does. `tests/ITHub.Tests.ps1`
fails if a sample no longer has the shape the code produces. After a deliberate change,
regenerate them:

```powershell
$env:ITTOOLKIT_WRITE_SAMPLES = '1'; Invoke-Pester ./tests/ITHub.Tests.ps1
```
