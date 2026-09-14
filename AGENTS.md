# Repository guidance

WinSpec uses data-only PSD1/JSON and supports Windows PowerShell 5.1 plus
PowerShell 7. Preserve the State/Action boundary: `apply` converges declarative
State, `run` executes one explicit Action, and `workflow` is the sole ordered
multi-step owner.

Never execute configuration during loading or provider discovery, load
third-party modules in process, add aliases for removed commands, assemble shell
command strings, elevate implicitly, or contact real bundled-provider upstreams
from tests.

Keep provider discovery static and external messages bounded. Bundled providers
are automatically discoverable but must remain process-isolated and inert until
explicitly selected.

Run focused tests, then:

```powershell
.\tools\format.ps1 -Check
Invoke-Pester -Path .\tests
```

For CLI or protocol changes, test fresh Windows PowerShell 5.1 and PowerShell 7
processes. `-Json` stdout must contain exactly one document.
