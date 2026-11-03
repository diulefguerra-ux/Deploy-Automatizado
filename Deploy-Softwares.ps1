
#Requires -Version 7.0
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$LogPath = "$env:SystemDrive\Logs\Provisionamento.log",
    [string]$TimingCachePath = "$env:SystemDrive\Logs\Provisionamento_Tempos.json"
)

$ErrorActionPreference = 'Stop'

# =====================================================================
# 1. CONFIGURACOES
# =====================================================================

$Config = @{
    LogPath = $LogPath
    TimingCachePath = $TimingCachePath

    # Programas basicos instalados pelo Chocolatey
    ChocoPackages = @(
        @{ Nome = "7-Zip"; Pacote = "7zip"; ArgsExtras = @() }
        @{ Nome = "PDF24 Creator"; Pacote = "pdf24"; ArgsExtras = @() }
        @{ Nome = "Google Chrome"; Pacote = "googlechrome"; ArgsExtras = @('--ignore-checksums') }
        @{ Nome = "Mozilla Firefox"; Pacote = "firefox"; ArgsExtras = @() }
        @{ Nome = "Microsoft Edge"; Pacote = "microsoft-edge"; ArgsExtras = @() }
        @{ Nome = "Visual C++ Redistributable (x64)"; Pacote = "vcredist140"; ArgsExtras = @() }
        @{ Nome = "Microsoft OneDrive"; Pacote = "onedrive"; ArgsExtras = @() }
    )

    # Instaladores corporativos
    KasperskyAgentPath = "\\serv54d\KLSHARE\01 - Kaspersky Agente de Rede 16.3.lnk"
    KasperskyEndpointPath = "\\serv54d\KLSHARE\02 - Kaspersky Endpoint 14.1.lnk"

    MeshAgentPath = "\\arquivos\comum-desenbahia\USI\Install\meshagent64-Estacoes.exe"

    GlpiAgentSearchPath = "\\arquivos\comum-desenbahia\USI\Install"
    GlpiAgentFilter = "GLPI-Agent-*.msi"

    # Aplicativos Microsoft
    Microsoft365ScriptPath = "\\serv64d\Microsoft365Apps\InstallOffice.bat"
    TeamsPackagePath = "\\arquivos\comum-desenbahia\USI\Install\MSTeams-x64.msix"

    # Codigos de saida considerados sucesso
    SuccessExitCodes = @(0, 1641, 3010)

    # Processos que podem permanecer abertos
    ProcessosParaFechar = @(
        "OfficeClickToRun",
        "setup",
        "OfficeC2RClient",
        "TeamsMachineInstaller"
    )
}


# =====================================================================
# 2. FUNCOES AUXILIARES
# =====================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linha = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "INFO"    { Write-Host $linha -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $linha -ForegroundColor Green }
        "WARNING" { Write-Host $linha -ForegroundColor Yellow }
        "ERROR"   { Write-Host $linha -ForegroundColor Red }
    }

    Write-Verbose $linha

    $diretorio = Split-Path $Config.LogPath

    if (-not (Test-Path $diretorio)) {
        New-Item -ItemType Directory -Path $diretorio -Force | Out-Null
    }

    Add-Content -Path $Config.LogPath -Value $linha
}


# ---------------------------------------------------------------------
# Verificacao do Chocolatey
# ---------------------------------------------------------------------

function Test-Chocolatey {

    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        Write-Log "Chocolatey ja esta instalado." "SUCCESS"
        return
    }

    Write-Log "Chocolatey nao encontrado. Iniciando instalacao..." "WARNING"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        Invoke-Expression (
            (New-Object Net.WebClient).DownloadString(
                'https://community.chocolatey.org/install.ps1'
            )
        )

        $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"

        if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
            throw "Chocolatey nao foi encontrado no PATH apos a instalacao."
        }

        Write-Log "Chocolatey instalado e validado." "SUCCESS"
    }
    catch {
        Write-Log "Falha critica na instalacao do Chocolatey: $($_.Exception.Message)" "ERROR"
        throw
    }
}


# ---------------------------------------------------------------------
# Cache de tempos de instalacao
# ---------------------------------------------------------------------

function Get-TimingCache {

    if (-not (Test-Path $Config.TimingCachePath)) {
        return @{}
    }

    $raw = Get-Content -Path $Config.TimingCachePath -Raw |
        ConvertFrom-Json -ErrorAction SilentlyContinue

    if ($null -eq $raw) {
        Write-Log "Cache de tempos invalido. Um novo sera criado." "WARNING"
        return @{}
    }

    $cache = @{}

    foreach ($propriedade in $raw.PSObject.Properties) {
        $cache[$propriedade.Name] = [double]$propriedade.Value
    }

    return $cache
}


