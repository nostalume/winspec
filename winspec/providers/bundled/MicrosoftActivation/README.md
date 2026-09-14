# MicrosoftActivation

Bundled protocol-version-1 Action for the current Microsoft Activation Scripts
bootstrap. It is automatically discoverable and inert until selected.

```powershell
activate = @{
    Use = 'MicrosoftActivation'
    With = @{ Args = @('/HWID'); Interactive = $false }
}
```

The normative fields, endpoint, preview/run behavior, trust boundary, privileges,
and receipt are in
[Bundled Action providers](../../../../docs/bundled-providers.md#microsoftactivation).
The package entrypoint is the authority for implementation details.
