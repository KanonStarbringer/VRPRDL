# =============================================================================
# rodar_hexaly_grandes.ps1
# -----------------------------------------------------------------------------
# Segunda passada do Hexaly: refina as inst N ncias n=60 e n=120 das originais.
#   - n = 60  -> TL = 300 s
#   - n = 120 -> TL = 1200 s
#
# Sobrescreve os .sol/log existentes dessas 20 inst N ncias.
# Mant lm intactas as demais (n <= 30 e variantes adicionais).
# =============================================================================

[CmdletBinding()]
param(
    [int]$Threads     = 4,
    [int]$Seed        = 1,
    [string]$HexalyDir = 'C:\hexaly_14_5'
)

$ErrorActionPreference = 'Stop'

$Root        = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Script      = Join-Path $PSScriptRoot 'vrprdl_hexaly.py'
$LogsDir     = Join-Path $PSScriptRoot 'logs_hexaly'
$SolsDir     = Join-Path $PSScriptRoot 'sols_hexaly'
$InstDirOrig = Join-Path $Root 'instancias_turco\VRPRDL-triangle'

$env:PYTHONPATH      = Join-Path $HexalyDir 'bin\python'
$env:HX_LICENSE_PATH = Join-Path $HexalyDir 'license.dat'
$env:PATH            = "$($HexalyDir)\bin;$env:PATH"

# le a primeira linha de par metros para descobrir n_customers
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

$todos = Get-ChildItem -Path $InstDirOrig -Filter '*.txt' -File | Sort-Object Name
$alvos = @()
foreach ($f in $todos) {
    $n = Get-NbCustomers $f.FullName
    if ($n -ge 60) {
        $tl = if ($n -ge 120) { 1200 } else { 300 }
        $alvos += [pscustomobject]@{
            Name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            Path = $f.FullName
            N    = $n
            TL   = $tl
        }
    }
}

Write-Host ("[grandes] {0} inst N ncias selecionadas (n>=60)" -f $alvos.Count)
Write-Host ("[grandes] tempo total estimado: {0} min" -f (($alvos | Measure-Object TL -Sum).Sum / 60))

$idx = 0
foreach ($a in $alvos) {
    $idx++
    $LogFile = Join-Path $LogsDir ("{0}.log" -f $a.Name)
    $SolFile = Join-Path $SolsDir ("{0}.sol" -f $a.Name)

    Write-Host ''
    Write-Host ("[{0}/{1}] {2} : n={3}, TL={4}s" -f $idx, $alvos.Count, $a.Name, $a.N, $a.TL) -ForegroundColor Cyan
    $start = Get-Date

    & python $Script $a.Path `
        --time-limit $a.TL `
        --threads $Threads `
        --seed $Seed `
        --out $SolFile `
        --verbosity 1 *> $LogFile

    $wall = (New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds

    if (Test-Path $SolFile) {
        $values = ((Get-Content $SolFile) | Where-Object { $_ -notlike '#*' } | Select-Object -First 1) -split '\s+'
        $nbT = [int]$values[0]
        $cost = [double]$values[1]
        Write-Host ("        > nb_trucks={0}, cost={1}, wall={2:F1}s" -f $nbT, $cost, $wall) -ForegroundColor Yellow
    } else {
        Write-Host ("        > ERRO: .sol n - o foi escrito") -ForegroundColor Red
    }
}

Write-Host ''
Write-Host ("[grandes] conclu \dQ do.  reconstrua o sum r rio com:") -ForegroundColor Green
Write-Host ("    python `"$PSScriptRoot\_rebuild_summary.py`"") -ForegroundColor Green
