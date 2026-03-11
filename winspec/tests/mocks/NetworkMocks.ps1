# tests/mocks/NetworkMocks.ps1 - Network mocking helpers for WinSpec tests
# Provides reusable mocks for network operations

# =============================================================================
# Activation Trigger Mocks
# =============================================================================

function Mock-ActivationNetworkSuccess {
    <#
    .SYNOPSIS
        Mocks successful network call to activation service
    #>
    Mock Invoke-RestMethod {
        return "# Mock activation script`nWrite-Host 'Activation successful'"
    } -ParameterFilter { $Uri -eq "https://get.activated.win" }
}

function Mock-ActivationNetworkTimeout {
    <#
    .SYNOPSIS
        Mocks network timeout for activation service
    #>
    Mock Invoke-RestMethod { 
        throw [System.Net.WebException]::new(
            "The operation has timed out.",
            [System.Net.WebExceptionStatus]::Timeout
        )
    } -ParameterFilter { $Uri -eq "https://get.activated.win" }
}

function Mock-ActivationNetworkNotFound {
    <#
    .SYNOPSIS
        Mocks 404 Not Found for activation service
    #>
    Mock Invoke-RestMethod { 
        throw [System.Net.HttpHttpRequestException]::new(
            "The remote server returned an error: (404) Not Found.",
            [System.Net.HttpStatusCode]::NotFound
        )
    } -ParameterFilter { $Uri -eq "https://get.activated.win" }
}

function Mock-ActivationNetworkDNSFailure {
    <#
    .SYNOPSIS
        Mocks DNS resolution failure for activation service
    #>
    Mock Invoke-RestMethod { 
        throw [System.Net.WebException]::new(
            "The remote name could not be resolved: 'get.activated.win'",
            [System.Net.WebExceptionStatus]::NameResolutionFailure
        )
    } -ParameterFilter { $Uri -eq "https://get.activated.win" }
}

function Mock-ActivationNetworkSSLFailure {
    <#
    .SYNOPSIS
        Mocks SSL certificate failure for activation service
    #>
    Mock Invoke-RestMethod { 
        throw [System.Net.WebException]::new(
            "The underlying connection was closed: Could not establish trust relationship for the SSL/TLS secure channel.",
            [System.Net.WebExceptionStatus]::TrustFailure
        )
    } -ParameterFilter { $Uri -eq "https://get.activated.win" }
}

function Mock-ActivationNetworkConnectionRefused {
    <#
    .SYNOPSIS
        Mocks connection refused for activation service
    #>
    Mock Invoke-RestMethod { 
        throw [System.Net.WebException]::new(
            "Unable to connect to the remote server.",
            [System.Net.WebExceptionStatus]::ConnectionClosed
        )
    } -ParameterFilter { $Uri -eq "https://get.activated.win" }
}

function Mock-ActivationNetworkProxyAuthRequired {
    <#
    .SYNOPSIS
        Mocks proxy authentication required
    #>
    Mock Invoke-RestMethod { 
        throw [System.Net.WebException]::new(
            "The remote server returned an error: (407) Proxy Authentication Required.",
            [System.Net.HttpStatusCode]::ProxyAuthenticationRequired
        )
    } -ParameterFilter { $Uri -eq "https://get.activated.win" }
}

function Mock-ActivationNetworkServerError {
    <#
    .SYNOPSIS
        Mocks server error (500) for activation service
    #>
    Mock Invoke-RestMethod { 
        throw [System.Net.HttpHttpRequestException]::new(
            "The remote server returned an error: (500) Internal Server Error.",
            [System.Net.HttpStatusCode]::InternalServerError
        )
    } -ParameterFilter { $Uri -eq "https://get.activated.win" }
}

# =============================================================================
# Office Trigger Mocks
# =============================================================================

function Mock-OfficeDownloadSuccess {
    <#
    .SYNOPSIS
        Mocks successful Office installer download
    #>
    Mock Invoke-WebRequest {
        return [PSCustomObject]@{
            StatusCode = 200
            Content = "mock installer content"
        }
    } -ParameterFilter { $Uri -match "office" }
}

function Mock-OfficeDownloadTimeout {
    <#
    .SYNOPSIS
        Mocks Office download timeout
    #>
    Mock Invoke-WebRequest { 
        throw [System.Net.WebException]::new(
            "The operation has timed out.",
            [System.Net.WebExceptionStatus]::Timeout
        )
    } -ParameterFilter { $Uri -match "office" }
}

function Mock-OfficeDownloadNotFound {
    <#
    .SYNOPSIS
        Mocks Office installer 404
    #>
    Mock Invoke-WebRequest { 
        throw [System.Net.WebException]::new(
            "The remote server returned an error: (404) Not Found.",
            [System.Net.HttpStatusCode]::NotFound
        )
    } -ParameterFilter { $Uri -match "office" }
}

