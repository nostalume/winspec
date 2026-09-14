# Windows host capability checks.

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

Export-ModuleMember -Function 'Test-IsAdmin'