function Save-TimingCache {
    param([hashtable]$Cache)

    $diretorio = Split-Path $Config.TimingCachePath

    if (-not (Test-Path $diretorio)) {
        New-Item -ItemType Directory -Path $diretorio -Force | Out-Null
    }

    $Cache |
        ConvertTo-Json |
        Set-Content -Path $Config.TimingCachePath -Encoding UTF8

    Write-Log "Cache de tempos atualizado." "SUCCESS"
}


# ---------------------------------------------------------------------
# Ordenacao por tempo historico
# ---------------------------------------------------------------------

function Sort-FilaPorTempoReal {
    param(
        [array]$Fila,
        [hashtable]$Cache
    )

    $comHistorico = @(
        $Fila |
            Where-Object { $Cache.ContainsKey($_.Nome) } |
            Sort-Object { $Cache[$_.Nome] }
    )

    $semHistorico = @(
        $Fila |
            Where-Object { -not $Cache.ContainsKey($_.Nome) }
    )

    return @($comHistorico) + @($semHistorico)
}


# ---------------------------------------------------------------------
# Consulta de tamanho dos pacotes Chocolatey
# ---------------------------------------------------------------------

function Get-ChocoPackageSizeBytes {
    param([string]$PackageId)

    $filtro = "Id eq '$PackageId' and IsLatestVersion"

    $uri = "https://community.chocolatey.org/api/v2/Packages()?`$filter=$([Uri]::EscapeDataString($filtro))"

    $resp = Invoke-RestMethod `
        -Uri $uri `
        -TimeoutSec 15 `
        -ErrorAction SilentlyContinue

    $entry = if ($resp -is [array]) {
        $resp | Select-Object -First 1
    } else {
        $resp
    }

    if ($entry -and $entry.PackageSize) {
        return [int64]$entry.PackageSize
    }

    return $null
}


function Sort-FilaPorTamanho {
    param([array]$Fila)

    $comTamanho = @()
    $semTamanho = @()

    foreach ($item in $Fila) {

        $tamanho = Get-ChocoPackageSizeBytes -PackageId $item.Pacote

        if ($null -ne $tamanho) {
            $comTamanho += [pscustomobject]@{
                Item = $item
                Tamanho = $tamanho
            }
        }
        else {
            $semTamanho += $item
        }
    }

    $ordenado = @(
        $comTamanho |
            Sort-Object Tamanho |
            ForEach-Object { $_.Item }
    )

    return @($ordenado) + @($semTamanho)
}


# ---------------------------------------------------------------------
# Instalacao de pacotes Chocolatey
# ---------------------------------------------------------------------

function Install-ChocoPackage {
    param(
        [string]$PackageId,
        [string]$FriendlyName,
        [string[]]$ArgsExtras = @()
    )

    Write-Log "Instalando $FriendlyName..." "INFO"

    $argumentos = @(
        'upgrade',
        $PackageId,
        '-y',
        '--no-progress',
        '--accept-license'
    )

    $argumentos += $ArgsExtras

    $processo = Start-Process `
        -FilePath "choco.exe" `
        -ArgumentList $argumentos `
        -Wait `
        -NoNewWindow `
        -PassThru

    $codigo = $processo.ExitCode

    if ($codigo -in $Config.SuccessExitCodes) {
        Write-Log "$FriendlyName instalado com sucesso. Codigo: $codigo" "SUCCESS"
        return $true
    }

    Write-Log "Falha ao instalar $FriendlyName. Codigo: $codigo. Continuando..." "ERROR"

    return $false
}


# ---------------------------------------------------------------------
# Instalacao de EXE, LNK, BAT e MSI
# ---------------------------------------------------------------------

function Invoke-SilentInstall {
    param(
        [string]$FriendlyName,
        [string]$Path,
        [string]$ArgumentList = ""
    )

    if (-not (Test-Path $Path)) {
        Write-Log "Instalador de $FriendlyName nao encontrado: $Path" "WARNING"
        return $false
    }

    Write-Log "Instalando $FriendlyName..." "INFO"

    $extensao = [IO.Path]::GetExtension($Path).ToLowerInvariant()

    if ($extensao -eq ".bat") {
        $executavel = "$env:SystemRoot\System32\cmd.exe"
        $argumentos = "/c `"`"$Path`"`""

        if ($ArgumentList) {
            $argumentos += " $ArgumentList"
        }
    }
    else {
        $executavel = $Path
        $argumentos = $ArgumentList
    }

    $parametros = @{
        FilePath = $executavel
        Wait = $true
        WindowStyle = "Hidden"
        PassThru = $true
        ErrorAction = "Stop"
    }

    if ($argumentos) {
        $parametros.ArgumentList = $argumentos
    }

    $processo = Start-Process @parametros
    $codigo = $processo.ExitCode

    if ($codigo -in $Config.SuccessExitCodes) {
        Write-Log "$FriendlyName instalado com sucesso. Codigo: $codigo" "SUCCESS"
        return $true
    }

    Write-Log "Falha na instalacao de $FriendlyName. Codigo: $codigo. Continuando..." "ERROR"

    return $false
}


