#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$LogPath          = "C:\Temp\Deploy_Automacao.log",
    [string]$TimingCachePath  = "C:\Temp\Deploy_Automacao_Tempos.json"
)

$ErrorActionPreference = 'Stop'

# ---------- Funções Auxiliares ----------

function Write-Log {
    param(
        [string]$Texto,
        [ConsoleColor]$Cor = 'Gray'
    )
    $linha = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Texto
    Write-Host $linha -ForegroundColor $Cor
   
    # Suporte nativo ao modo Verbose integrado do PowerShell
    Write-Verbose $linha

    if (-not (Test-Path (Split-Path $LogPath))) {
        New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value $linha
}

function Test-Chocolatey {
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) { return }
   
    Write-Log "Chocolatey ausente. Instalando..." Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"
       
        if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
            throw "Falha ao validar a instalação do Chocolatey no PATH."
        }
    }
    catch {
        # Erro crítico: lança a exceção para interromper o fluxo do script
        throw "ERRO CRÍTICO: Não foi possível instalar o Chocolatey. Detalhes: $($_.Exception.Message)"
    }
}

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
    try {
        $dir = Split-Path $TimingCachePath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Cache | ConvertTo-Json | Set-Content -Path $TimingCachePath -Encoding UTF8
    } catch {
        Write-Log "Aviso: Não foi possível salvar o cache de tempos: $($_.Exception.Message)" Yellow
    }
}

function Sort-FilaPorTempoReal {
    param([array]$Fila, [hashtable]$Cache)
    $comHistorico = $Fila | Where-Object { $Cache.ContainsKey($_.Nome) } | Sort-Object { $Cache[$_.Nome] }
    $semHistorico = $Fila | Where-Object { -not $Cache.ContainsKey($_.Nome) }
    return @($comHistorico + $semHistorico)
}

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

function Install-Choco {
    param([string]$Pacote, [string[]]$ArgsExtras)
   
    $argumentos = @('upgrade', $Pacote, '-y', '--no-progress', '--accept-license')
    if ($ArgsExtras) { $argumentos += $ArgsExtras }
   
    $p = Start-Process choco.exe -ArgumentList $argumentos -Wait -NoNewWindow -PassThru
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Ok = $p.ExitCode -in 0, 1641, 3010 }
}

# ---------- Função Principal ----------

function Main {
    try {
        $inicio = Get-Date
        $resultados = [System.Collections.Generic.List[pscustomobject]]::new()

        Test-Chocolatey

        $Fila = @(
            @{ Nome = "7-Zip";                           Tipo = "Choco"; Pacote = "7zip" }
            @{ Nome = "PDF24 Creator";                    Tipo = "Choco"; Pacote = "pdf24" }
            @{ Nome = "Google Chrome";                    Tipo = "Choco"; Pacote = "googlechrome"; ArgsExtras = @('--ignore-checksums') }
            @{ Nome = "Mozilla Firefox";                  Tipo = "Choco"; Pacote = "firefox" }
            @{ Nome = "Microsoft Edge";                   Tipo = "Choco"; Pacote = "microsoft-edge" }
            @{ Nome = "GLPI Agent";                       Tipo = "Choco"; Pacote = "glpi-agent" }
            @{ Nome = "Visual C++ Redistributable (x64)"; Tipo = "Choco"; Pacote = "vcredist140" }
            @{ Nome = "Microsoft OneDrive";               Tipo = "Choco"; Pacote = "onedrive" }
            @{ Nome = "Microsoft Teams";                  Tipo = "Choco"; Pacote = "microsoft-teams" }
            @{ Nome = "Microsoft 365 Business";           Tipo = "Choco"; Pacote = "office365business" }
        )

        $TimingCache = Get-TimingCache

        if ($TimingCache.Count -gt 0) {
            $Fila = Sort-FilaPorTempoReal -Fila $Fila -Cache $TimingCache
            Write-Log "Fila reordenada por tempo real medido (mais rápido -> mais lento)." Cyan
        } else {
            Write-Log "Sem histórico ainda. Ordenando por tamanho de pacote (menor -> maior)." Yellow
            $Fila = Sort-FilaPorTamanho -Fila $Fila
        }

        Write-Log "===== INÍCIO DA IMPLANTAÇÃO ($($Fila.Count) itens) =====" Cyan

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
                    $resultados.Add([pscustomobject]@{ Nome = $item.Nome; Status = 'OK'; Motivo = ''; Duracao = $duracao })
                    $TimingCache[$item.Nome] = $duracao
                } else {
                    $motivo = "instalador retornou código de saída $($r.ExitCode)"
                    Write-Log "  -> [FALHA] $motivo ($duracao s)" Red
                    $resultados.Add([pscustomobject]@{ Nome = $item.Nome; Status = 'FALHA'; Motivo = $motivo; Duracao = $duracao })
                }
            }
            catch {
                # Tratamento de exceção local da fila: captura o erro do pacote, mas NÃO interrompe os próximos
                $cronometro.Stop()
                $duracao = [math]::Round($cronometro.Elapsed.TotalSeconds, 1)
                Write-Log "  -> [FALHA] Exceção: $($_.Exception.Message) ($duracao s)" Red
                $resultados.Add([pscustomobject]@{ Nome = $item.Nome; Status = 'FALHA'; Motivo = $_.Exception.Message; Duracao = $duracao })
            }
        }

        Save-TimingCache -Cache $TimingCache

        # Geração do Relatório Final
        $tempoTotal = [math]::Round(((Get-Date) - $inicio).TotalSeconds, 1)
        $ok = ($resultados | Where-Object Status -eq 'OK').Count
        $falha = ($resultados | Where-Object Status -eq 'FALHA').Count

        $resumo = @(
            "========================================",
            "        RESULTADO DA INSTALAÇÃO",
            "========================================"
        )
        foreach ($r in ($resultados | Sort-Object Duracao)) {
            $resumo += "{0,-45} [{1}]  {2,6}s" -f $r.Nome, $r.Status, $r.Duracao
            if ($r.Status -eq 'FALHA') { $resumo += "  Motivo: $($r.Motivo)" }
        }
        $resumo += "========================================"
        $resumo += "Instalações com sucesso: $ok"
        $resumo += "Instalações com falha:   $falha"
        $resumo += "Tempo total:              $tempoTotal segundos"
        $resumo += "Log:                      $LogPath"
        $resumo += "Cache de tempos:          $TimingCachePath"
        $resumo += "========================================"

        foreach ($linha in $resumo) {
            Write-Host $linha
            Add-Content -Path $LogPath -Value $linha
        }
        Write-Log "===== FIM DA EXECUÇÃO =====" Cyan
    }
    catch {
        # Captura erros não tratados ou lançados explicitamente por 'throw' (ex: falha no Test-Chocolatey)
        Write-Log "EXECUÇÃO ABORTADA: $($_.Exception.Message)" Red
        exit 1
    }
}

# Executa o script chamando a função Main
Main
