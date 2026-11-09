#!/usr/bin/python3
"""OtterScan UI server on 127.0.0.1. Opens a browser tab, or with --app serves the native window."""
import http.client, ipaddress, json, os, secrets, subprocess, sys, threading, time, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import otterscan

# random path so other web pages can't trigger scans through this local server
BASE = f"/{secrets.token_urlsafe(16)}/"
OTTER = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "otter.svg")).read()

PAGE = r"""<!doctype html><html lang=en><meta charset=utf-8><title>OtterScan</title>
<style>
:root{color-scheme:light dark;--line:#8883;--dim:#8a8a8e;--stripe:#8880a;--sel:#12a5ad38;--up:#30b94d;--down:#e5484d;--accent:#12909a;--chip:#12a5ad1f}
*{box-sizing:border-box}html,body{height:100%;margin:0}[hidden]{display:none!important}
body{font:13px -apple-system,system-ui,sans-serif;background:Canvas;color:CanvasText;display:grid;grid-template-rows:auto minmax(0,1fr) auto;grid-template-columns:minmax(0,1fr);cursor:default}
header{display:flex;align-items:center;gap:10px;padding:10px 16px;border-bottom:1px solid var(--line);flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:8px;font-size:15px;font-weight:650;margin-right:6px}.brand svg{width:30px;height:30px}
#range{flex:1;text-align:center;color:var(--dim);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:40px}
input[type=search],select,#menu input{font:inherit;padding:4px 8px;border:1px solid var(--line);border-radius:7px;background:transparent;color:inherit}
button{font:inherit;padding:4px 12px;border:1px solid var(--line);border-radius:7px;background:transparent;color:inherit}
button:focus-visible,tr:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff;min-width:64px;font-weight:600}
label{display:flex;gap:5px;align-items:center;color:var(--dim)}progress{width:110px;height:6px;accent-color:var(--accent)}
.seg{display:flex;border:1px solid var(--line);border-radius:7px;overflow:hidden}.seg button{border:0;border-radius:0}.seg button[aria-pressed=true]{background:var(--chip);font-weight:600}
#go{display:flex;align-items:center;min-width:0;padding:5px 12px}#more{min-width:0;padding:4px 5px;border-left:1px solid #fff6}#more:disabled,#refresh:disabled{opacity:.5}
#refresh{display:flex;padding:5px 8px;background:#fff;color:#1d1d1f}#refresh:disabled{background:#c7c7cc}
#split{display:flex;min-height:0}#wrap{flex:1;overflow:auto;min-width:0;scroll-padding-top:32px}
table{border-collapse:separate;border-spacing:0;white-space:nowrap}
th{position:sticky;top:0;background:Canvas;border-bottom:1px solid var(--line);padding:0;text-align:left;z-index:1}
th button{display:flex;align-items:center;gap:5px;border:0;border-radius:0;font-weight:600;padding:7px 10px;width:100%;text-align:left}
td{padding:4px 10px;font:12px ui-monospace,Menlo,monospace}td.txt{font:13px -apple-system,system-ui,sans-serif}
tbody tr:nth-child(odd){background:var(--stripe)}tbody tr.sel{background:var(--sel)}tr.pin+tr:not(.pin) td{border-top:1px solid var(--line)}
.dev{display:flex;align-items:center;gap:9px}.dev>div{display:flex;flex-direction:column;justify-content:center;height:30px;line-height:16px}
.dev .ic{width:34px;height:34px;margin:-2px;stroke-width:.8;color:var(--accent)}.dev small{font-size:11px;line-height:14px;color:var(--dim)}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;background:var(--down)}.dot.up{background:var(--up)}
.chips{display:flex;flex-wrap:wrap;gap:5px}td.ports{max-width:180px;overflow:hidden;text-overflow:ellipsis}
.chip{display:inline-flex;gap:6px;align-items:baseline;background:var(--chip);border-radius:6px;padding:2px 8px;font:12px -apple-system,system-ui,sans-serif;white-space:nowrap}
.chip b{font:600 11px ui-monospace,Menlo,monospace;color:var(--accent)}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:12px;padding:16px;align-items:start}.cards:empty{display:none}
.card{border:1px solid var(--line);border-radius:10px;padding:12px 14px}.card.sel{background:#0a84ff24;border-color:#0a84ff}.card h3{margin:0;font-size:13px;word-break:break-all}.card p{margin:2px 0 10px;color:var(--dim);font-size:12px}
#empty{padding:64px 24px;text-align:center;color:var(--dim)}#empty svg{width:96px;height:96px;display:block;margin:0 auto 12px}
aside{width:330px;flex:none;border-left:1px solid var(--line);padding:12px 16px;overflow:auto;display:none}aside.open{display:block}
aside .top{display:flex;justify-content:space-between;margin-bottom:12px}
dl{display:grid;grid-template-columns:auto minmax(0,1fr);gap:7px 18px;margin:0}dt{display:flex;align-items:center;gap:8px;white-space:nowrap;color:var(--dim)}dd{margin:0;justify-self:end;text-align:right;word-break:break-all;-webkit-user-select:text;user-select:text}aside .chips{justify-content:flex-end;margin-block:-2px}
hr{grid-column:1/-1;width:100%;border:0;border-top:1px solid var(--line);margin:6px 0}
footer{display:flex;justify-content:space-between;gap:10px;padding:5px 16px;border-top:1px solid var(--line);color:var(--dim)}
button.link{border:0;padding:0;border-radius:0;color:var(--accent);text-decoration:underline;font:inherit;cursor:pointer}
.ic{width:14px;height:14px;flex:none;fill:none;stroke:currentColor;stroke-width:1.4;stroke-linecap:round;stroke-linejoin:round}
th .ic{color:var(--accent)}
th.over-l{box-shadow:inset 2px 0 var(--accent)}th.over-r{box-shadow:inset -2px 0 var(--accent)}
.spin{display:inline-block;width:11px;height:11px;border:2px solid var(--line);border-top-color:var(--accent);border-radius:50%;animation:spin .8s linear infinite;vertical-align:-1px}
@keyframes spin{to{transform:rotate(360deg)}}@media (prefers-reduced-motion:reduce){.spin{animation-duration:4s}}
#menu,#menu .sub{position:fixed;z-index:9;min-width:200px;background:Canvas;border:1px solid var(--line);border-radius:9px;padding:4px;box-shadow:0 8px 28px #0005;display:flex;flex-direction:column;gap:3px;outline:0}
#menu button{display:flex;align-items:center;gap:8px;width:100%;border:0;border-radius:5px;padding:4px 8px;text-align:left}
#menu button:hover,#menu button:focus{background:var(--sel);outline:0}#menu button[aria-checked=true]{background:var(--accent);color:#fff}#menu button[aria-checked=true]:focus{outline:2px solid #fff;outline-offset:-3px}#menu .tick,#menu .arrow{margin-left:auto}#menu .arrow{transform:rotate(-90deg)}#menu input{width:100%}#menu hr{border:0;border-top:1px solid var(--line);margin:4px 0}#menu .menu-label{color:var(--dim);font-size:11px;padding:2px 8px}
</style>
<header><span class=brand><!--otter-->OtterScan</span>
<div class=seg><button id=go class=primary></button><button id=more class=primary aria-label="Choose scan type" aria-haspopup=menu></button></div><button id=refresh aria-label="Scan again" title="Scan again" disabled></button>
<label>Ports <select id=pmode aria-label="Port scan on every device"><option value=off>Off<option value=common>Common<option value=all>Every port (slow)</select></label>
<div class=seg role=group aria-label=View><button id=vDev aria-pressed=true>Devices</button><button id=vPorts aria-pressed=false>Ports</button></div>
<span id=range></span><progress id=bar value=0 max=1 hidden></progress>
<input id=filter type=search placeholder=Filter aria-label="Filter devices" spellcheck=false></header>
<div id=split><div id=wrap><table id=tbl><thead><tr id=hd></tr></thead><tbody id=out></tbody></table><div id=cards class=cards hidden></div><div id=empty><!--otter--><span id=emptyText>Press the scan button to find devices on this network.</span></div></div>
<aside id=side aria-label="Device details"><div class=top><button id=pscan>Scan Every Port</button><button id=closeSide aria-label="Close details">✕</button></div><dl id=info></dl></aside></div>
<footer aria-live=polite><span id=msg>Ready</span><span id=count></span></footer>
<div id=menu role=menu tabindex=-1 hidden></div>
<script>
const $=id=>document.getElementById(id),make=(t,c,x)=>{const e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e};
const COLS=[['Device','hostname',1],['IPv4 address','ip'],['Hostname','host',1],['Ping','ping'],['Open Ports','ports'],['MAC address','mac'],
['IPv6 Local','ipv6_local'],['IPv6 Global','ipv6_global'],['Identification','identification',1],
['mDNS Name','mdns',1],['SMB Name','smb',1],['SMB Domain','smb_domain',1],['DNS Name','dns',1]];
// SF Symbols-style line icons, 16x16
const ICONS={ip:'M1.8 8a6.2 6.2 0 1 0 12.4 0a6.2 6.2 0 1 0-12.4 0M1.8 8h12.4M8 1.8c2.4 2 2.4 10.4 0 12.4M8 1.8c-2.4 2-2.4 10.4 0 12.4',
hostname:'M3.2 2.5h9.6a1.2 1.2 0 0 1 1.2 1.2v6.1a1.2 1.2 0 0 1-1.2 1.2H3.2A1.2 1.2 0 0 1 2 9.8V3.7a1.2 1.2 0 0 1 1.2-1.2M6 14h4M8 11v3',
dns:'M8 1.8v12.4M4 3.2h7.5l2 1.8-2 1.8H4zM12 8.6H4.5l-2 1.8 2 1.8H12z',
ping:'M1.5 8h2l1.5-4 3 9 2-6.5 1 1.5h3.5',
vendor:'M3 14V3.2a.7.7 0 0 1 .7-.7h5.6a.7.7 0 0 1 .7.7V14M10 7h2.3a.7.7 0 0 1 .7.7V14M1.5 14h13M5.5 5.5H7M5.5 8H7M5.5 10.5H7',
ports:'M3.2 3h9.6A1.2 1.2 0 0 1 14 4.2v7.6a1.2 1.2 0 0 1-1.2 1.2H3.2A1.2 1.2 0 0 1 2 11.8V4.2A1.2 1.2 0 0 1 3.2 3M5 13v-2.5H4V7h1V5.5h6V7h1v3.5h-1V13',
mac:'M2 4v8M4.5 4v8M7 4v8M9 4v8M11.5 4v8M14 4v8',
ipv6_local:'M2 7.5l6-5 6 5M3.5 6.5v7h9v-7M6.5 13.5v-4h3v4',
ipv6_global:'M1.8 8a6.2 6.2 0 1 0 12.4 0a6.2 6.2 0 1 0-12.4 0M6 10l4-4M6.5 6H10v3.5',
identification:'M2.5 2.5h5.2l6 6-5.2 5.2-6-6zM5.2 5.2h.01',
mdns:'M7 11a1 1 0 1 0 2 0a1 1 0 1 0-2 0M5 8.2a4 4 0 0 1 6 0M2.8 5.8a7.2 7.2 0 0 1 10.4 0',
smb:'M1.8 4.5a1 1 0 0 1 1-1h3.4l1.6 1.8h5.4a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H2.8a1 1 0 0 1-1-1z',
smb_domain:'M3.8 5.5a2.2 2.2 0 1 0 4.4 0a2.2 2.2 0 1 0-4.4 0M2 13c0-2.6 1.8-4 4-4s4 1.4 4 4M10.5 3.6a2.2 2.2 0 0 1 0 3.8M12 9.4c1.4.6 2.2 1.8 2.2 3.6',
always:'M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8zM6 8a2 2 0 1 0 4 0a2 2 0 1 0-4 0',
empty:'M2 9.5l2-6h8l2 6v3a.7.7 0 0 1-.7.7H2.7a.7.7 0 0 1-.7-.7zM2 9.5h3.5l1 1.5h3l1-1.5H14',
hide:'M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8zM6 8a2 2 0 1 0 4 0a2 2 0 1 0-4 0M2.5 2.5l11 11',
copy:'M6 5.5h7a.8.8 0 0 1 .8.8v7a.8.8 0 0 1-.8.8H6a.8.8 0 0 1-.8-.8v-7a.8.8 0 0 1 .8-.8M3 10.5H2.8a.8.8 0 0 1-.8-.8v-7a.8.8 0 0 1 .8-.8h7a.8.8 0 0 1 .8.8V3',add:'M8 3v10M3 8h10',
reset:'M3 8a5 5 0 1 0 1.6-3.7L3 6M3 2.8V6h3.2',tick:'M3.5 8.5l3 3 6-7',chev:'M4 6l4 4 4-4',refresh:'M13 8a5 5 0 1 1-1.6-3.7L13 6M13 2.8V6H9.8',
scan:'M2 7a5 5 0 1 0 10 0a5 5 0 1 0-10 0M10.6 10.6L14 14',stop:'M4 4h8v8H4z',
live:'M6.6 8a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0-2.8 0M5 11a4.2 4.2 0 0 1 0-6M11 5a4.2 4.2 0 0 1 0 6M3 13a7 7 0 0 1 0-10M13 3a7 7 0 0 1 0 10',
phone:'M5.2 1.5h5.6A1.2 1.2 0 0 1 12 2.7v10.6a1.2 1.2 0 0 1-1.2 1.2H5.2A1.2 1.2 0 0 1 4 13.3V2.7a1.2 1.2 0 0 1 1.2-1.2M7 12.6h2',
computer:'M3.7 3h8.6a1.2 1.2 0 0 1 1.2 1.2V11h-11V4.2A1.2 1.2 0 0 1 3.7 3M.8 11h14.4v.6a1.2 1.2 0 0 1-1.2 1.2H2a1.2 1.2 0 0 1-1.2-1.2z',
tv:'M2.7 2.5h10.6a1.2 1.2 0 0 1 1.2 1.2v7.1a1.2 1.2 0 0 1-1.2 1.2H2.7a1.2 1.2 0 0 1-1.2-1.2V3.7a1.2 1.2 0 0 1 1.2-1.2M5 14.5h6',
speaker:'M5 1.5h6a1.2 1.2 0 0 1 1.2 1.2v10.6a1.2 1.2 0 0 1-1.2 1.2H5a1.2 1.2 0 0 1-1.2-1.2V2.7A1.2 1.2 0 0 1 5 1.5M5.8 10.2a2.2 2.2 0 1 0 4.4 0a2.2 2.2 0 1 0-4.4 0M8 4.3h.01',
printer:'M4.5 5.5V1.8h7v3.7M4.5 11.5H3a1.2 1.2 0 0 1-1.2-1.2V6.7A1.2 1.2 0 0 1 3 5.5h10a1.2 1.2 0 0 1 1.2 1.2v3.6a1.2 1.2 0 0 1-1.2 1.2h-1.5M4.5 9.2h7v5h-7z',
router:'M2.8 9.5h10.4a1.2 1.2 0 0 1 1.2 1.2v2.1a1.2 1.2 0 0 1-1.2 1.2H2.8a1.2 1.2 0 0 1-1.2-1.2v-2.1a1.2 1.2 0 0 1 1.2-1.2M4.5 11.8h.01M7 11.8h.01M11 9.5V5M8.4 4a3.6 3.6 0 0 1 5.2 0M6.6 2.2a6.2 6.2 0 0 1 8.8 0',
server:'M2.8 2h10.4a1.2 1.2 0 0 1 1.2 1.2v3.2a1.2 1.2 0 0 1-1.2 1.2H2.8a1.2 1.2 0 0 1-1.2-1.2V3.2A1.2 1.2 0 0 1 2.8 2M2.8 8.4h10.4a1.2 1.2 0 0 1 1.2 1.2v3.2a1.2 1.2 0 0 1-1.2 1.2H2.8a1.2 1.2 0 0 1-1.2-1.2V9.6a1.2 1.2 0 0 1 1.2-1.2M4.5 4.8h.01M4.5 11.2h.01M8 4.8h4M8 11.2h4'};
ICONS.host=ICONS.hostname;
const icon=n=>{const s=document.createElementNS('http://www.w3.org/2000/svg','svg'),p=document.createElementNS('http://www.w3.org/2000/svg','path');
 s.setAttribute('viewBox','0 0 16 16');s.setAttribute('class','ic');s.setAttribute('aria-hidden','true');p.setAttribute('d',ICONS[n]);s.append(p);return s};
const NAMES=['hostname','host','dns','mdns','smb','smb_domain'];
const DEFAULTS=()=>({order:COLS.map(c=>c[1]),vis:{ipv6_local:'empty',ipv6_global:'empty',identification:'empty',mdns:'empty',smb:'empty',smb_domain:'empty'},urls:{}});
let cfg=DEFAULTS(),rows=[],sort={k:'ip',dir:1},sel=null,ctl=null,me={},queued=false,view='dev',dragKey=null,headKey='',live=false,mine=[],pin=true;
const isMine=r=>pin&&view==='dev'&&mine.includes(r.ip);  // this Mac sits on top until a header is clicked
const ipn=s=>s.split('.').reduce((a,b)=>a*256+ +b,0);
const text=v=>Array.isArray(v)?v.map(p=>p.name+' '+p.port).join(', '):v||'';
// textContent everywhere: every value here came off the network
const chips=ports=>{const d=make('div','chips');for(const p of ports){const c=make('span','chip',p.name);c.append(make('b','',p.port));d.append(c)}return d};
const spin=()=>{const s=make('span','spin');s.setAttribute('role','img');s.setAttribute('aria-label','Still fetching');return s};
function device(r){const d=make('div','dev'),t=make('div'),n=make('div');
 const g=icon(r.kind||'ports');g.removeAttribute('aria-hidden');g.setAttribute('role','img');g.setAttribute('aria-label',r.kind||'device');  // no kind: a plain network jack
 if(r._wait.has('hostname')&&!r.hostname)n.append(spin());else n.textContent=r.hostname||r.ip;
 t.append(n);if(r.vendor)t.append(make('small','',r.vendor));d.append(g,t);return d}
function compare(a,b){const k=sort.k;
 if(isMine(a)!==isMine(b))return isMine(a)?-1:1;
 if(k==='ip')return (ipn(a.ip)-ipn(b.ip))*sort.dir;
 if(k==='ping')return (a.ping-b.ping)*sort.dir||ipn(a.ip)-ipn(b.ip);
 if(k==='ports')return (a.ports.length-b.ports.length)*sort.dir||ipn(a.ip)-ipn(b.ip);
 if(!a[k]!==!b[k])return a[k]?-1:1;  // blanks stay at the bottom either way
 return String(a[k]).localeCompare(String(b[k]))*sort.dir||ipn(a.ip)-ipn(b.ip)}
const save=()=>fetch('settings',{method:'POST',body:JSON.stringify(cfg)}).catch(()=>{$('msg').textContent='Could not save column settings'});
function applyCfg(s){const keys=COLS.map(c=>c[1]),d=DEFAULTS(),saved=s.order||[];
 // a saved 'vendor' means the order predates the Device column, so move Device first; no 'host' predates Hostname, which takes DNS Name's spot
 cfg={order:[...new Set([...(saved.includes('vendor')?['hostname']:[]),...saved.map(k=>k==='dns'&&!saved.includes('host')?'host':k).filter(k=>keys.includes(k)),...keys])],vis:{...d.vis},urls:s.urls||{}};
 for(const k of keys)if(['always','empty','hide'].includes((s.vis||{})[k]))cfg.vis[k]=s.vis[k];headKey='';render()}
function move(from,to,after){const o=cfg.order.filter(x=>x!==from);o.splice(o.indexOf(to)+(after?1:0),0,from);cfg.order=o;headKey='';save();render()}
function visibleCols(){const on=cfg.order.map(k=>COLS.find(c=>c[1]===k)).filter(([,k])=>{const v=cfg.vis[k]||'always';
  return v==='always'||(v==='empty'&&rows.some(r=>text(r[k])||r._wait.has(k)))});
 return on.length?on:COLS}  // never strand you with no header to right-click
function makeTh([label,k]){const th=make('th'),b=make('button');b.append(icon(k),make('span','',label));th.dataset.k=k;th.draggable=true;
 b.onclick=()=>{pin=false;sort=sort.k===k?{k,dir:-sort.dir}:{k,dir:1};render()};
 b.onkeydown=e=>{if(e.altKey&&(e.key==='ArrowLeft'||e.key==='ArrowRight')){e.preventDefault();  // keyboard way to reorder
  const v=visibleCols().map(c=>c[1]),n=v[v.indexOf(k)+(e.key==='ArrowRight'?1:-1)];
  if(n){move(k,n,e.key==='ArrowRight');document.querySelector('th[data-k='+k+'] button').focus()}}};
 const side=e=>{const r=th.getBoundingClientRect();return e.clientX>r.left+r.width/2};
 th.ondragstart=e=>{dragKey=k;e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain',k)};
 th.ondragover=e=>{if(dragKey&&dragKey!==k){e.preventDefault();th.className=side(e)?'over-r':'over-l'}};
 th.ondragleave=()=>{th.className=''};
 th.ondrop=e=>{e.preventDefault();th.className='';if(dragKey&&dragKey!==k){const f=dragKey;dragKey=null;move(f,k,side(e))}};
 th.ondragend=()=>{dragKey=null;render()};
 th.oncontextmenu=e=>{e.preventDefault();const r=th.getBoundingClientRect();openMenu(k,e.clientX||r.left,e.clientY||r.bottom,b)};
 th.append(b);return th}
function closeMenu(){$('menu').hidden=true}
function menuItem(ic,label,fn,on,to=$('menu')){const b=make('button');b.setAttribute('role',on===undefined?'menuitem':'menuitemradio');if(on!==undefined)b.setAttribute('aria-checked',on);
 b.append(icon(ic),make('span','',label));if(on){const t=icon('tick');t.classList.add('tick');b.append(t)}
 b.onclick=()=>{closeMenu();fn()};to.append(b)}
function showMenu(x,y,back){const m=$('menu');m.hidden=false;m.style.left=Math.min(x,innerWidth-m.offsetWidth-8)+'px';m.style.top=Math.min(y,innerHeight-m.offsetHeight-8)+'px';m.focus();  // the box, not a row: a focused row would look hovered as soon as the menu opens
 m.onkeydown=e=>{if(e.key==='Escape'){closeMenu();back.focus()}}}
function openMenu(k,x,y,back){const m=$('menu');m.replaceChildren();
 const item=(ic,label,fn,on)=>menuItem(ic,label,()=>{fn();headKey='';save();render();back.isConnected&&back.focus()},on);
 const set=v=>()=>{cfg.vis[k]=v},cur=cfg.vis[k]||'always';
 item('always','Always Show',set('always'),cur==='always');item('empty','Hide When Empty',set('empty'),cur==='empty');item('hide','Hide',set('hide'),cur==='hide');
 const hidden=COLS.filter(c=>cfg.vis[c[1]]==='hide');
 if(hidden.length){m.append(make('hr'),make('div','menu-label','Hidden'));for(const [label,h] of hidden)item(h,'Show '+label,()=>{cfg.vis[h]='always'})}
 m.append(make('hr'));item('reset','Reset Columns',()=>{cfg={...DEFAULTS(),urls:cfg.urls}});
 showMenu(x,y,back)}
const openUrl=u=>fetch('open?url='+encodeURIComponent(u)).then(x=>x.json()).then(j=>{if(j.error)$('msg').textContent='Could not open Safari: '+j.error;return !j.error});
function copy(s){const t=make('textarea');t.value=s;document.body.append(t);t.select();$('msg').textContent=document.execCommand('copy')?'Copied':'Could not copy';t.remove()}  // execCommand: needs no secure context or clipboard permission
function rowMenu(e,r,back){e.preventDefault();const m=$('menu'),sub=make('div','sub'),more=make('button'),add=make('button'),arrow=icon('chev'),b=back.getBoundingClientRect();m.replaceChildren();sub.hidden=true;sub.setAttribute('role','menu');
 const refocus=()=>{back.isConnected&&back.focus()};
 add.setAttribute('role','menuitem');add.append(icon('add'),make('span','','Add New URL'));
 add.onclick=()=>{const i=make('input');i.type='url';i.spellcheck=false;i.setAttribute('aria-label','New URL');i.value='http://'+r.ip+':';
  i.onkeydown=k=>{if(k.key!=='Enter')return;const u=i.value.trim();closeMenu();refocus();
   openUrl(u).then(ok=>{const l=cfg.urls[r.ip]||[];if(ok&&!l.includes(u)){cfg.urls[r.ip]=[...l,u];save()}})};  // saved only once the server accepts it
  add.replaceWith(i);i.focus()};
 sub.append(add,make('hr'));
 for(const u of ['http://'+r.ip+':80','https://'+r.ip+':443',...(cfg.urls[r.ip]||[])])menuItem('ipv6_global',u,()=>openUrl(u),undefined,sub);
 more.setAttribute('role','menuitem');more.setAttribute('aria-haspopup','menu');arrow.classList.add('arrow');more.append(icon('ipv6_global'),make('span','','Open in Browser'),arrow);
 const show=()=>{sub.hidden=false;const a=more.getBoundingClientRect();sub.style.left=(a.right+sub.offsetWidth+4>innerWidth?a.left-sub.offsetWidth-4:a.right+4)+'px';sub.style.top=Math.min(a.top,innerHeight-sub.offsetHeight-8)+'px'};
 more.onmouseenter=show;more.onclick=()=>{show();sub.querySelector('button').focus()};
 m.onmouseover=h=>{const t=h.target.closest('button');if(t&&t!==more&&!sub.contains(t)&&!sub.contains(document.activeElement))sub.hidden=true};  // buttons only: the padding between the two menus must not close it
 m.append(more,sub,make('hr'));
 const item=(ic,label,v)=>menuItem(ic,label,()=>{copy(v);refocus()});
 item('copy','Copy',visibleCols().map(([,k])=>k==='ping'?(r.ping?'Replied':'No reply'):text(r[k])).join('\t'));
 for(const [label,k] of [['Copy IP Address','ip'],['Copy MAC Address','mac'],['Copy Hostname','hostname'],['Copy Vendor','vendor']])if(r[k])item(k,label,r[k]);
 showMenu(e.clientX||b.left,e.clientY||b.bottom,back)}
// WebKit's default menu is only Reload here; inputs and detail values keep theirs for copy and paste
addEventListener('contextmenu',e=>{if(!e.target.closest('input,dd'))e.preventDefault()});
addEventListener('mousedown',e=>{if(!$('menu').contains(e.target)&&!$('more').contains(e.target))closeMenu()});
$('more').append(icon('chev'));
$('refresh').append(icon('refresh'));
function drawGo(){const b=$('go'),t=ctl?'Stop':live?'Live Scan':'Scan';b.replaceChildren(icon(ctl?'stop':live?'live':'scan'));b.setAttribute('aria-label',t);b.title=t}
drawGo();
$('more').onclick=()=>{if(!$('menu').hidden)return closeMenu();$('menu').replaceChildren();
 for(const [ic,label,v] of [['live','Live Scan',true],['scan','Scan',false]])menuItem(ic,label,()=>{live=v;drawGo();$('refresh').hidden=v;$('go').focus()},live===v);
 const r=$('go').getBoundingClientRect();showMenu(r.left,r.bottom+4,$('more'))};
function render(){queued=false;
 const q=$('filter').value.trim().toLowerCase();
 const shown=rows.filter(r=>!q||r.vendor.toLowerCase().includes(q)||COLS.some(([,k])=>k!=='ping'&&text(r[k]).toLowerCase().includes(q))).sort(compare);
 const ports=view==='ports';$('tbl').hidden=ports||!rows.length;$('cards').hidden=!ports;
 if(ports){const withPorts=shown.filter(r=>r.ports.length);
  $('cards').replaceChildren(...withPorts.map(r=>{const c=make('div',r.ip===sel?'card sel':'card');c.dataset.ip=r.ip;c.tabIndex=0;c.oncontextmenu=e=>rowMenu(e,r,c);c.onclick=()=>select(r.ip);c.onkeydown=e=>{if(e.key==='Enter')select(r.ip)};
   c.append(make('h3','',r.hostname||r.ip),make('p','',[r.ip,r.vendor,r.ports.length+(r.ports.length===1?' open port':' open ports')].filter(Boolean).join(' · ')),chips(r.ports));return c}));
  $('empty').hidden=withPorts.length>0;$('emptyText').textContent=ctl?'Checking ports...':'No open ports to show yet. Press the scan button to check this network.'}
 else{const body=document.createDocumentFragment(),cols=visibleCols(),hk=cols.map(c=>c[1]).join();
  if(hk!==headKey&&!dragKey){headKey=hk;$('hd').replaceChildren(...cols.map(makeTh))}  // not mid-drag: that would cancel it
  for(const r of shown){const tr=make('tr');tr.dataset.ip=r.ip;tr.tabIndex=0;if(r.ip===sel)tr.className='sel';if(isMine(r))tr.classList.add('pin');
   for(const [,k,txt] of cols){const td=tr.insertCell();if(txt)td.className='txt';
    if(k==='hostname')td.append(device(r));
    else if(r._wait.has(k)&&!text(r[k]))td.append(spin());
    else if(k==='ping'){const d=make('span','dot'+(r.ping?' up':''));d.setAttribute('role','img');d.setAttribute('aria-label',r.ping?'Replied to ping':'No ping reply');td.append(d)}
    else if(k==='ports'){td.className='ports';td.textContent=r.ports.map(p=>p.port).join(', ');td.title=text(r.ports)}
    else td.textContent=text(r[k])}
   tr.oncontextmenu=e=>rowMenu(e,r,tr);tr.onclick=()=>select(r.ip);tr.onkeydown=e=>{if(e.key==='Enter')select(r.ip)};body.append(tr)}
  $('out').replaceChildren(body);$('empty').hidden=rows.length>0;$('emptyText').textContent='Press the scan button to find devices on this network.'}
 document.querySelectorAll('th').forEach(th=>{const on=th.dataset.k===sort.k;th.setAttribute('aria-sort',on?(sort.dir>0?'ascending':'descending'):'none');
  th.querySelector('span').textContent=COLS.find(c=>c[1]===th.dataset.k)[0]+(on?(sort.dir>0?' ▲':' ▼'):'')});
 $('count').textContent='Devices seen: '+rows.length+(q?' ('+shown.length+' shown)':'')}
// a redraw replaces the rows and would wipe text highlighted in them, so hold off until it's cleared
const redraw=()=>{const s=getSelection();if(s.isCollapsed||!$('wrap').contains(s.anchorNode))render();else setTimeout(redraw,300)};
const later=()=>{if(!queued){queued=true;setTimeout(redraw,120)}};
function details(){const r=rows.find(x=>x.ip===sel);if(!r)return;const dl=$('info');dl.replaceChildren();
 const add=(h,v,k)=>{const dd=make('dd'),dt=make('dt');if(k)dt.append(icon(k));dt.append(h+':');
  if(k&&r._wait.has(k)&&!text(r[k]))dd.append(make('span','spin'));else v instanceof Node?dd.append(v):dd.textContent=v||'';dl.append(dt,dd)};
 const has=n=>r.ports.some(p=>p.port===n),link=make('button','link',r.ip);link.title='Open in Safari';
 link.onclick=()=>openUrl((has(443)&&!has(80)?'https':'http')+'://'+r.ip+'/');
 for(const [h,k] of COLS.flatMap(c=>c[1]==='hostname'?[['Hostname','hostname'],['Vendor','vendor']]:c[1]==='host'?[]:[c]))add(h,k==='ip'?link:k==='ping'?(r.ping?'Replied':'No reply'):k==='ports'?chips(r.ports):text(r[k]),k);
 dl.append(make('hr'));add('ISP',me.isp);add('Country',me.country);add('Public IPv4',me.query)}
function select(ip){sel=ip;$('side').classList.add('open');details();document.querySelectorAll('#out tr,.card').forEach(e=>e.classList.toggle('sel',e.dataset.ip===ip))}  // not render(): this runs on mouseup, and rebuilding the rows would wipe the text just highlighted
function setView(v){view=v;if(v==='ports'&&$('pmode').value==='off')$('pmode').value='common';$('vDev').setAttribute('aria-pressed',v==='dev');$('vPorts').setAttribute('aria-pressed',v==='ports');render()}
$('vDev').onclick=()=>setView('dev');$('vPorts').onclick=()=>setView('ports');
$('closeSide').onclick=()=>{sel=null;$('side').classList.remove('open');render()};
$('filter').oninput=later;
// on window, finding the row fresh each press: render() rebuilds the rows, and live scans redraw and drop focus
addEventListener('keydown',e=>{const d={ArrowDown:1,ArrowUp:-1}[e.key],c=view==='ports'?'.card':'#out tr';
 if(!d||e.altKey||e.metaKey||e.ctrlKey||!$('menu').hidden||e.target.matches('input,select'))return;
 const all=[...document.querySelectorAll(c)],cur=e.target.closest(c)||document.querySelector(c+'.sel'),next=cur?all[all.indexOf(cur)+d]:all[d>0?0:all.length-1];
 if(!next)return;e.preventDefault();select(next.dataset.ip);document.querySelector(c+'.sel').focus()});
$('pscan').onclick=async()=>{const ip=sel,b=$('pscan'),r=rows.find(x=>x.ip===ip);b.disabled=true;b.textContent='Scanning...';
 r.ports=[];r._wait.add('ports');r._wait.add('identification');details();render();
 try{const j=await (await fetch('ports?mode=all&ip='+encodeURIComponent(ip))).json();if(j.error)throw j.error;Object.assign(r,j)}
 catch(e){$('msg').textContent='Port scan failed: '+e}
 r._wait.delete('ports');r._wait.delete('identification');details();render();
 b.disabled=false;b.textContent='Scan Every Port'};
async function scan(){if(ctl){ctl.abort();return}
 ctl=new AbortController();rows=[];sel=null;$('side').classList.remove('open');render();
 const bar=$('bar'),mode=$('pmode').value;let done=0,total=0;bar.hidden=false;bar.removeAttribute('value');
 drawGo();$('more').disabled=$('refresh').disabled=true;$('msg').textContent='Finding devices...';$('range').textContent='';
 const sig=()=>rows.map(r=>r.ip+r.ping).join();  // redraw only on change: a redraw drops keyboard focus
 let end='Scan complete';
 try{const r=await fetch('scan?mode='+mode+'&live='+(live?1:0),{signal:ctl.signal});
  const rd=r.body.getReader(),dec=new TextDecoder();let buf='';
  for(;;){const c=await rd.read();if(c.done)break;buf+=dec.decode(c.value,{stream:true});
   const lines=buf.split('\n');buf=lines.pop();
   for(const l of lines){const m=JSON.parse(l);
    if(m.error)throw m.error;
    if(m.net){$('range').textContent='Scan of '+m.net;mine=m.mine}
    if(m.seen){const was=sig();if(sel&&!(sel in m.seen)){sel=null;$('side').classList.remove('open')}
     rows=rows.filter(r=>r.ip in m.seen);rows.forEach(r=>r.ping=m.seen[r.ip]);if(sig()!==was){details();later()}}
    if(m.total!==undefined){total=m.total;done=0;if(!live){bar.max=total||1;bar.value=0}}  // setting a value would stop live's endless animation
    if(m.row){m.row._wait=new Set(mode==='off'?NAMES:[...NAMES,'ports','identification']);rows=rows.filter(x=>x.ip!==m.row.ip);rows.push(m.row);later()}
    if(m.update){const r=rows.find(x=>x.ip===m.update.ip);if(r){Object.assign(r,m.update);r._wait.clear();if(r.ip===sel)details()}done++;if(!live)bar.value=done;
     $('msg').textContent=(mode==='off'?'Looking up names... ':'Checking ports... ')+done+' of '+total;later()}
    if(live&&done===total&&(m.update||m.seen)){$('msg').textContent='Live: watching for changes'}}}
 }catch(e){end=e.name==='AbortError'?'Stopped':'Error: '+e}
 rows.forEach(r=>r._wait.clear());ctl=null;bar.hidden=true;drawGo();$('more').disabled=$('refresh').disabled=false;$('msg').textContent=end;details();later()}
$('go').onclick=$('refresh').onclick=scan;
fetch('me').then(r=>r.json()).then(j=>{me=j;details()});
render();
fetch('settings').then(r=>r.json()).then(applyCfg);
</script></html>""".replace("<!--otter-->", OTTER)