# ---------------------------------------------------------------------
# Instalacao do GLPI Agent via MSI
# ---------------------------------------------------------------------

function Install-GlpiAgent {

    Write-Log "Procurando instalador do GLPI Agent..." "INFO"

    $GlpiMsi = Get-ChildItem `
        -Path $Config.GlpiAgentSearchPath `
        -Filter $Config.GlpiAgentFilter `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $GlpiMsi) {
        Write-Log "Instalador do GLPI Agent nao encontrado. Pulando." "WARNING"
        return $false
    }

    return Invoke-SilentInstall `
        -FriendlyName "GLPI Agent" `
        -Path "msiexec.exe" `
        -ArgumentList "/i `"$($GlpiMsi.FullName)`" /qn /norestart"
}


# ---------------------------------------------------------------------
# Instalacao do Microsoft Teams
# ---------------------------------------------------------------------

function Install-MicrosoftTeams {

    if (-not (Test-Path $Config.TeamsPackagePath)) {
        Write-Log "Pacote do Microsoft Teams nao encontrado." "WARNING"
        return $false
    }

    Write-Log "Instalando Microsoft Teams..." "INFO"

    Add-AppxProvisionedPackage `
        -Online `
        -PackagePath $Config.TeamsPackagePath `
        -SkipLicense |
        Out-Null

    Write-Log "Microsoft Teams instalado com sucesso." "SUCCESS"

    return $true
}


# ---------------------------------------------------------------------
# Fechamento de processos residuais
# ---------------------------------------------------------------------

function Close-LeftoverInstallerWindows {
    param([string[]]$ProcessNames)

    foreach ($Name in $ProcessNames) {

        $processos = Get-Process -Name $Name -ErrorAction SilentlyContinue

        if ($processos) {
            Write-Log "Encerrando processo residual: $Name" "WARNING"

            $processos |
                Stop-Process -Force -ErrorAction Stop
        }
    }
}


# =====================================================================
# 3. FUNCAO PRINCIPAL
# =====================================================================

