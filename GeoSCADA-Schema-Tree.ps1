# GeoSCADA-Schema-Tree.ps1
# Copyright (C) 2026  Adam Woodland
#
# This program is free software: you can redistribute it and/or modify it under the terms of the
# GNU General Public License as published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without
# even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with this program.
# If not, see <https://www.gnu.org/licenses/>.

<#
.SYNOPSIS
    Parses the Geo SCADA XML schema (served at https://<host>/schema/<ClassName>)
    from a given root class downwards and generates an interactive HTML file
    showing the class / sub-class tree with a details panel per class.

.DESCRIPTION
    Each schema page for a class exposes <Subclass> elements naming its child
    classes; walking those recursively (starting at -RootClass, default
    CDBObject) yields the full inheritance tree.

    Each page also defines the members introduced by that class:
      * ConfigField   - configuration properties
      * DataField     - data properties
      * Aggregate     - aggregate child-tables
      * Method        - methods (with arguments)
      * AlarmCondition- alarm conditions (with sub-conditions)
    plus a friendly display name (the Class 'name' attribute, present on
    creatable classes) and a <Base> pointer to the parent class.

    The tree is rendered server-side; every class's own members are embedded
    as JSON and shown in a slide-out panel when a class is clicked. Searching
    matches the class name, friendly name and the class's own member content.

    Members are shown "as defined on the class" (not merged with inherited
    ancestors) - i.e. exactly what that schema page returns.

.PARAMETER RootClass
    The class to start from. Defaults to CDBObject (the root of the hierarchy).

.PARAMETER BaseUrl
    The schema endpoint base. Defaults to https://localhost/schema/

.PARAMETER OutputPath
    Where to write the HTML. Defaults to .\SchemaTree.html next to this script.

.PARAMETER AcceptDisclaimer
    Accept the usage disclaimer non-interactively (required in non-interactive
    sessions). Omit to be prompted to accept before the script runs.

.EXAMPLE
    .\GeoSCADA-Schema-Tree.ps1
    .\GeoSCADA-Schema-Tree.ps1 -RootClass CGroup -OutputPath C:\temp\groups.html
    .\GeoSCADA-Schema-Tree.ps1 -AcceptDisclaimer

.NOTES
    DISCLAIMER
    This script is provided "AS IS", without warranty of any kind, express or implied, including but
    not limited to the warranties of merchantability, fitness for a particular purpose and non-
    infringement. In no event shall the author be liable for any claim, damages or other liability
    arising from, out of or in connection with the script or its use. It connects to the Geo SCADA
    schema web endpoint to read schema metadata and writes an HTML file; to reach a self-signed
    localhost endpoint it disables TLS certificate validation for the session. It is NOT certified
    for production SCADA environments. Do NOT run it against a production or safety-critical system
    without first reviewing the code and testing it on a representative non-production system. You
    run it at your own risk and are responsible for compliance with your own change-control and
    security policies.
#>
[CmdletBinding()]
param(
    [string]$RootClass  = 'CDBObject',
    [string]$BaseUrl    = 'https://localhost/schema/',
    [string]$OutputPath,
    [switch]$AcceptDisclaimer
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web

# Resolve the output path here (not in the param default) so it works even when
# $PSScriptRoot is empty - e.g. running a selection (F8) or dot-sourcing rather
# than invoking the whole file as a script.
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
                 elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
                 else { (Get-Location).Path }
    $OutputPath = Join-Path $scriptDir 'SchemaTree.html'
}

# --- Usage disclaimer -----------------------------------------------------
function Confirm-Disclaimer {
    param([switch]$Accepted)

    $disclaimer = @'
------------------------------------------------------------------------------
 GeoSCADA-Schema-Tree.ps1  Copyright (C) 2026  Adam Woodland
 Licensed under the GNU GPL v3. This is free software, and you are welcome to
 redistribute it under those conditions; it comes with ABSOLUTELY NO WARRANTY.

 DISCLAIMER
 This script is provided "AS IS", WITHOUT WARRANTY OF ANY KIND, express or
 implied. The author accepts no liability for any damages arising from its use.
 It connects to the Geo SCADA schema web endpoint to read schema metadata and
 writes an HTML file; to reach a self-signed localhost endpoint it disables TLS
 certificate validation for the session. It is NOT certified for production
 SCADA systems. Do NOT run it against a production or safety-critical system
 without first reviewing the code and testing on a representative non-
 production system. You run it at your own risk and remain responsible for your
 own change-control and security policies.
------------------------------------------------------------------------------
'@

    if ($Accepted) {
        Write-Verbose 'Disclaimer accepted via -AcceptDisclaimer.'
        return $true
    }

    $canPrompt = [Environment]::UserInteractive
    try { if ([Console]::IsInputRedirected) { $canPrompt = $false } } catch { }

    if (-not $canPrompt) {
        Write-Host $disclaimer -ForegroundColor Yellow
        throw 'Disclaimer not accepted (non-interactive session). Re-run with -AcceptDisclaimer to confirm acceptance.'
    }

    Write-Host ''
    Write-Host $disclaimer -ForegroundColor Yellow
    $yes = New-Object System.Management.Automation.Host.ChoiceDescription '&Yes', 'I accept the terms and have tested appropriately.'
    $no  = New-Object System.Management.Automation.Host.ChoiceDescription '&No',  'Do not run.'
    $choices = [System.Management.Automation.Host.ChoiceDescription[]]@($yes, $no)
    try {
        $decision = $Host.UI.PromptForChoice('Disclaimer', 'Do you accept these terms and confirm you have tested appropriately?', $choices, 1)
    } catch {
        throw 'Disclaimer not accepted (host could not prompt). Re-run with -AcceptDisclaimer to confirm acceptance.'
    }
    if ($decision -ne 0) {
        Write-Warning 'Disclaimer not accepted. Exiting without running.'
        return $false
    }
    return $true
}

# --- Accept the self-signed localhost certificate -------------------------
try {
    Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class GeoScadaTrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@ -ErrorAction SilentlyContinue
} catch { }
[System.Net.ServicePointManager]::CertificatePolicy = New-Object GeoScadaTrustAll
[System.Net.ServicePointManager]::SecurityProtocol   =
    [System.Net.SecurityProtocolType]::Tls12 -bor `
    [System.Net.SecurityProtocolType]::Tls11 -bor `
    [System.Net.SecurityProtocolType]::Tls

# --- State ----------------------------------------------------------------
$BaseUrl        = $BaseUrl.TrimEnd('/') + '/'
$script:XmlCache = @{}   # className -> [xml]
$script:Classes  = [ordered]@{}   # className -> own member data (for JSON)
$script:Fetched  = 0

function HE([string]$s) { [System.Web.HttpUtility]::HtmlEncode($s) }

function Get-ClassXml {
    param([string]$ClassName)
    if ($script:XmlCache.ContainsKey($ClassName)) { return $script:XmlCache[$ClassName] }
    $url = $BaseUrl + $ClassName
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
        $xml  = [xml]$resp.Content
    } catch {
        Write-Warning "Failed to fetch '$ClassName' ($url): $($_.Exception.Message)"
        $xml = $null
    }
    $script:XmlCache[$ClassName] = $xml
    $script:Fetched++
    Write-Progress -Activity 'Parsing Geo SCADA schema' -Status "Fetched $script:Fetched classes (current: $ClassName)"
    return $xml
}