_me = None
# a file, not browser storage: the port changes every launch, which would wipe localStorage
SETTINGS = os.path.expanduser("~/Library/Application Support/OtterScan/settings.json")


def public_info():  # one call to ip-api.com (reveals your public IP to them); cached
    global _me
    if _me is None:
        try:
            # http.client, not urllib.request: urllib loads macOS proxy code that crashes forked children
            c = http.client.HTTPConnection("ip-api.com", timeout=4)
            c.request("GET", "/json/?fields=isp,country,query")
            _me = json.load(c.getresponse())
        except (OSError, ValueError, http.client.HTTPException):
            _me = {}
    return _me


def private_ip(s):
    ip = ipaddress.ip_address(s)
    if ip.version != 4 or not ip.is_private:
        raise ValueError("OtterScan only scans private IPv4 addresses")
    return s


def web_url(s):
    u = urlparse(s)
    if u.scheme not in ("http", "https") or "\\" in s:  # browsers read a backslash as a slash, so the host check below would lie
        raise ValueError("only http and https URLs can be opened")
    private_ip(u.hostname or "")
    return u.geturl()


def parse_net(s):
    net = ipaddress.ip_network(s, strict=False) if s else otterscan.local_net()
    if net.version != 4 or not net.is_private:
        raise ValueError("OtterScan only scans private IPv4 ranges")
    if net.num_addresses > 4096:
        raise ValueError("range too big (max /20)")
    return net