function Main {

    try {

        $inicio = Get-Date

        $resultados = [System.Collections.Generic.List[object]]::new()

        Write-Log "======================================================" "INFO"
        Write-Log " INICIANDO PROVISIONAMENTO DO COMPUTADOR" "INFO"
        Write-Log "======================================================" "INFO"

        # -------------------------------------------------------------
        # ETAPA 1 - Chocolatey
        # -------------------------------------------------------------

        Test-Chocolatey

        # -------------------------------------------------------------
        # ETAPA 2 - Programas basicos
        # -------------------------------------------------------------

        Write-Log "Iniciando instalacao dos programas basicos." "INFO"

        $TimingCache = Get-TimingCache

        if ($TimingCache.Count -gt 0) {

            $Fila = Sort-FilaPorTempoReal `
                -Fila $Config.ChocoPackages `
                -Cache $TimingCache

            Write-Log "Fila ordenada pelo historico de tempo de instalacao." "SUCCESS"
        }
        else {

            Write-Log "Sem historico. Consultando tamanhos dos pacotes." "WARNING"

            $Fila = Sort-FilaPorTamanho -Fila $Config.ChocoPackages
        }

        foreach ($item in $Fila) {

            $cronometro = [Diagnostics.Stopwatch]::StartNew()

            $tempoConhecido = if ($TimingCache.ContainsKey($item.Nome)) {
                "Historico: $($TimingCache[$item.Nome]) segundos"
            }
            else {
                "Sem historico"
            }

            Write-Log "Preparando $($item.Nome). $tempoConhecido" "INFO"

            $sucesso = Install-ChocoPackage `
                -PackageId $item.Pacote `
                -FriendlyName $item.Nome `
                -ArgsExtras $item.ArgsExtras

            $cronometro.Stop()

            $duracao = [math]::Round($cronometro.Elapsed.TotalSeconds, 1)

            $status = if ($sucesso) { "OK" } else { "FALHA" }

            $resultados.Add([pscustomobject]@{
                Nome = $item.Nome
                Status = $status
                Duracao = $duracao
            })

            if ($sucesso) {
                $TimingCache[$item.Nome] = $duracao
            }
        }

        Save-TimingCache -Cache $TimingCache

        # -------------------------------------------------------------
        # ETAPA 3 - Agentes corporativos
        # -------------------------------------------------------------

        Write-Log "Iniciando instalacao dos agentes corporativos." "INFO"

        $agentes = @(
            @{
                Nome = "Kaspersky - Agente de Rede"
                Path = $Config.KasperskyAgentPath
                Args = "/s"
            }
            @{
                Nome = "Kaspersky - Protecao do Computador"
                Path = $Config.KasperskyEndpointPath
                Args = "/s"
            }
            @{
                Nome = "MeshAgent"
                Path = $Config.MeshAgentPath
                Args = "-install"
            }
        )

        foreach ($agente in $agentes) {

            $sucesso = Invoke-SilentInstall `
                -FriendlyName $agente.Nome `
                -Path $agente.Path `
                -ArgumentList $agente.Args

            $resultados.Add([pscustomobject]@{
                Nome = $agente.Nome
                Status = if ($sucesso) { "OK" } else { "FALHA/IGNORADO" }
                Duracao = 0
            })
        }

        # GLPI Agent
        $sucesso = Install-GlpiAgent

        $resultados.Add([pscustomobject]@{
            Nome = "GLPI Agent"
            Status = if ($sucesso) { "OK" } else { "FALHA/IGNORADO" }
            Duracao = 0
        })

        # -------------------------------------------------------------
        # ETAPA 4 - Aplicativos Microsoft
        # -------------------------------------------------------------

        Write-Log "Iniciando instalacao dos aplicativos Microsoft." "INFO"

        # Microsoft 365 / Office
        $sucesso = Invoke-SilentInstall `
            -FriendlyName "Microsoft Office 365" `
            -Path $Config.Microsoft365ScriptPath

        $resultados.Add([pscustomobject]@{
            Nome = "Microsoft Office 365"
            Status = if ($sucesso) { "OK" } else { "FALHA/IGNORADO" }
            Duracao = 0
        })

        # Microsoft Teams
        $sucesso = Install-MicrosoftTeams

        $resultados.Add([pscustomobject]@{
            Nome = "Microsoft Teams"
            Status = if ($sucesso) { "OK" } else { "FALHA/IGNORADO" }
            Duracao = 0
        })

        # -------------------------------------------------------------
        # ETAPA 5 - Limpeza
        # -------------------------------------------------------------

        Write-Log "Iniciando limpeza de processos residuais." "INFO"

        Close-LeftoverInstallerWindows `
            -ProcessNames $Config.ProcessosParaFechar

        # -------------------------------------------------------------
        # ETAPA 6 - Relatorio final
        # -------------------------------------------------------------

        $tempoTotal = [math]::Round(
            ((Get-Date) - $inicio).TotalSeconds, 1
        )

        $ok = @($resultados | Where-Object Status -eq "OK").Count

        $falha = @(
            $resultados |
                Where-Object Status -ne "OK"
        ).Count

        Write-Log "======================================================" "INFO"
        Write-Log " RESULTADO DO PROVISIONAMENTO" "INFO"
        Write-Log "======================================================" "INFO"

        foreach ($item in $resultados) {

            $nivel = if ($item.Status -eq "OK") {
                "SUCCESS"
            }
            else {
                "WARNING"
            }

            Write-Log "$($item.Nome) | $($item.Status) | $($item.Duracao)s" $nivel
        }

        Write-Log "------------------------------------------------------" "INFO"
        Write-Log "Instalacoes com sucesso: $ok" "SUCCESS"
        Write-Log "Instalacoes com falha/ignoradas: $falha" "WARNING"
        Write-Log "Tempo total: $tempoTotal segundos" "INFO"
        Write-Log "Log: $($Config.LogPath)" "INFO"
        Write-Log "Cache: $($Config.TimingCachePath)" "INFO"
        Write-Log "======================================================" "INFO"

        Write-Log "PROVISIONAMENTO FINALIZADO." "SUCCESS"
    }
    catch {

        Write-Host "ERRO CRITICO: $($_.Exception.Message)" -ForegroundColor Red

        throw
    }
}


# =====================================================================
# 4. EXECUCAO
# =====================================================================

Main


# Executa o script chamando a função Main
Main
