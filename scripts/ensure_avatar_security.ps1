param(
    [Parameter(Mandatory = $true)]
    [string]$DataRoot
)

$resolvedDataRoot = [IO.Path]::GetFullPath($DataRoot)
$configDir = Join-Path $resolvedDataRoot 'config'
$tokenPath = Join-Path $configDir 'avatar-admin-token.txt'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    $token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $encoding = New-Object Text.UTF8Encoding($false)
    try {
        $stream = [IO.File]::Open(
            $tokenPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::Read
        )
        try {
            $writer = New-Object IO.StreamWriter($stream, $encoding)
            try {
                $writer.Write($token)
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    }
    catch [IO.IOException] {
        # Another launcher may have won the CreateNew race. Read its token below.
    }
}

$value = [IO.File]::ReadAllText($tokenPath).Trim()
if ($value -notmatch '^[A-Za-z0-9_-]{43}$') {
    throw 'Avatar admin token is invalid'
}
$value