# Drop empty / false / empty-array entries so the JSON stays small.
function New-Compact {
    param([System.Collections.Specialized.OrderedDictionary]$H)
    $o = [ordered]@{}
    foreach ($k in @($H.Keys)) {
        $v = $H[$k]
        if ($null -eq $v) { continue }
        if ($v -is [string] -and $v -eq '') { continue }
        if ($v -is [bool]   -and -not $v)   { continue }
        if ($v -is [array]  -and $v.Count -eq 0) { continue }
        $o[$k] = $v
    }
    $o
}

function Convert-Field {
    param($Node)
    $enums = @()
    foreach ($e in $Node.SelectNodes('Enum')) {
        $enums += (New-Compact ([ordered]@{ v = $e.GetAttribute('value'); t = $e.InnerText }))
    }
    New-Compact ([ordered]@{
        n   = $Node.GetAttribute('name')
        dn  = $Node.GetAttribute('displayname')
        d   = $Node.GetAttribute('description')
        t   = $Node.GetAttribute('typeDesc')
        ref = $Node.GetAttribute('refTable')
        ro  = [bool]$Node.GetAttribute('readOnly')
        sl  = $Node.GetAttribute('strLen')
        wp  = $Node.GetAttribute('writePrivilege')
        rp  = $Node.GetAttribute('readPrivilege')
        op  = $Node.GetAttribute('opcProp')
        en  = @($enums)
    })
}

