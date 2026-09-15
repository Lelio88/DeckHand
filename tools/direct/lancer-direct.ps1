<#
.SYNOPSIS
Démarre Streamlabs et le bot Twitch ensemble ; fermer Streamlabs arrête le bot.

.DESCRIPTION
Le calque de direct n'a besoin de rien sur ce poste : c'est une page servie par
GitHub Pages, que la source navigateur lit seule. Le bot, lui, doit tourner — et
un bot qu'on oublie de lancer donne un chat qui ne répond pas, sans que rien ne
le signale. Ce lanceur lie sa vie à celle de Streamlabs.

Choix non évidents :

- **Streamlabs est retrouvé par le registre**, pas par un chemin écrit en dur.
  Relevé sur une installation 1.20.9 : l'entrée s'appelle « Streamlabs
  Desktop », l'exécutable garde l'ancien nom (`Streamlabs OBS\Streamlabs
  OBS.exe`) et `InstallLocation` est vide — seul `DisplayIcon` porte le chemin.
- **Streamlabs est surveillé par le chemin de son exécutable**, pas par le
  processus que ce script démarre : une application déjà ouverte n'est pas
  relancée, et le processus démarré peut rendre la main à une instance existante.
- **Une absence ne compte qu'à la seconde vérification.** Précaution, non
  mesurée : un bref trou entre deux processus, pendant un redémarrage de
  l'application, ne doit pas couper le bot en plein direct.
- **Le bot tourne dans la fenêtre du lanceur** : ses journaux restent lisibles,
  et une relance n'ouvre pas une fenêtre de plus.
- **Les relances sont rares et bornées.** Le bot se reconnecte seul après une
  coupure réseau et ne s'arrête que sur une autre erreur. Or le crédit qu'il
  publie dans le chat n'est retenu qu'en mémoire : chaque relance le republie.
  Trois relances espacées d'une minute, puis le lanceur s'arrête et le dit.

Invariants :

- Aucun secret n'est lu ici. La vérification passe par `app.config`, le code
  même du bot, qui ne nomme que les clés manquantes.
- Magic seul : le bot part avec son jeu par défaut, celui que le calque suppose
  quand son adresse n'en précise aucun.
- Chargé par « . », le script ne définit que ses fonctions : la surveillance
  s'éprouve alors avec des processus inoffensifs, sans toucher à Twitch.

.PARAMETER Verifier
Contrôle les prérequis sans rien lancer.

.PARAMETER Raccourci
Crée le raccourci « Direct DeckHand » sur le bureau.

.PARAMETER StreamlabsPath
Chemin de l'exécutable de Streamlabs, quand le registre ne le donne pas.

.EXAMPLE
pwsh -File tools/direct/lancer-direct.ps1 -Verifier
#>
#Requires -Version 7

[CmdletBinding()]
param(
    [switch] $Verifier,
    [switch] $Raccourci,
    [string] $StreamlabsPath
)

$RACINE = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$API = Join-Path $RACINE 'api'
$PYTHON = Join-Path $API '.venv\Scripts\python.exe'

# Choix, non mesures : de quoi laisser démarrer une application lente, et
# surveiller sans charger le poste qui diffuse.
$ATTENTE_DEMARRAGE_S = 120
$INTERVALLE_S = 5
$RELANCES_MAX = 3
$DELAI_RELANCE_S = 60

function Find-Streamlabs {
    $cles = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($entree in Get-ItemProperty -Path $cles -ErrorAction SilentlyContinue) {
        if ("$($entree.DisplayName)" -notlike 'Streamlabs*' -or -not $entree.DisplayIcon) { continue }
        # « <exécutable>,<rang de l'icône> », parfois entre guillemets.
        $chemin = ($entree.DisplayIcon -replace ',\s*-?\d+$', '').Trim('"')
        if (Test-Path -LiteralPath $chemin -PathType Leaf) { return $chemin }
    }
    return $null
}

function Test-ProcessusOuvert([string] $Chemin) {
    $nom = [IO.Path]::GetFileNameWithoutExtension($Chemin)
    $ouverts = Get-Process -Name $nom -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $Chemin }
    return [bool] $ouverts
}

function Get-Problemes([string] $Streamlabs) {
    $problemes = [System.Collections.Generic.List[string]]::new()
    if (-not $Streamlabs) {
        $problemes.Add('Streamlabs introuvable : passer -StreamlabsPath "<chemin de l''exécutable>".')
    }
    if (-not (Test-Path -LiteralPath $PYTHON -PathType Leaf)) {
        $problemes.Add('Environnement Python absent. Depuis api\ : python -m venv .venv, puis .venv\Scripts\python -m pip install -e .')
        return $problemes
    }

    # Le code même du bot : versions, dépendances, clés du coffre.
    $controle = @'
import sys
if sys.version_info < (3, 11):
    sys.exit('Python 3.11 ou plus requis, trouvé ' + sys.version.split()[0])
try:
    import app.twitch.bot
    from app.config import ConfigError, SupabaseConfig, TwitchConfig
except ImportError as error:
    sys.exit('dépendance manquante (' + str(error) + ') : .venv\\Scripts\\python -m pip install -e .')
try:
    SupabaseConfig.load()
    TwitchConfig.load()
except ConfigError as error:
    sys.exit(str(error))
'@
    # Une sortie Python redirigée part en cp1252 sous Windows : les accents et le
    # tiret des messages d'`app.config` arriveraient défigurés.
    $encodage = [Console]::OutputEncoding
    $env:PYTHONIOENCODING = 'utf-8'
    Push-Location $API
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $sortie = & $PYTHON -c $controle 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        [Console]::OutputEncoding = $encodage
        Remove-Item Env:PYTHONIOENCODING
    }
    if ($code -ne 0) { $problemes.Add(($sortie -join ' ')) }
    return $problemes
}

