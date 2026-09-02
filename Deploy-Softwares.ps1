```powershell
#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Instalação e atualização automatizada de softwares via Chocolatey.

.DESCRIPTION
    - Instala o Chocolatey caso não esteja presente.
    - Instala ou atualiza os softwares definidos na variável $Softwares.
    - Todas as instalações são executadas de forma silenciosa.
    - Não requer interação humana.
    - Registra sucesso, falha e motivo da falha.
    - Utiliza "choco upgrade", que instala o pacote caso não exista
      e atualiza caso já esteja instalado.
#>

$ErrorActionPreference = "Continue"

# =========================================================================
# CONFIGURAÇÕES
# =========================================================================

$LogPath = "C:\Temp\Deploy_Automacao.log"

# =========================================================================
# SOFTWARES
# =========================================================================
# Nome       = Nome exibido no relatório
# Pacote     = Nome do pacote no Chocolatey
# Parametros = Parâmetros opcionais específicos do pacote
# =========================================================================

$Softwares = @(
    @{
        Nome       = "7-Zip (x64 edition)"
        Pacote     = "7zip"
        Parametros = ""
    },
    @{
        Nome       = "GLPI Agent"
        Pacote     = "glpi-agent"
        Parametros = ""
    },
    @{
        Nome       = "Google Chrome"
        Pacote     = "googlechrome"
        Parametros = ""
    },
    @{
        Nome       = "Kaspersky Endpoint Security for Windows"
        Pacote     = "kaspersky-endpoint-security"
        Parametros = ""
    },
    @{
        Nome       = "Kaspersky Security Center Network Agent"
        Pacote     = "kaspersky-agent"
        Parametros = ""
    },
    @{
        Nome       = "Mesh Agent"
        Pacote     = "meshcentral-agent"
        Parametros = ""
    },
    @{
        Nome       = "Microsoft 365 Apps para grandes empresas - pt-BR"
        Pacote     = "office365proplus"
        Parametros = '--params "/Language:pt-br"'
    },
    @{
        Nome       = "Microsoft Edge"
        Pacote     = "microsoft-edge"
        Parametros = ""
    },
    @{
        Nome       = "Microsoft OneDrive"
        Pacote     = "onedrive"
        Parametros = ""
    },
    @{
        Nome       = "Microsoft Teams"
        Pacote     = "microsoft-teams-new-bootstrapper"
        Parametros = ""
    },
    @{
        Nome       = "Microsoft Visual C++"
        Pacote     = "vcredist-all"
        Parametros = ""
    },
    @{
        Nome       = "Microsoft Windows Application"
        Pacote     = "dotnet-desktopruntime"
        Parametros = ""
    },
    @{
        Nome       = "Mozilla Firefox"
        Pacote     = "firefox"
        Parametros = ""
    },
    @{
        Nome       = "Mozilla Maintenance Service"
        Pacote     = "firefox"
        Parametros = ""
    },
    @{
        Nome       = "PDF24 Creator"
        Pacote     = "pdf24"
        Parametros = ""
    }
)

# =========================================================================
# PREPARAÇÃO DO AMBIENTE
# =========================================================================

if (-not (Test-Path "C:\Temp")) {
    New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
}

Start-Transcript -Path $LogPath -Append -Force | Out-Null

$Inicio = Get-Date

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "        DEPLOY AUTOMATIZADO VIA CHOCOLATEY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Início: $Inicio" -ForegroundColor Gray
Write-Host "Quantidade de softwares: $($Softwares.Count)" -ForegroundColor Gray
Write-Host ""

# =========================================================================
# VERIFICAÇÃO / INSTALAÇÃO DO CHOCOLATEY
# =========================================================================

Write-Host "[1/2] Verificando Chocolatey..." -ForegroundColor Yellow

if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {

    Write-Host "Chocolatey não encontrado. Instalando automaticamente..." -ForegroundColor Yellow

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        Set-ExecutionPolicy Bypass -Scope Process -Force

        $InstallScript = (New-Object Net.WebClient).DownloadString(
            "https://community.chocolatey.org/install.ps1"
        )

        Invoke-Expression $InstallScript

        $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"

        if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
            throw "Chocolatey foi instalado, mas o executável não foi encontrado no PATH."
        }

        Write-Host "Chocolatey instalado com sucesso." -ForegroundColor Green
    }
    catch {
        Write-Host "Não foi possível instalar o Chocolatey." -ForegroundColor Red
        Write-Host "Motivo: $($_.Exception.Message)" -ForegroundColor Red

        Stop-Transcript | Out-Null
        exit 1
    }
}
else {
    Write-Host "Chocolatey já está instalado." -ForegroundColor Green
}

# Configurações para execução automática
choco config set --name=allowGlobalConfirmation --value=true | Out-Null
choco config set --name=autoUninstaller --value=true | Out-Null

Write-Host ""

# =========================================================================
# INSTALAÇÃO / ATUALIZAÇÃO DOS SOFTWARES
# =========================================================================

Write-Host "[2/2] Instalando/atualizando softwares..." -ForegroundColor Yellow
Write-Host ""

$Relatorio = foreach ($Software in $Softwares) {

    Write-Host ("{0,-55}" -f $Software.Nome) -NoNewline

    $Argumentos = @(
        "upgrade"
        $Software.Pacote
        "-y"
        "--no-progress"
        "--accept-license"
    )

    if (-not [string]::IsNullOrWhiteSpace($Software.Parametros)) {
        $Argumentos += $Software.Parametros
    }

    try {

        $Saida = & choco.exe @Argumentos 2>&1
        $CodigoSaida = $LASTEXITCODE

        if ($CodigoSaida -in @(0, 1641, 3010)) {

            Write-Host "[OK]" -ForegroundColor Green

            [PSCustomObject]@{
                Software = $Software.Nome
                Pacote   = $Software.Pacote
                Status   = "INSTALADO/ATUALIZADO"
                Detalhes = "Instalação ou atualização concluída com sucesso."
            }
        }
        else {

            $DetalhesErro = ($Saida | Select-Object -Last 8) -join " "

            Write-Host "[FALHA]" -ForegroundColor Red

            [PSCustomObject]@{
                Software = $Software.Nome
                Pacote   = $Software.Pacote
                Status   = "NÃO INSTALADO"
                Detalhes = "Código Chocolatey: $CodigoSaida. $DetalhesErro"
            }
        }
    }
    catch {

        Write-Host "[ERRO]" -ForegroundColor Red

        [PSCustomObject]@{
            Software = $Software.Nome
            Pacote   = $Software.Pacote
            Status   = "NÃO INSTALADO"
            Detalhes = $_.Exception.Message
        }
    }
}

# =========================================================================
# RESUMO
# =========================================================================

$Fim = Get-Date
$Tempo = ($Fim - $Inicio).TotalSeconds

$Sucesso = @(
    $Relatorio | Where-Object {
        $_.Status -eq "INSTALADO/ATUALIZADO"
    }
).Count

$Falhas = @(
    $Relatorio | Where-Object {
        $_.Status -eq "NÃO INSTALADO"
    }
).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                    RESULTADO FINAL" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$Relatorio | Format-Table -AutoSize `
    Software,
    Pacote,
    Status,
    Detalhes

Write-Host ""
Write-Host "Total de softwares : $($Softwares.Count)" -ForegroundColor Cyan
Write-Host "Sucesso             : $Sucesso" -ForegroundColor Green
Write-Host "Falhas              : $Falhas" -ForegroundColor $(if ($Falhas -gt 0) { "Red" } else { "Green" })
Write-Host "Tempo de execução   : $([math]::Round($Tempo, 2)) segundos" -ForegroundColor Cyan
Write-Host "Log                 : $LogPath" -ForegroundColor Gray

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Stop-Transcript | Out-Null
```