function Convert-Method {
    param($Node)
    $margs = @()
    foreach ($a in $Node.SelectNodes('Argument')) {
        $margs += (New-Compact ([ordered]@{
            n   = $a.InnerText
            t   = $a.GetAttribute('typeDesc')
            d   = $a.GetAttribute('description')
            ret = [bool]$a.GetAttribute('retVal')
        }))
    }
    New-Compact ([ordered]@{
        n    = $Node.GetAttribute('name')
        dn   = $Node.GetAttribute('displayName')
        d    = $Node.GetAttribute('description')
        pv   = $Node.GetAttribute('privilege')
        args = @($margs)
    })
}

function Convert-Aggregate {
    param($Node)
    $tables = @()
    foreach ($t in $Node.SelectNodes('Table')) {
        $tables += (New-Compact ([ordered]@{ name = $t.GetAttribute('name'); t = $t.InnerText }))
    }
    New-Compact ([ordered]@{
        n      = $Node.GetAttribute('name')
        op     = $Node.GetAttribute('opcProp')
        fx     = [bool]$Node.GetAttribute('fixed')
        tables = @($tables)
    })
}

function Convert-Alarm {
    param($Node)
    $subs = @()
    foreach ($s in $Node.SelectNodes('SubCondition')) { $subs += $s.InnerText }
    New-Compact ([ordered]@{
        n    = $Node.GetAttribute('name')
        cat  = $Node.GetAttribute('category')
        ct   = $Node.GetAttribute('categorytable')
        subs = @($subs)
    })
}

# Parse a class's own members into the $script:Classes map. Returns the
# list of subclass names for tree recursion.
function Register-Class {
    param([string]$ClassName, $Xml)
    $c = $Xml.Class

    $config = @(); foreach ($f in $c.SelectNodes('ConfigField'))    { $config += (Convert-Field $f) }
    $data   = @(); foreach ($f in $c.SelectNodes('DataField'))      { $data   += (Convert-Field $f) }
    $meth   = @(); foreach ($m in $c.SelectNodes('Method'))         { $meth   += (Convert-Method $m) }
    $agg    = @(); foreach ($a in $c.SelectNodes('Aggregate'))      { $agg    += (Convert-Aggregate $a) }
    $alarm  = @(); foreach ($a in $c.SelectNodes('AlarmCondition')) { $alarm  += (Convert-Alarm $a) }
    $baseNode = $c.SelectSingleNode('Base')

    $script:Classes[$ClassName] = New-Compact ([ordered]@{
        fn     = $c.GetAttribute('name')       # friendly display name (creatable classes)
        cat    = $c.GetAttribute('category')
        sch    = $c.GetAttribute('schema')
        base   = if ($baseNode) { $baseNode.InnerText } else { '' }
        config = @($config)
        data   = @($data)
        agg    = @($agg)
        meth   = @($meth)
        alarm  = @($alarm)
    })

    return @($c.SelectNodes('Subclass') | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ })
}

# Recursively build the tree: @{ Name; Error; Cycle; Children = @(...) }
function Get-SchemaNode {
    param([string]$ClassName, [System.Collections.Generic.HashSet[string]]$Ancestors)

    $node = [ordered]@{ Name = $ClassName; Error = $false; Cycle = $false; Children = @() }
    if ($Ancestors.Contains($ClassName)) { $node.Cycle = $true; return $node }

    $xml = Get-ClassXml -ClassName $ClassName
    if ($null -eq $xml) { $node.Error = $true; return $node }

    $subclasses = if ($script:Classes.Contains($ClassName)) {
        # Already parsed (shared class reached again) - re-read subclasses from xml.
        @($xml.Class.SelectNodes('Subclass') | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ })
    } else {
        Register-Class -ClassName $ClassName -Xml $xml
    }

    $null = $Ancestors.Add($ClassName)
    foreach ($sub in $subclasses) {
        $node.Children += (Get-SchemaNode -ClassName $sub -Ancestors $Ancestors)
    }
    $null = $Ancestors.Remove($ClassName)
    return $node
}

# --- HTML tree rendering --------------------------------------------------
function Get-DescendantCount {
    param($Node)
    $count = $Node.Children.Count
    foreach ($c in $Node.Children) { $count += Get-DescendantCount -Node $c }
    return $count
}

