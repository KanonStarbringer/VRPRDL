# =============================================================================
# rodar_hexaly.ps1
# -----------------------------------------------------------------------------
# Resolve as 60 inst rR ncias VRPRDL (40 originais + 20 adicionais) usando o
# Hexaly Optimizer 14.x via vrprdl_hexaly.py.
#
# Uso (PowerShell):
#     # bateria completa, conforme TL do artigo Tzbaygin et al. (2017):
#     #   - 7200 s (2 h) por inst rR ncia com n <= 60
#     #   - 21600 s (6 h) por inst rR ncia com n = 120
#     .\rodar_hexaly.ps1
#
#     # smoke test (60 s por inst rR ncia, todas as 60):
#     .\rodar_hexaly.ps1 -SmokeTimeLimit 60
#
#     # rodar s s as 40 originais:
#     .\rodar_hexaly.ps1 -OnlyOriginal
#
#     # pular inst rR ncias j r processadas (pega de onde parou):
#     .\rodar_hexaly.ps1 -SkipExisting
# =============================================================================

[CmdletBinding()]
param(
    [int]$SmokeTimeLimit = 0,                 # > 0 sobrescreve TL adaptativo
    [int]$Threads        = 4,
    [int]$Seed           = 1,
    [switch]$OnlyOriginal,
    [switch]$OnlyExtra,
    [switch]$SkipExisting,
    [string]$HexalyDir   = 'C:\hexaly_14_5'
)

$ErrorActionPreference = 'Stop'

# --------- caminhos absolutos (independente do cwd) --------------------------
$Root          = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Script        = Join-Path $PSScriptRoot 'vrprdl_hexaly.py'
$LogsDir       = Join-Path $PSScriptRoot 'logs_hexaly'
$SolsDir       = Join-Path $PSScriptRoot 'sols_hexaly'
$SummaryFile   = Join-Path $LogsDir '_summary.csv'

$InstDirOrig   = Join-Path $Root 'instancias_turco\VRPRDL-triangle'
$InstDirV1     = Join-Path $Root 'instancias_turco\additional_instances\variant_1'
$InstDirV2     = Join-Path $Root 'instancias_turco\additional_instances\variant_2'

New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
New-Item -ItemType Directory -Force -Path $SolsDir | Out-Null

# --------- ambiente Hexaly --------------------------------------------------
$env:PYTHONPATH      = Join-Path $HexalyDir 'bin\python'
$env:HX_LICENSE_PATH = Join-Path $HexalyDir 'license.dat'
$env:PATH            = "$($HexalyDir)\bin;$env:PATH"

if (-not (Test-Path $Script))             { throw "n - o achei $Script" }
if (-not (Test-Path $env:HX_LICENSE_PATH)) { Write-Warning "license.dat n - o encontrada em $($env:HX_LICENSE_PATH)" }

# --------- monta lista de inst rR ncias --------------------------------------
function Add-Instances([string]$dir, [string]$family) {
    if (-not (Test-Path $dir)) { return @() }
    Get-ChildItem -Path $dir -Filter '*.txt' -File |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Family = $family
                Name   = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                Path   = $_.FullName
            }
        }
}

$Instances = @()
if (-not $OnlyExtra)    { $Instances += Add-Instances $InstDirOrig 'original' }
if (-not $OnlyOriginal) {
    $Instances += Add-Instances $InstDirV1 'variant_1'
    $Instances += Add-Instances $InstDirV2 'variant_2'
}

if ($Instances.Count -eq 0) { throw 'nenhuma inst rR ncia encontrada' }
Write-Host ("[batch] {0} inst rR ncias selecionadas" -f $Instances.Count)

# --------- header do _summary.csv (cria se ainda n - o existir) ---------------
if (-not (Test-Path $SummaryFile)) {
    'family,instance,n_customers,locs_ativos,nb_trucks_used,total_distance,total_lateness,status,time_limit_s,wall_time_s,sol_path,log_path' |
        Out-File -FilePath $SummaryFile -Encoding utf8
}

