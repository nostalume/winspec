# WindowsDebloat

Bundled protocol-version-1 Action for the current Win11Debloat bootstrap. It is
automatically discoverable and inert until selected.

```powershell
debloat = @{
    Use = 'WindowsDebloat'
    With = @{ Args = @('-RunDefaultsLite', '-Silent'); Interactive = $false }
}
```

The normative fields, endpoint, preview/run behavior, trust boundary, recovery,
and receipt are in
[Bundled Action providers](../../../../docs/bundled-providers.md#windowsdebloat).
The package entrypoint is the authority for implementation details.
