#Requires -Version 7.6
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Instalação silenciosa de softwares padrão de estação de trabalho via Chocolatey.
.DESCRIPTION
    - A cada execução, todos os itens são instalados/atualizados para a versão mais recente.
    - Ordenação: com histórico de tempo real ($TimingCachePath), do mais rápido pro mais lento.
      Sem histórico, consulta o tamanho de cada pacote no Chocolatey antes de baixar
      qualquer coisa e ordena por tamanho (menor -> maior) como estimativa.
    - Cada item recebe [OK] ou [FALHA] sem interromper a fila. Log em $LogPath.
#>

param(
    [string]$LogPath         = "C:\Temp\Deploy_Automacao.log",
    [string]$TimingCachePath = "C:\Temp\Deploy_Automacao_Tempos.json"
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path $TimingCachePath) -Force | Out-Null
$script:Resultados = [System.Collections.Generic.List[pscustomobject]]::new()

function Write-Log {
    param([string]$Texto, [ConsoleColor]$Cor = 'Gray')
    $linha = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Texto
    Write-Host $linha -ForegroundColor $Cor
    Add-Content -Path $LogPath -Value $linha
}

function Test-Chocolatey {
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) { return }
    Write-Log "Chocolatey ausente. Instalando..." Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"
}

# ---------- Cache de tempos reais ----------

function Get-TimingCache {
    if (Test-Path $TimingCachePath) {
        try {
            $raw = Get-Content -Path $TimingCachePath -Raw | ConvertFrom-Json
            $dict = @{}
            foreach ($p in $raw.PSObject.Properties) { $dict[$p.Name] = [double]$p.Value }
            return $dict
        } catch {
            Write-Log "Cache de tempos corrompido, iniciando um novo. ($($_.Exception.Message))" Yellow
            return @{}
        }
    }
    return @{}
}

function Save-TimingCache {
    param([hashtable]$Cache)
    $Cache | ConvertTo-Json | Set-Content -Path $TimingCachePath -Encoding UTF8
}

function Sort-FilaPorTempoReal {
    param([array]$Fila, [hashtable]$Cache)
    $comHistorico = @()
    $semHistorico = @()
    foreach ($item in $Fila) {
        if ($Cache.ContainsKey($item.Nome)) { $comHistorico += $item }
        else { $semHistorico += $item }
    }
    $comHistorico = $comHistorico | Sort-Object { $Cache[$_.Nome] }
    return @($comHistorico + $semHistorico)
}

# ---------- Estimativa de tamanho (usada só sem histórico de tempo real) ----------

function Get-ChocoPackageSizeBytes {
    param([string]$PackageId)
    try {
        $filtro = "Id eq '$PackageId' and IsLatestVersion"
        $uri = "https://community.chocolatey.org/api/v2/Packages()?`$filter=$([Uri]::EscapeDataString($filtro))"
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 15
        $entry = if ($resp -is [array]) { $resp[0] } else { $resp }
        if ($entry -and $entry.PackageSize) { return [int64]$entry.PackageSize }
    } catch {
        Write-Log "Não foi possível consultar o tamanho do pacote '$PackageId': $($_.Exception.Message)" Yellow
    }
    return $null
}

function Sort-FilaPorTamanho {
    param([array]$Fila)
    $comTamanho = @()
    $semTamanho = @()
    foreach ($item in $Fila) {
        $tamanho = Get-ChocoPackageSizeBytes -PackageId $item.Pacote
        if ($null -ne $tamanho) { $comTamanho += [pscustomobject]@{ Item = $item; Tamanho = $tamanho } }
        else { $semTamanho += $item }
    }
    $ordenado = $comTamanho | Sort-Object Tamanho | ForEach-Object { $_.Item }
    return @($ordenado + $semTamanho)
}

# ---------- Instalador ----------

function Install-Choco {
    param([string]$Pacote, [string[]]$ArgsExtras)
    $argumentos = @('upgrade', $Pacote, '-y', '--no-progress', '--accept-license')
    if ($ArgsExtras) { $argumentos += $ArgsExtras }
    $p = Start-Process choco.exe -ArgumentList $argumentos -Wait -NoNewWindow -PassThru
    [pscustomobject]@{ ExitCode = $p.ExitCode; Ok = $p.ExitCode -in 0, 1641, 3010 }
}