# --------- helper: l ^X o cabe ' alho da inst rR ncia para descobrir n -------------
function Get-NbCustomers([string]$path) {
    foreach ($line in Get-Content $path) {
        $clean = $line.Trim()
        if ($clean -eq '' -or $clean.StartsWith('#')) { continue }
        if ($clean -match '^\d+\s+\d+\s+\d+(\.\d+)?\s+\d+(\.\d+)?$') {
            return [int]($clean -split '\s+')[0]
        }
    }
    throw "n - o consegui identificar n_customers em $path"
}

# --------- loop principal ---------------------------------------------------
$idx = 0
foreach ($inst in $Instances) {
    $idx++
    $stem    = $inst.Name
    $LogFile = Join-Path $LogsDir ("{0}.log" -f $stem)
    $SolFile = Join-Path $SolsDir ("{0}.sol" -f $stem)

    if ($SkipExisting -and (Test-Path $SolFile)) {
        Write-Host ("[{0}/{1}] {2} : j r resolvida, pulando" -f $idx, $Instances.Count, $stem)
        continue
    }

    $n = Get-NbCustomers $inst.Path
    if ($SmokeTimeLimit -gt 0) {
        $tl = $SmokeTimeLimit
    } elseif ($n -le 60) {
        $tl = 7200
    } else {
        $tl = 21600
    }

    Write-Host ''
    Write-Host ("[{0}/{1}] {2} ({3}) : n={4}, TL={5}s" -f $idx, $Instances.Count, $stem, $inst.Family, $n, $tl) -ForegroundColor Cyan

    $start = Get-Date

    & python $Script $inst.Path `
        --time-limit $tl `
        --threads $Threads `
        --seed $Seed `
        --out $SolFile `
        --verbosity 1 *> $LogFile

    $code = $LASTEXITCODE
    $wall = (New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds

    # parse do .sol para alimentar o sum r rio
    if (Test-Path $SolFile) {
        $solLines  = Get-Content $SolFile
        $headerCmt = ($solLines | Where-Object { $_ -like '#*status*' } | Select-Object -First 1)
        $values    = ($solLines | Where-Object { $_ -notlike '#*' } | Select-Object -First 1) -split '\s+'
        $nbT = [int]$values[0]
        $cost = [double]$values[1]

        $status      = ''
        $totalLate   = ''
        $locsAtivos  = ''
        if ($headerCmt -match 'status=([^\s]+)\s+wall_time_s=([0-9.]+)') {
            $status = $Matches[1]
        }
        $costInfo = ($solLines | Where-Object { $_ -like '#*total_lateness*' } | Select-Object -First 1)
        if ($costInfo -match 'total_lateness=([0-9.eE+-]+)') {
            $totalLate = $Matches[1]
        }
        $locInfo = ($solLines | Where-Object { $_ -like '#*locations_active*' -or $_ -like '#*nb_locations_active*' } | Select-Object -First 1)
        if ($locInfo -match 'nb_locations_active=([0-9]+)') {
            $locsAtivos = $Matches[1]
        }
    } else {
        $nbT = '' ; $cost = '' ; $status = "exit=$code" ; $totalLate = '' ; $locsAtivos = ''
    }

    $row = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9:F2},{10},{11}' -f `
        $inst.Family, $stem, $n, $locsAtivos, $nbT, $cost, $totalLate, $status, $tl, $wall, $SolFile, $LogFile
    Add-Content -Path $SummaryFile -Value $row

    Write-Host ("        > status={0}, nb_trucks={1}, cost={2}, wall={3:F1}s" -f $status, $nbT, $cost, $wall) -ForegroundColor Yellow
}

Write-Host ''
Write-Host ("[batch] resumo gravado em {0}" -f $SummaryFile) -ForegroundColor Green
