param([string]$Fg,[string]$Bg,[switch]$SelfTest)
# WCAG 2.x contrast-ratio calculator. 6-digit hex only (e.g. #A47864).
# Dot-source for its functions, or run:
#   contrast-check.ps1 -Fg '#FFFFFF' -Bg '#A47864'   (exit 0 if AA passes, 1 if not)
#   contrast-check.ps1 -SelfTest                       (verify the math vs known values)
function Get-RelLuminance([string]$hex){
    $h = $hex.TrimStart('#')
    if ($h.Length -ne 6) { throw "Expected 6-digit hex, got '$hex'" }
    $vals = @()
    foreach ($i in 0,2,4) {
        $c = [Convert]::ToInt32($h.Substring($i,2),16) / 255.0
        if ($c -le 0.03928) { $vals += ($c / 12.92) }
        else { $vals += [Math]::Pow((($c + 0.055) / 1.055), 2.4) }
    }
    return (0.2126 * $vals[0]) + (0.7152 * $vals[1]) + (0.0722 * $vals[2])
}
function Get-ContrastRatio([string]$fg,[string]$bg){
    $a = Get-RelLuminance $fg; $b = Get-RelLuminance $bg
    $hi = [Math]::Max($a,$b); $lo = [Math]::Min($a,$b)
    return [Math]::Round((($hi+0.05)/($lo+0.05)),2)
}
function Test-ContrastAA([string]$fg,[string]$bg,[switch]$Large){
    $r = Get-ContrastRatio $fg $bg
    if ($Large) { $needAA = 3.0; $needAAA = 4.5 } else { $needAA = 4.5; $needAAA = 7.0 }
    [pscustomobject]@{ fg=$fg; bg=$bg; ratio=$r; AA=($r -ge $needAA); AAA=($r -ge $needAAA) }
}
if ($SelfTest) {
    "WCAG self-test (math must match known values):"
    "  black/white = {0} (expect 21)"     -f (Get-ContrastRatio '#000000' '#FFFFFF')
    "  white/white = {0} (expect 1)"      -f (Get-ContrastRatio '#FFFFFF' '#FFFFFF')
    "  #777/white  = {0} (expect ~4.48)"  -f (Get-ContrastRatio '#777777' '#FFFFFF')
    return
}
if ($Fg -and $Bg) {
    $t = Test-ContrastAA $Fg $Bg
    "{0} on {1}: {2}:1   AA(normal)={3}  AAA={4}" -f $t.fg,$t.bg,$t.ratio,$t.AA,$t.AAA
    if ($t.AA) { exit 0 } else { exit 1 }
}