class H(BaseHTTPRequestHandler):
    def reply(self, body, ct="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.end_headers()
        self.wfile.write(body)

    def line(self, obj):
        self.wfile.write(json.dumps(obj).encode() + b"\n")
        self.wfile.flush()

    def do_GET(self):
        u = urlparse(self.path)
        if not u.path.startswith(BASE):
            return self.send_error(404)
        route, q = u.path[len(BASE):], parse_qs(u.query)
        mode = q.get("mode", ["off"])[0]
        if mode not in ("off", "common", "all"):
            mode = "off"
        if route == "":
            self.reply(PAGE.encode(), "text/html; charset=utf-8")
        elif route == "me":
            self.reply(json.dumps(public_info()).encode())
        elif route == "open":
            try:
                subprocess.run(["/usr/bin/open", "-a", "Safari", web_url(q.get("url", [""])[0])], check=True)
                out = {}
            except (ValueError, OSError, subprocess.SubprocessError) as e:
                out = {"error": str(e)}
            self.reply(json.dumps(out).encode())
        elif route == "settings":
            try:
                with open(SETTINGS) as f:
                    json.load(f)  # a corrupt file should mean defaults, not a broken page
                    f.seek(0)
                    self.reply(f.read().encode())
            except (OSError, ValueError):
                self.reply(b"{}")
        elif route == "ports":
            try:
                out = otterscan.port_info(private_ip(q.get("ip", [""])[0]), "all" if mode == "all" else "common")
            except (ValueError, OSError) as e:
                out = {"error": str(e)}
            self.reply(json.dumps(out).encode())
        elif route == "scan":
            self.reply(b"", "application/x-ndjson")
            try:
                net = parse_net(q.get("net", [""])[0])
                self.line({"net": str(net), "mine": otterscan.local_ips()})
                for event in otterscan.events(net, mode, q.get("live") == ["1"]):
                    self.line(event)
            except ConnectionError:  # user pressed Stop; leaving the loop cancels the rest
                pass
            except (ValueError, OSError) as e:
                self.line({"error": str(e)})
        else:
            self.send_error(404)

    def do_POST(self):
        if urlparse(self.path).path != BASE + "settings":
            return self.send_error(404)
        try:
            n = int(self.headers.get("Content-Length", 0))
            if not 0 < n <= 65536:
                raise ValueError
            cfg = json.loads(self.rfile.read(n))
            if not isinstance(cfg, dict):
                raise ValueError
        except ValueError:
            return self.send_error(400)
        os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
        with open(SETTINGS + ".tmp", "w") as f:  # replace atomically so a crash can't leave half a file
            json.dump(cfg, f)
        os.replace(SETTINGS + ".tmp", SETTINGS)
        self.reply(b"{}")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    url = f"http://127.0.0.1:{srv.server_port}{BASE}"
    print("OtterScan at", url)
    if "--app" in sys.argv:
        app_dir = os.path.dirname(SETTINGS)
        app_pid = int(open(os.path.join(app_dir, "app.pid")).read())

        def exit_with_app():  # started via Terminal, so we can't inherit a pipe from the app
            while True:
                time.sleep(2)
                try:
                    os.kill(app_pid, 0)
                except OSError:
                    os._exit(0)

        threading.Thread(target=exit_with_app, daemon=True).start()
        # private (0600) and atomic: the URL holds this session's token and the app polls for it
        fd = os.open(os.path.join(app_dir, "server.url.tmp"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(url)
        os.replace(os.path.join(app_dir, "server.url.tmp"), os.path.join(app_dir, "server.url"))
    else:
        threading.Timer(0.5, webbrowser.open, [url]).start()
    srv.serve_forever()