function ConvertTo-TreeHtml {
    param($Node, [int]$Depth = 0)

    $cls  = $Node.Name
    $enc  = HE $cls
    $data = $script:Classes[$cls]
    $friendly = if ($data) { [string]$data['fn'] } else { '' }
    $fhtml = if ($friendly) { " <span class=""friendly"">$(HE $friendly)</span>" } else { '' }
    $href  = $BaseUrl + $cls
    $link  = "<a class=""schema-link"" href=""$href"" target=""_blank"" title=""Open raw schema page"" onclick=""event.stopPropagation()"">&#128279;</a>"
    $name  = "<span class=""name"" onclick=""pick(event,'$cls')"">$enc</span>"

    $badge = ''
    if     ($Node.Cycle) { $badge = ' <span class="tag cycle">cycle</span>' }
    elseif ($Node.Error) { $badge = ' <span class="tag err">unavailable</span>' }

    if ($Node.Children.Count -gt 0) {
        $desc  = Get-DescendantCount -Node $Node
        $count = " <span class=""count"">$($Node.Children.Count) direct / $desc total</span>"
        $open  = if ($Depth -lt 1) { ' open' } else { '' }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("<li data-class=""$cls""><details$open><summary>$name$fhtml $link$count$badge</summary><ul>")
        foreach ($c in $Node.Children) { [void]$sb.Append((ConvertTo-TreeHtml -Node $c -Depth ($Depth + 1))) }
        [void]$sb.Append('</ul></details></li>')
        return $sb.ToString()
    }
    return "<li class=""leaf"" data-class=""$cls"">$name$fhtml $link$badge</li>"
}

# --- Main -----------------------------------------------------------------
if (-not (Confirm-Disclaimer -Accepted:$AcceptDisclaimer)) { return }

Write-Host "Parsing schema from '$RootClass' at $BaseUrl ..." -ForegroundColor Cyan
$root = Get-SchemaNode -ClassName $RootClass -Ancestors ([System.Collections.Generic.HashSet[string]]::new())
Write-Progress -Activity 'Parsing Geo SCADA schema' -Completed

$totalClasses = $script:Classes.Count
$totalDesc    = Get-DescendantCount -Node $root
$generated    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$treeHtml     = ConvertTo-TreeHtml -Node $root -Depth 0

$json = $script:Classes | ConvertTo-Json -Depth 20 -Compress
# Escape '<' as a < JSON unicode escape so an embedded string can never
# terminate the <script> block. (Built from char codes to avoid editor mangling.)
$ltEscape = [char]0x5C + 'u003c'
$json = $json.Replace('<', $ltEscape)

$meta = "Root: <strong>$(HE $RootClass)</strong> &bull; $totalClasses classes &bull; $totalDesc descendants &bull; Source: $(HE $BaseUrl) &bull; Generated $generated"