# O instalador do Chrome vem sempre da mesma URL da Google (não versionada), então o
# checksum fixado no pacote frequentemente fica desatualizado. --ignore-checksums evita
# falha por esse motivo.
$Fila = @(
    @{ Nome = "7-Zip";                               Tipo = "Choco"; Pacote = "7zip" }
    @{ Nome = "PDF24 Creator";                        Tipo = "Choco"; Pacote = "pdf24" }
    @{ Nome = "Google Chrome";                        Tipo = "Choco"; Pacote = "googlechrome"; ArgsExtras = @('--ignore-checksums') }
    @{ Nome = "Mozilla Firefox";                      Tipo = "Choco"; Pacote = "firefox" }
    @{ Nome = "Microsoft Edge";                       Tipo = "Choco"; Pacote = "microsoft-edge" }
    @{ Nome = "GLPI Agent";                           Tipo = "Choco"; Pacote = "glpi-agent" }
    @{ Nome = "Visual C++ Redistributable (x64/x86)"; Tipo = "Choco"; Pacote = "vcredist140" }
    @{ Nome = "Microsoft OneDrive";                   Tipo = "Choco"; Pacote = "onedrive" }
    @{ Nome = "Microsoft Teams";                      Tipo = "Choco"; Pacote = "microsoft-teams" }
    @{ Nome = "Microsoft 365 Business";               Tipo = "Choco"; Pacote = "office365business" }
)

$inicio = Get-Date
$TimingCache = Get-TimingCache

if ($TimingCache.Count -gt 0) {
    $Fila = Sort-FilaPorTempoReal -Fila $Fila -Cache $TimingCache
    Write-Log "Fila reordenada por tempo real medido (mais rápido -> mais lento)." Cyan
} else {
    Write-Log "Sem histórico ainda. Ordenando por tamanho de pacote (menor -> maior)." Yellow
    $Fila = Sort-FilaPorTamanho -Fila $Fila
}

Write-Log "===== INÍCIO DA IMPLANTAÇÃO ($($Fila.Count) itens) =====" Cyan
Test-Chocolatey

foreach ($item in $Fila) {
    $tempoConhecido = if ($TimingCache.ContainsKey($item.Nome)) { " (histórico: $([math]::Round($TimingCache[$item.Nome],1))s)" } else { " (sem histórico)" }
    Write-Log "Instalando: $($item.Nome)$tempoConhecido"

    $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Install-Choco -Pacote $item.Pacote -ArgsExtras $item.ArgsExtras
        $cronometro.Stop()
        $duracao = [math]::Round($cronometro.Elapsed.TotalSeconds, 1)

        if ($r.Ok) {
            Write-Log "  -> [OK] (exit code $($r.ExitCode), $duracao s)" Green
            $script:Resultados.Add([pscustomobject]@{ Nome = $item.Nome; Status = 'OK'; Motivo = ''; Duracao = $duracao })
            $TimingCache[$item.Nome] = $duracao
        } else {
            $motivo = "instalador retornou código de saída $($r.ExitCode)"
            Write-Log "  -> [FALHA] $motivo ($duracao s)" Red
            $script:Resultados.Add([pscustomobject]@{ Nome = $item.Nome; Status = 'FALHA'; Motivo = $motivo; Duracao = $duracao })
        }
    }
    catch {
        $cronometro.Stop()
        $duracao = [math]::Round($cronometro.Elapsed.TotalSeconds, 1)
        Write-Log "  -> [FALHA] $($_.Exception.Message) ($duracao s)" Red
        $script:Resultados.Add([pscustomobject]@{ Nome = $item.Nome; Status = 'FALHA'; Motivo = $_.Exception.Message; Duracao = $duracao })
    }
}

Save-TimingCache -Cache $TimingCache

$tempoTotal = [math]::Round(((Get-Date) - $inicio).TotalSeconds, 1)
$ok = ($Resultados | Where-Object Status -eq 'OK').Count
$falha = ($Resultados | Where-Object Status -eq 'FALHA').Count

$resumo = @()
$resumo += "========================================"
$resumo += "        RESULTADO DA INSTALAÇÃO"
$resumo += "========================================"
foreach ($r in ($Resultados | Sort-Object Duracao)) {
    $resumo += "{0,-45} [{1}]  {2,6}s" -f $r.Nome, $r.Status, $r.Duracao
    if ($r.Status -eq 'FALHA') { $resumo += "  Motivo: $($r.Motivo)" }
}
$resumo += "========================================"
$resumo += "Instalações com sucesso: $ok"
$resumo += "Instalações com falha:    $falha"
$resumo += "Tempo total:              $tempoTotal segundos"
$resumo += "Log:                      $LogPath"
$resumo += "Cache de tempos:          $TimingCachePath"
$resumo += "========================================"

$resumo | ForEach-Object { Write-Host $; Add-Content -Path $LogPath -Value $ }
Write-Log "===== FIM DA EXECUÇÃO =====" Cyan
