# OfficeDeployment

Bundled protocol-version-1 Action for Microsoft's current Office online
installer. It is automatically discoverable and inert until selected.

```powershell
cacheOffice = @{
    Use = 'OfficeDeployment'
    With = @{ Path = './downloads/office'; Cache = $true }
}
```

The normative fields, endpoint, publisher check, destination, effects, and
receipt are in
[Bundled Action providers](../../../../docs/bundled-providers.md#officedeployment).
The package entrypoint is the authority for implementation details.