$template = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Geo SCADA Schema Tree - {{ROOT}}</title>
<style>
  :root { color-scheme: light dark; --accent:#0f6cbd; --muted:#6b7280; --line:#e2e5e9; --bg:#f6f7f9; --panel:#ffffff; }
  * { box-sizing: border-box; }
  body { font-family: 'Segoe UI', system-ui, sans-serif; margin:0; background:var(--bg); color:#1c1e21; }
  header { background:var(--accent); color:#fff; padding:14px 24px; box-shadow:0 1px 4px rgba(0,0,0,.2); }
  header h1 { margin:0; font-size:19px; font-weight:600; }
  header .meta { font-size:12.5px; opacity:.92; margin-top:4px; }
  .toolbar { padding:10px 24px; background:#fff; border-bottom:1px solid var(--line); position:sticky; top:0; z-index:5;
             display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
  .toolbar button { font:inherit; padding:5px 12px; border:1px solid var(--accent); background:#fff; color:var(--accent);
                    border-radius:5px; cursor:pointer; }
  .toolbar button:hover { background:var(--accent); color:#fff; }
  .toolbar input { font:inherit; padding:6px 10px; border:1px solid #ccc; border-radius:5px; min-width:260px; }
  main { padding:14px 24px 60px; }
  ul { list-style:none; margin:0; padding-left:20px; }
  main > ul { padding-left:0; }
  li { margin:2px 0; }
  li.leaf { padding-left:18px; position:relative; }
  li.leaf::before { content:'\2022'; position:absolute; left:2px; color:#9aa0a6; }
  details > summary { cursor:pointer; list-style:none; padding:1px 4px 1px 0; border-radius:4px; }
  details > summary:hover { background:#eef4fb; }
  details > summary::-webkit-details-marker { display:none; }
  details > summary::before { content:'\25B6'; display:inline-block; width:14px; color:var(--accent); font-size:10px;
                              transition:transform .12s; }
  details[open] > summary::before { transform:rotate(90deg); }
  .name { font-weight:600; cursor:pointer; padding:1px 3px; border-radius:4px; }
  .name:hover { background:#dbeafe; text-decoration:underline; }
  li.sel > .name, li.sel > details > summary > .name { background:var(--accent); color:#fff; }
  .friendly { color:var(--muted); font-size:12.5px; font-weight:normal; font-style:italic; }
  .count { color:var(--muted); font-size:12px; font-weight:normal; }
  .schema-link { text-decoration:none; font-size:12px; opacity:.5; }
  .schema-link:hover { opacity:1; }
  .tag { font-size:11px; padding:1px 6px; border-radius:8px; margin-left:6px; }
  .tag.err { background:#fde7e7; color:#b91c1c; }
  .tag.cycle { background:#fff3cd; color:#92600a; }
  .hidden { display:none !important; }
  mark { background:#ffe58a; color:inherit; padding:0 1px; border-radius:2px; }
  footer.disclaimer { margin:0 24px 40px; padding:12px 16px; border-top:1px solid var(--line);
                      font-size:11.5px; line-height:1.5; color:var(--muted); max-width:900px; }
  footer.disclaimer a { color:var(--accent); }

  /* ---- Details panel ---- */
  #panel { position:fixed; top:0; right:0; height:100vh; width:min(480px,94vw); background:var(--panel);
           box-shadow:-3px 0 16px rgba(0,0,0,.25); transform:translateX(100%); transition:transform .18s ease;
           overflow-y:auto; z-index:20; }
  #panel.open { transform:none; }
  #panel .phead { position:sticky; top:0; background:var(--accent); color:#fff; padding:14px 16px; z-index:2; }
  #panel .phead h2 { margin:0; font-size:18px; font-weight:600; word-break:break-all; }
  #panel .phead .pfriendly { font-size:13px; opacity:.95; font-style:italic; margin-top:2px; }
  #panel .phead .pbadges { margin-top:8px; display:flex; gap:6px; flex-wrap:wrap; align-items:center; font-size:12px; }
  #panel .phead .pill { background:rgba(255,255,255,.22); padding:2px 8px; border-radius:10px; }
  #panel .phead a { color:#fff; }
  #panel .pclose { position:absolute; top:10px; right:12px; background:none; border:none; color:#fff; font-size:22px;
                   cursor:pointer; line-height:1; }
  #panel .popts { padding:8px 16px; border-bottom:1px solid var(--line); font-size:12.5px; color:var(--muted);
                  display:flex; gap:14px; align-items:center; flex-wrap:wrap; }
  #panel .pbody { padding:4px 0 40px; }
  section.grp { border-bottom:1px solid var(--line); }
  section.grp > h3 { margin:0; padding:10px 16px; font-size:13px; text-transform:uppercase; letter-spacing:.04em;
                     color:#374151; cursor:pointer; display:flex; justify-content:space-between; align-items:center;
                     background:#f8fafc; user-select:none; }
  section.grp > h3:hover { background:#eef2f7; }
  section.grp > h3 .gc { color:var(--muted); font-weight:normal; text-transform:none; }
  section.grp.collapsed .items { display:none; }
  section.grp > h3::after { content:'\25BC'; font-size:9px; color:var(--muted); margin-left:8px; }
  section.grp.collapsed > h3::after { content:'\25B6'; }
  .items { padding:2px 0; }
  .row { padding:8px 16px; border-top:1px solid #f0f2f4; }
  .row:first-child { border-top:none; }
  .row .rname { font-weight:600; font-family:'Cascadia Code',Consolas,monospace; font-size:13px; }
  .row .rdisp { color:#374151; font-size:12.5px; margin-left:6px; }
  .row .rtype { display:inline-block; background:#eef2f7; color:#334155; border-radius:4px; padding:0 6px;
                font-size:11.5px; margin-left:6px; }
  .row .rflags { font-size:11px; color:var(--muted); margin-left:6px; }
  .row .rdesc { color:#4b5563; font-size:12.5px; margin-top:3px; white-space:pre-wrap; }
  .row .rlink { font-size:11.5px; }
  .chip { display:inline-block; background:#eef4fb; color:#1e40af; border-radius:10px; padding:1px 8px; font-size:11.5px;
          margin:2px 4px 0 0; }
  .chip.enumv { background:#f1f5f9; color:#334155; }
  a.clslink { color:var(--accent); cursor:pointer; text-decoration:none; font-family:'Cascadia Code',Consolas,monospace; }
  a.clslink:hover { text-decoration:underline; }
  .args { margin:4px 0 0 0; padding-left:14px; }
  .args li { font-size:12px; margin:2px 0; }
  .args .an { font-family:'Cascadia Code',Consolas,monospace; font-weight:600; }
  .args .ret { color:#0f766e; font-weight:600; }
  .empty { padding:20px 16px; color:var(--muted); font-style:italic; }
  .enumtoggle { font-size:11.5px; color:var(--accent); cursor:pointer; margin-top:3px; display:inline-block; }
  .enumlist.hidden { display:none; }
</style>
</head>
<body>
<header>
  <h1>Geo SCADA Schema Tree</h1>
  <div class="meta">{{META}}</div>
</header>
<div class="toolbar">
  <button onclick="setAll(true)">Expand all</button>
  <button onclick="setAll(false)">Collapse all</button>
  <input id="filter" type="search" placeholder="Filter name or content (fields, methods, alarms...)" oninput="doFilter(this.value)">
  <span id="filterInfo" class="count"></span>
</div>
<main>
  <ul id="tree">
    {{TREE}}
  </ul>
</main>

<footer class="disclaimer">
  <strong>GeoSCADA-Schema-Tree</strong> &mdash; Copyright &copy; 2026 Adam Woodland. Licensed under the
  <a href="https://www.gnu.org/licenses/gpl-3.0.html" target="_blank">GNU GPL v3</a>.
  <br>
  <strong>Disclaimer:</strong> This report is generated by a tool provided "AS IS", without warranty of any kind,
  express or implied. The author accepts no liability for any damages arising from its use. The generator reads
  Geo SCADA schema metadata over the web API and (for self-signed localhost endpoints) disables TLS certificate
  validation for its session. It is <strong>NOT</strong> certified for production SCADA systems &mdash; review the
  code and test on a representative non-production system before use. You use it at your own risk and remain
  responsible for your own change-control and security policies.
</footer>

<aside id="panel" aria-hidden="true">
  <div class="phead">
    <button class="pclose" title="Close" onclick="closePanel()">&times;</button>
    <h2 id="pTitle"></h2>
    <div id="pFriendly" class="pfriendly"></div>
    <div id="pBadges" class="pbadges"></div>
  </div>
  <div id="pOpts" class="popts"></div>
  <div id="pBody" class="pbody"></div>
</aside>

<script>
var CLASSES = {{JSON}};

// Pre-compute a lowercase search blob per class (name + friendly + own content).
var SEARCH = {};
Object.keys(CLASSES).forEach(function(k){
  var c = CLASSES[k], p = [k, c.fn||'', c.cat||'', c.sch||''];
  ['config','data'].forEach(function(kind){ (c[kind]||[]).forEach(function(m){ p.push(m.n,m.dn,m.d,m.t,m.ref); }); });
  (c.meth||[]).forEach(function(m){ p.push(m.n,m.dn,m.d,m.pv); (m.args||[]).forEach(function(a){ p.push(a.n,a.d); }); });
  (c.agg||[]).forEach(function(a){ p.push(a.n); (a.tables||[]).forEach(function(t){ p.push(t.t,t.name); }); });
  (c.alarm||[]).forEach(function(a){ p.push(a.n,a.cat); (a.subs||[]).forEach(function(s){ p.push(s); }); });
  SEARCH[k] = p.join(' ').toLowerCase();
});

function esc(s){ return String(s==null?'':s).replace(/[&<>"]/g,function(m){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[m];}); }

// ---- Tree interaction ----
function setAll(open){ document.querySelectorAll('#tree details').forEach(function(d){ d.open = open; }); }

function pick(ev, cls){
  ev.preventDefault(); ev.stopPropagation();   // don't toggle the <details>
  document.querySelectorAll('#tree li.sel').forEach(function(li){ li.classList.remove('sel'); });
  var li = document.querySelector('#tree li[data-class="'+cls+'"]');
  if (li) li.classList.add('sel');
  openPanel(cls);
}

function doFilter(term){
  term = term.trim().toLowerCase();
  var tree = document.getElementById('tree'), info = document.getElementById('filterInfo');
  tree.querySelectorAll('mark').forEach(function(m){ var t=document.createTextNode(m.textContent); m.parentNode.replaceChild(t,m); });
  if (!term){
    tree.querySelectorAll('li').forEach(function(li){ li.classList.remove('hidden'); });
    setAll(false);
    var first = tree.querySelector('details'); if (first) first.open = true;
    info.textContent = ''; return;
  }
  tree.querySelectorAll('li').forEach(function(li){ li.classList.add('hidden'); });
  var matches = 0;
  tree.querySelectorAll('li[data-class]').forEach(function(li){
    var cls = li.getAttribute('data-class');
    if ((SEARCH[cls]||cls.toLowerCase()).indexOf(term) === -1) return;
    matches++;
    // Highlight the class name if the term is in the visible name.
    var span = li.querySelector(':scope > .name, :scope > details > summary > .name');
    if (span){
      var txt = span.textContent, i = txt.toLowerCase().indexOf(term);
      if (i !== -1) span.innerHTML = esc(txt.slice(0,i))+'<mark>'+esc(txt.slice(i,i+term.length))+'</mark>'+esc(txt.slice(i+term.length));
    }
    // Reveal this node and all ancestors.
    var el = li;
    while (el && el.id !== 'tree'){
      el.classList.remove('hidden');
      var d = el.querySelector(':scope > details'); if (d) d.open = true;
      el = el.parentElement ? el.parentElement.closest('li') : null;
    }
  });
  info.textContent = matches + ' match' + (matches===1?'':'es');
}

// ---- Detail panel ----
function openClass(cls){
  var li = document.querySelector('#tree li[data-class="'+cls+'"]');
  if (li){
    document.querySelectorAll('#tree li.sel').forEach(function(x){ x.classList.remove('sel'); });
    li.classList.add('sel');
    var el = li.parentElement ? li.parentElement.closest('li') : null;
    while (el){ var d = el.querySelector(':scope > details'); if (d) d.open = true; el = el.parentElement ? el.parentElement.closest('li') : null; }
    li.scrollIntoView({block:'center'});
  }
  openPanel(cls);
}

function clsLink(cls){
  if (CLASSES[cls]) return '<a class="clslink" onclick="openClass(\''+cls+'\')">'+esc(cls)+'</a>';
  return '<span class="clslink" style="color:inherit;cursor:default" title="Not in this tree">'+esc(cls)+'</span>';
}

function fieldRow(m){
  var h = '<div class="row"><span class="rname">'+esc(m.n)+'</span>';
  if (m.dn && m.dn !== m.n) h += '<span class="rdisp">'+esc(m.dn)+'</span>';
  if (m.t) h += '<span class="rtype">'+esc(m.t)+(m.sl?('('+esc(m.sl)+')'):'')+'</span>';
  var flags = [];
  if (m.ro) flags.push('read-only');
  if (m.op) flags.push('OPC '+esc(m.op));
  if (flags.length) h += '<span class="rflags">'+flags.join(' &middot; ')+'</span>';
  if (m.ref) h += '<div class="rlink">&#8594; ref: '+clsLink(m.ref)+'</div>';
  if (m.d) h += '<div class="rdesc">'+esc(m.d)+'</div>';
  if (m.en && m.en.length){
    var id = 'en'+(Math.round(window.__enc=(window.__enc||0)+1));
    h += '<span class="enumtoggle" onclick="document.getElementById(\''+id+'\').classList.toggle(\'hidden\')">'+m.en.length+' enum value'+(m.en.length===1?'':'s')+'</span>';
    h += '<div id="'+id+'" class="enumlist hidden">'+m.en.map(function(e){
           return '<span class="chip enumv">'+(e.v!=null?('<b>'+esc(e.v)+'</b> '):'')+esc(e.t)+'</span>'; }).join('')+'</div>';
  }
  return h + '</div>';
}

function methodRow(m){
  var h = '<div class="row"><span class="rname">'+esc(m.n)+'</span>';
  if (m.dn && m.dn !== m.n) h += '<span class="rdisp">'+esc(m.dn)+'</span>';
  if (m.pv) h += '<span class="rflags">priv: '+esc(m.pv)+'</span>';
  if (m.d) h += '<div class="rdesc">'+esc(m.d)+'</div>';
  if (m.args && m.args.length){
    h += '<ul class="args">'+m.args.map(function(a){
      return '<li><span class="an '+(a.ret?'ret':'')+'">'+esc(a.n)+'</span>'
           + (a.t?' : '+esc(a.t):'') + (a.ret?' <span class="ret">(return)</span>':'')
           + (a.d?' &ndash; '+esc(a.d):'') + '</li>'; }).join('')+'</ul>';
  }
  return h + '</div>';
}

function aggRow(a){
  var h = '<div class="row"><span class="rname">'+esc(a.n)+'</span>';
  if (a.fx) h += '<span class="rflags">fixed</span>';
  if (a.op) h += '<span class="rflags">OPC '+esc(a.op)+'</span>';
  h += '<div class="rlink">'+ (a.tables||[]).map(function(t){
        return (t.name?esc(t.name)+': ':'') + clsLink(t.t); }).join(' &middot; ') + '</div>';
  return h + '</div>';
}

function alarmRow(a){
  var h = '<div class="row"><span class="rname">'+esc(a.n)+'</span>';
  if (a.cat) h += '<span class="rdisp">'+esc(a.cat)+'</span>';
  if (a.ct) h += '<span class="rflags">table: '+clsLink(a.ct)+'</span>';
  if (a.subs && a.subs.length) h += '<div>'+a.subs.map(function(s){ return '<span class="chip">'+esc(s)+'</span>'; }).join('')+'</div>';
  return h + '</div>';
}

var SECTIONS = [
  {key:'config', title:'Configuration Fields', fn:fieldRow},
  {key:'data',   title:'Data Fields',          fn:fieldRow},
  {key:'agg',    title:'Aggregates', fn:aggRow},
  {key:'meth',   title:'Methods',              fn:methodRow},
  {key:'alarm',  title:'Alarm Conditions',     fn:alarmRow}
];

function openPanel(cls){
  var c = CLASSES[cls];
  var panel = document.getElementById('panel');
  document.getElementById('pTitle').textContent = cls;
  var fr = document.getElementById('pFriendly');
  fr.textContent = (c && c.fn) ? c.fn : '';
  fr.style.display = (c && c.fn) ? '' : 'none';

  var badges = [];
  if (c && c.sch) badges.push('<span class="pill">schema: '+esc(c.sch)+'</span>');
  if (c && c.cat) badges.push('<span class="pill">category: '+esc(c.cat)+'</span>');
  if (c && c.base) badges.push('<span class="pill">base: '+clsLink(c.base)+'</span>');
  badges.push('<a href="{{BASEURL}}'+encodeURIComponent(cls)+'" target="_blank" title="Open raw schema page">&#128279; raw</a>');
  document.getElementById('pBadges').innerHTML = badges.join(' ');

  var opts = [];
  if (c){
    SECTIONS.forEach(function(s){ var n=(c[s.key]||[]).length; if (n) opts.push(s.title.split(' ')[0]+': '+n); });
  }
  var optSep = '   ' + String.fromCharCode(8226) + '   ';
  document.getElementById('pOpts').textContent = opts.length ? opts.join(optSep) : '';

  var body = document.getElementById('pBody');
  if (!c){ body.innerHTML = '<div class="empty">No schema data for this class (it was unavailable during the crawl).</div>'; }
  else {
    var html = '';
    SECTIONS.forEach(function(s){
      var arr = c[s.key] || [];
      if (!arr.length) return;
      html += '<section class="grp"><h3 onclick="this.parentNode.classList.toggle(\'collapsed\')">'
            + esc(s.title) + '<span class="gc">'+arr.length+'</span></h3><div class="items">'
            + arr.map(s.fn).join('') + '</div></section>';
    });
    if (!html) html = '<div class="empty">This class defines no members of its own &mdash; all of its properties, methods and alarms are inherited from '
                    + (c.base ? clsLink(c.base) : 'its base class') + '.</div>';
    body.innerHTML = html;
  }
  panel.classList.add('open');
  panel.setAttribute('aria-hidden','false');
  body.scrollTop = 0; panel.scrollTop = 0;
}

function closePanel(){
  var p = document.getElementById('panel');
  p.classList.remove('open'); p.setAttribute('aria-hidden','true');
  document.querySelectorAll('#tree li.sel').forEach(function(li){ li.classList.remove('sel'); });
}
document.addEventListener('keydown', function(e){ if (e.key === 'Escape') closePanel(); });
</script>
</body>
</html>
'@

$html = $template.
    Replace('{{ROOT}}',   (HE $RootClass)).
    Replace('{{META}}',   $meta).
    Replace('{{TREE}}',   $treeHtml).
    Replace('{{JSON}}',   $json).
    Replace('{{BASEURL}}',$BaseUrl)

$html | Out-File -FilePath $OutputPath -Encoding utf8
Write-Host "Done. $totalClasses classes, $totalDesc descendants of $RootClass." -ForegroundColor Green
Write-Host "HTML written to: $OutputPath" -ForegroundColor Green
