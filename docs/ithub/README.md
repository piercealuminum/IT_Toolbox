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

Timestamps are fixed so the files change only when the envelope does. `tests/ITHub.Tests.ps1`
fails if a sample no longer has the shape the code produces. After a deliberate change,
regenerate them:

```powershell
$env:ITTOOLKIT_WRITE_SAMPLES = '1'; Invoke-Pester ./tests/ITHub.Tests.ps1
```