# =============================================================================
# Generic Web Request Mocks
# =============================================================================

function Mock-WebRequestSuccess {
    <#
    .SYNOPSIS
        Mocks successful generic web request
    .PARAMETER Uri
        URI to match for this mock
    #>
    param(
        [string]$Uri = ".*"
    )
    
    Mock Invoke-WebRequest {
        return [PSCustomObject]@{
            StatusCode = 200
            Content = '{"status": "success"}'
        }
    } -ParameterFilter { $Uri -match $Uri }
}

function Mock-WebRequestFailure {
    <#
    .SYNOPSIS
        Mocks failed generic web request
    .PARAMETER Uri
        URI to match for this mock
    .PARAMETER StatusCode
        HTTP status code to return
    #>
    param(
        [string]$Uri = ".*",
        [int]$StatusCode = 500
    )
    
    Mock Invoke-WebRequest { 
        throw [System.Net.HttpHttpRequestException]::new(
            "The remote server returned an error: ($StatusCode)",
            [System.Net.HttpStatusCode]$StatusCode
        )
    } -ParameterFilter { $Uri -match $Uri }
}

# =============================================================================
# REST Method Mocks
# =============================================================================

function Mock-RestMethodSuccess {
    <#
    .SYNOPSIS
        Mocks successful generic REST request
    .PARAMETER Uri
        URI to match for this mock
    .PARAMETER Response
        Response content to return
    #>
    param(
        [string]$Uri = ".*",
        [string]$Response = '{"status": "success"}'
    )
    
    Mock Invoke-RestMethod {
        return $Response
    } -ParameterFilter { $Uri -match $Uri }
}

function Mock-RestMethodFailure {
    <#
    .SYNOPSIS
        Mocks failed generic REST request
    .PARAMETER Uri
        URI to match for this mock
    #>
    param(
        [string]$Uri = ".*"
    )
    
    Mock Invoke-RestMethod { 
        throw [System.Net.WebException]::new(
            "The remote server returned an error.",
            [System.Net.WebExceptionStatus]::ProtocolError
        )
    } -ParameterFilter { $Uri -match $Uri }
}

# =============================================================================
# Network Error Factory
# =============================================================================

function New-NetworkError {
    <#
    .SYNOPSIS
        Creates a network error for testing
    .PARAMETER ErrorType
        Type of error: Timeout, NotFound, DNS, SSL, ConnectionRefused, ProxyAuth, ServerError
    #>
    param(
        [ValidateSet("Timeout", "NotFound", "DNS", "SSL", "ConnectionRefused", "ProxyAuth", "ServerError")]
        [string]$ErrorType
    )
    
    switch ($ErrorType) {
        "Timeout" {
            return [System.Net.WebException]::new(
                "The operation has timed out.",
                [System.Net.WebExceptionStatus]::Timeout
            )
        }
        "NotFound" {
            return [System.Net.HttpHttpRequestException]::new(
                "The remote server returned an error: (404) Not Found.",
                [System.Net.HttpStatusCode]::NotFound
            )
        }
        "DNS" {
            return [System.Net.WebException]::new(
                "The remote name could not be resolved.",
                [System.Net.WebExceptionStatus]::NameResolutionFailure
            )
        }
        "SSL" {
            return [System.Net.WebException]::new(
                "Could not establish trust relationship for the SSL/TLS secure channel.",
                [System.Net.WebExceptionStatus]::TrustFailure
            )
        }
        "ConnectionRefused" {
            return [System.Net.WebException]::new(
                "Unable to connect to the remote server.",
                [System.Net.WebExceptionStatus]::ConnectionClosed
            )
        }
        "ProxyAuth" {
            return [System.Net.WebException]::new(
                "The remote server returned an error: (407) Proxy Authentication Required.",
                [System.Net.HttpStatusCode]::ProxyAuthenticationRequired
            )
        }
        "ServerError" {
            return [System.Net.HttpHttpRequestException]::new(
                "The remote server returned an error: (500) Internal Server Error.",
                [System.Net.HttpStatusCode]::InternalServerError
            )
        }
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Mock-ActivationNetworkSuccess',
    'Mock-ActivationNetworkTimeout',
    'Mock-ActivationNetworkNotFound',
    'Mock-ActivationNetworkDNSFailure',
    'Mock-ActivationNetworkSSLFailure',
    'Mock-ActivationNetworkConnectionRefused',
    'Mock-ActivationNetworkProxyAuthRequired',
    'Mock-ActivationNetworkServerError',
    'Mock-OfficeDownloadSuccess',
    'Mock-OfficeDownloadTimeout',
    'Mock-OfficeDownloadNotFound',
    'Mock-WebRequestSuccess',
    'Mock-WebRequestFailure',
    'Mock-RestMethodSuccess',
    'Mock-RestMethodFailure',
    'New-NetworkError'
)