function Start-Bot {
    $options = @{
        FilePath         = $PYTHON
        ArgumentList     = @('-m', 'app.twitch')
        WorkingDirectory = $API
        NoNewWindow      = $true
        PassThru         = $true
    }
    $processus = Start-Process @options
    # Sans poignée retenue dès le démarrage, .NET ne sait plus rendre le code de sortie.
    $null = $processus.Handle
    return $processus
}

function Invoke-Surveillance {
    <#
    Tient le bot en vie tant que l'application tourne. Rend $true quand
    l'application s'est fermée, $false quand le bot est tombé trop souvent. Le
    bot est arrêté dans les deux cas, y compris sur Ctrl+C.
    #>
    param(
        [Parameter(Mandatory)] [string] $Application,
        [Parameter(Mandatory)] [scriptblock] $LancerBot,
        [int] $IntervalleS = $INTERVALLE_S,
        [int] $RelancesMax = $RELANCES_MAX,
        [int] $DelaiRelanceS = $DELAI_RELANCE_S
    )
    $bot = & $LancerBot
    $relances = 0
    $absences = 0
    try {
        while ($true) {
            Start-Sleep -Seconds $IntervalleS
            $absences = if (Test-ProcessusOuvert $Application) { 0 } else { $absences + 1 }
            if ($absences -ge 2) {
                Write-Host 'Streamlabs est fermé : arrêt du bot.'
                return $true
            }
            if (-not $bot.HasExited) { continue }
            if ($relances -ge $RelancesMax) {
                Write-Host "Le bot est tombé $($relances + 1) fois : le chat ne répond plus." -ForegroundColor Red
                return $false
            }
            $relances++
            Write-Host "Le bot s'est arrêté (code $($bot.ExitCode)) : relance $relances/$RelancesMax dans $DelaiRelanceS s." -ForegroundColor Yellow
            Start-Sleep -Seconds $DelaiRelanceS
            $bot = & $LancerBot
        }
    } finally {
        if ($bot -and -not $bot.HasExited) {
            Stop-Process -Id $bot.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-Raccourci([string] $Streamlabs) {
    $lien = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Direct DeckHand.lnk'
    $raccourci = (New-Object -ComObject WScript.Shell).CreateShortcut($lien)
    $raccourci.TargetPath = [Environment]::ProcessPath
    $raccourci.Arguments = "-NoProfile -File `"$PSCommandPath`""
    $raccourci.WorkingDirectory = $RACINE
    if ($Streamlabs) { $raccourci.IconLocation = "$Streamlabs,0" }
    $raccourci.Save()
    return $lien
}

function Show-Problemes([string[]] $Problemes) {
    foreach ($probleme in $Problemes) { Write-Host "- $probleme" -ForegroundColor Red }
}

function Wait-Lecture {
    # Lancée par le raccourci, la fenêtre se ferme avec le script : sans pause,
    # le message disparaîtrait avant d'avoir été lu.
    if (-not [Console]::IsInputRedirected) { $null = Read-Host 'Entrée pour fermer' }
}

if ($MyInvocation.InvocationName -eq '.') { return }

$streamlabs = if ($StreamlabsPath) { $StreamlabsPath } else { Find-Streamlabs }
if ($streamlabs -and -not (Test-Path -LiteralPath $streamlabs -PathType Leaf)) { $streamlabs = $null }

if ($Raccourci) {
    Write-Host "Raccourci créé : $(New-Raccourci $streamlabs)"
    exit 0
}

$problemes = @(Get-Problemes $streamlabs)
if ($problemes.Count -gt 0) {
    Show-Problemes $problemes
    if (-not $Verifier) { Wait-Lecture }
    exit 1
}
if ($Verifier) {
    Write-Host "Prêt : $streamlabs, Python et coffre." -ForegroundColor Green
    exit 0
}

if (-not (Test-ProcessusOuvert $streamlabs)) { Start-Process -FilePath $streamlabs }
$limite = (Get-Date).AddSeconds($ATTENTE_DEMARRAGE_S)
while (-not (Test-ProcessusOuvert $streamlabs)) {
    if ((Get-Date) -gt $limite) {
        Write-Host "Streamlabs n'a pas démarré en $ATTENTE_DEMARRAGE_S s." -ForegroundColor Red
        Wait-Lecture
        exit 1
    }
    Start-Sleep -Seconds 1
}

Write-Host 'Bot Twitch lancé. Fermer Streamlabs l''arrête — laisser cette fenêtre ouverte pendant le direct.'
if (-not (Invoke-Surveillance -Application $streamlabs -LancerBot { Start-Bot })) {
    Wait-Lecture
    exit 1
}
