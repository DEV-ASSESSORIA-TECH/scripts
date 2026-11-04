# Primitivas de interface do terminal: telas, secoes, marcadores e teclas.
# Largura fixa para caber em 80 colunas. ASCII apenas (Windows PowerShell 5.1).

$UiWidth = 62

function Clear-UiScreen {
    if ([Console]::IsOutputRedirected) { return }
    try { Clear-Host } catch { }
}

# Write-Host com cor opcional (Write-Host nao aceita cor vazia).
function Write-UiText([string]$Text, [string]$Color, [switch]$NoNewline) {
    $params = @{ Object = $Text; NoNewline = [bool]$NoNewline }
    if ($Color) { $params.ForegroundColor = $Color }
    Write-Host @params
}

function Write-UiRule([string]$Char = '-') { Write-Host (' ' + ($Char * $UiWidth)) }

function Write-UiBanner([string]$Right) {
    Write-UiRule '='
    $left = 'GRAFANA ALLOY'
    $gap = [Math]::Max(1, $UiWidth - 2 - $left.Length - $Right.Length)
    Write-UiText "  $left" 'White' -NoNewline
    Write-Host ((' ' * $gap) + $Right)
    Write-UiRule '='
}

# == TITULO =========================================
function Write-UiSection([string]$Title) {
    $text = " $Title "
    Write-Host ''
    Write-UiText (' ==' + $text + ('=' * [Math]::Max(0, $UiWidth - 2 - $text.Length))) 'White'
}

function Write-UiBadge([string]$Kind) {
    switch ($Kind) {
        'ok'   { Write-UiText '[ OK ]' 'Green' -NoNewline }
        'warn' { Write-UiText '[ !! ]' 'Yellow' -NoNewline }
        'err'  { Write-UiText '[ !! ]' 'Red' -NoNewline }
        'off'  { Write-UiText '[ -- ]' 'DarkGray' -NoNewline }
        default { Write-Host '      ' -NoNewline }
    }
}

# Linha alinhada de estado: rotulo, marcador e texto.
function Write-UiRow([string]$Label, [string]$Kind, [string]$Text, [string]$Color) {
    Write-Host ('  ' + $Label.PadRight(12) + ' ') -NoNewline
    Write-UiBadge $Kind
    Write-UiText ('  ' + $Text) $Color
}

# Linha do menu em duas colunas; a cor nao conta na largura.
function Write-UiColumns([string]$Left, [string]$LeftColor, [string]$Right, [string]$RightColor) {
    Write-Host '  ' -NoNewline
    Write-UiText $Left.PadRight(30) $LeftColor -NoNewline
    Write-UiText $Right $RightColor
}

# Uma tecla, sem Enter. Enter -> ''; Esc e setas -> 'ESC'.
# Hosts sem ReadKey (ex.: ISE) caem para Read-Host.
function Read-UiKey([string]$Prompt) {
    Write-Host "  ${Prompt}: " -NoNewline
    try {
        $key = [Console]::ReadKey($true)
    } catch {
        return (Read-Host).Trim()
    }
    if ($key.Key -eq 'Enter') { Write-Host ''; return '' }
    if ($key.Key -eq 'Escape' -or [int]$key.KeyChar -eq 0) { Write-Host ''; return 'ESC' }
    Write-Host $key.KeyChar
    return [string]$key.KeyChar
}

function Wait-UiKey {
    Write-Host ''
    Write-UiText '  Tecle algo para voltar ao menu...' 'DarkGray' -NoNewline
    try { $null = [Console]::ReadKey($true) } catch { $null = Read-Host }
    Write-Host ''
}
