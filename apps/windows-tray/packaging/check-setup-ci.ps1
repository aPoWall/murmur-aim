# Native acceptance of the actual release installer, only on a disposable hosted runner.
param(
    [Parameter(Mandatory=$true)][string]$SetupExe,
    [Parameter(Mandatory=$true)][string]$BundleDir,
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [Parameter(Mandatory=$true)][string]$ProofPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'This acceptance script is restricted to disposable GitHub-hosted Windows runners.'
}
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$work = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
if (-not $work.StartsWith($runnerTemp+'\', [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)) {
    throw 'Use a new directory below RUNNER_TEMP.'
}
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{427756A9-E238-4E87-B289-8DA6AD302E8C}_is1'
if (Test-Path -LiteralPath $uninstallKey) { throw 'Refuse to touch a pre-existing Murmur installation.' }
$startShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Murmur/Murmur.lnk'
if (Test-Path -LiteralPath $startShortcut) { throw 'Refuse to replace a pre-existing Murmur shortcut.' }
$setup = (Resolve-Path -LiteralPath $SetupExe).Path
$manifest = Get-Content -LiteralPath (Join-Path $BundleDir 'release-manifest.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Path $work | Out-Null
$install = Join-Path $work 'Murmur installed'
$sentinel = Join-Path $work 'profile-sentinel.txt'
Set-Content -LiteralPath $sentinel -Value 'Profile outside installation must survive' -NoNewline
$sentinelHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
$serviceName = 'MurmurInstallerAcceptance-' + [Guid]::NewGuid().ToString('N')
$serviceCommand = '"' + (Join-Path $install 'runtime/bin/murmur-svc.exe') + '"'
$serviceCreated = $false
$installed = $false

function Run-SetupProcess([string]$Executable, [string[]]$Arguments, [int]$Expected) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -PassThru
    if (-not $process.WaitForExit(180000)) {
        $process.Kill()
        throw 'The owned setup process exceeded its time budget.'
    }
    # Wait on this process, not its tree (an upgrade can restart a tray).
    if ($process.ExitCode -ne $Expected) { throw "Setup exit $($process.ExitCode), expected $Expected" }
}
function Remove-TestService {
    if (-not $script:serviceCreated) { return }
    $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
    if ($null -eq $service -or $service.PathName -cne $serviceCommand -or $service.State -ne 'Stopped') {
        throw 'Test service ownership/state changed; refusing cleanup.'
    }
    & sc.exe delete $serviceName
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove the owned test service.' }
    $script:serviceCreated = $false
}
function Check-Payload {
    foreach ($entry in $manifest.files.PSObject.Properties) {
        $file = Join-Path $install $entry.Name
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value.sha256) {
            throw "Installed payload differs: $($entry.Name)"
        }
    }
    if ((Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -cne $sentinelHash) { throw 'Profile sentinel changed.' }
}
$arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SHORTCUTCONFLICT=fail', '/MERGETASKS=!startup,!desktop', ('/DIR="'+$install+'"'))
try {
    Run-SetupProcess $setup ($arguments + ('/LOG="'+(Join-Path $work 'install.log')+'"')) 0
    $installed = $true
    $marker = Get-Content -LiteralPath (Join-Path $install 'murmur-install.json') -Raw | ConvertFrom-Json
    if ($marker.installer -ne 'setup' -or $marker.version -ne $manifest.declaredVersion) { throw 'Wrong installed ownership/version marker.' }
    Check-Payload
    $version = & node (Join-Path $install 'runtime/packages/setup/bin/murmur.mjs') version --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $version.version -ne $manifest.declaredVersion) { throw 'Installed CLI version failed.' }

    # A stopped but registered service must also block replacement (#291).
    # This is an SCM dependency probe, not a claim of a running Murmur daemon.
    & sc.exe create $serviceName binPath= $serviceCommand start= demand
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the disposable dependency probe.' }
    $serviceCreated = $true
    Run-SetupProcess $setup ($arguments + ('/LOG="'+(Join-Path $work 'blocked-upgrade.log')+'"')) 7
    Check-Payload
    Remove-TestService
    Run-SetupProcess $setup ($arguments + ('/LOG="'+(Join-Path $work 'upgrade.log')+'"')) 0
    Check-Payload
    Run-SetupProcess (Join-Path $install 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') 0
    $installed = $false
    foreach ($name in @('murmur-tray.exe', 'murmur-install.json', 'runtime/packages/setup/bin/murmur.mjs')) {
        if (Test-Path -LiteralPath (Join-Path $install $name)) { throw "Uninstall retained $name" }
    }
    if ((Test-Path -LiteralPath $uninstallKey) -or (Test-Path -LiteralPath $startShortcut)) { throw 'Uninstall retained registration or shortcut.' }
    if ((Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -cne $sentinelHash) { throw 'Uninstall changed the profile sentinel.' }
    [ordered]@{
        schema = 'murmur.windows-installer-acceptance/1'
        sourceCommit = $manifest.sourceCommit
        installerSha256 = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
        checks = @('silent-install', 'installed-payload-hashes', 'installed-cli-version', 'registered-service-refusal-exit-7', 'unchanged-blocked-payload', 'upgrade-after-service-removal', 'uninstall', 'external-profile-sentinel-preserved')
        gui = 'not-tested'; loginReboot = 'not-tested'; realServiceRoundtrip = 'not-tested'
    } | ConvertTo-Json | Set-Content -LiteralPath $ProofPath -Encoding utf8
} finally {
    Remove-TestService
    if ($installed -and (Test-Path -LiteralPath (Join-Path $install 'unins000.exe'))) {
        Run-SetupProcess (Join-Path $install 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') 0
    }
}
