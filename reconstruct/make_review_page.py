#!/usr/bin/env python3
"""Builds a local review page (review.html) from trips.json: one card per trip with a map,
the computed metrics, the suggested label and a choice "Vélo / Pas vélo / Ignorer".
Choices are kept in the browser and exported with "Télécharger mes choix" (validation.json).

Map tiles come from openstreetmap.org (only the viewed map areas are requested).
Usage: python3 make_review_page.py WORK_DIR
"""
import json
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

PARIS = ZoneInfo("Europe/Paris")
DAYS = ["lun.", "mar.", "mer.", "jeu.", "ven.", "sam.", "dim."]
MAX_POINTS = 600


def compact(trip):
    pts = trip["points"]
    step = max(1, len(pts) // MAX_POINTS)
    keep = pts[::step] + ([pts[-1]] if (len(pts) - 1) % step else [])
    out, prev = [], None
    for p in keep:
        t = datetime.fromisoformat(p["t"])
        gap = prev is not None and (t - prev).total_seconds() > 60
        out.append([round(p["lat"], 6), round(p["lon"], 6), round((p["speed"] or 0) * 3.6, 1) if (p["speed"] or 0) >= 0 else None, 1 if gap else 0])
        prev = t
    m = trip["metrics"]
    t0 = datetime.fromisoformat(trip["start"]).astimezone(PARIS)
    t1 = datetime.fromisoformat(trip["end"]).astimezone(PARIS)
    return {
        "id": trip["id"], "label": trip["label"], "reasons": trip["reasons"],
        "day": f"{DAYS[t0.weekday()]} {t0:%d/%m}", "time": f"{t0:%H:%M}–{t1:%H:%M}",
        "km": round(m["distance_m"] / 1000, 2), "min": round(m["duration_s"] / 60),
        "avg": round(m["avg_speed_kmh"] or 0, 1), "median": round(m["speed_median_kmh"] or 0, 1),
        "watch": trip["watch_overlap"], "pts": out,
    }


PAGE = """<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Trajets à valider</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"></script>
<style>
:root { --bg:#f6f6f4; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:#e3e3e0; --velo:#1f8a4c; --non:#b3261e; --ign:#8a8a8e; --warn:#b36b00; }
@media (prefers-color-scheme: dark) { :root { --bg:#161617; --card:#1f1f21; --text:#f2f2f2; --muted:#a1a1a6; --line:#333336; } }
* { box-sizing:border-box; } body { margin:0; background:var(--bg); color:var(--text); font:15px/1.45 -apple-system, system-ui, sans-serif; }
header { position:sticky; top:0; z-index:1000; background:var(--card); border-bottom:1px solid var(--line); padding:12px 16px; display:flex; gap:12px; flex-wrap:wrap; align-items:center; }
header h1 { font-size:17px; margin:0 12px 0 0; } .count { color:var(--muted); } button { font:inherit; padding:7px 12px; border-radius:8px; border:1px solid var(--line); background:var(--bg); color:var(--text); cursor:pointer; }
button.primary { background:var(--velo); color:#fff; border-color:var(--velo); } select { font:inherit; padding:6px; border-radius:8px; }
main { max-width:1100px; margin:0 auto; padding:16px; } h2 { font-size:15px; color:var(--muted); margin:24px 0 8px; }
.grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(320px, 1fr)); gap:14px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:12px; overflow:hidden; border-left:5px solid var(--line); }
.card.c-velo { border-left-color:var(--velo); } .card.c-non { border-left-color:var(--non); } .card.c-ign { border-left-color:var(--ign); opacity:.65; }
.map { height:210px; background:var(--line); } .body { padding:10px 12px; } .title { font-weight:600; } .meta { color:var(--muted); font-size:13px; }
.reason { font-size:12.5px; margin-top:4px; } .reason.warn { color:var(--warn); } .watch { font-size:12.5px; color:var(--velo); margin-top:4px; font-weight:600; }
.choices { display:flex; gap:6px; margin-top:8px; } .choices label { flex:1; text-align:center; border:1px solid var(--line); border-radius:8px; padding:5px 0; cursor:pointer; font-size:13px; }
.choices input { display:none; } .choices input:checked + span { font-weight:700; } .choices label:has(input:checked) { background:var(--bg); border-color:var(--text); }
.legend { font-size:12.5px; color:var(--muted); } .legend b { display:inline-block; width:18px; height:4px; vertical-align:middle; margin:0 4px 0 10px; }
</style></head><body>
<header><h1>Trajets à valider</h1><span class="count" id="count"></span>
<select id="filter"><option value="all">Tout afficher</option><option value="todo">Non encore choisis</option><option value="velo">Vélo</option><option value="non">Pas vélo</option></select>
<button class="primary" id="dl">Télécharger mes choix</button>
<span class="legend">vitesse :<b style="background:#2e7d32"></b>&lt;12<b style="background:#f9a825"></b>12–30<b style="background:#d84315"></b>&gt;30 km/h · pointillés = trou GPS &gt;1 min</span></header>
<main id="main"></main>
<script>
const TRIPS = __DATA__;
const SECTIONS = [["a_verifier","À vérifier en priorité"],["velo","Proposés comme vélo"],["marche","Proposés comme marche"],["trop_court","Trop courts (ignorés par défaut)"]];
const DEFAULT = {velo:"velo", marche:"non", trop_court:"ign", a_verifier:null};
let choices = {}; try { choices = JSON.parse(localStorage.getItem("choices") || "{}"); } catch (e) {}
for (const t of TRIPS) if (!(t.id in choices) && DEFAULT[t.label]) choices[t.id] = DEFAULT[t.label];
const save = () => { try { localStorage.setItem("choices", JSON.stringify(choices)); } catch (e) {} };
const color = v => v == null ? "#888" : v < 12 ? "#2e7d32" : v <= 30 ? "#f9a825" : "#d84315";
const main = document.getElementById("main");
function render() {
  main.innerHTML = ""; const f = document.getElementById("filter").value;
  for (const [key, title] of SECTIONS) {
    const list = TRIPS.filter(t => t.label === key && (f === "all" || (f === "todo" ? !choices[t.id] : choices[t.id] === f)));
    if (!list.length) continue;
    const h = document.createElement("h2"); h.textContent = `${title} (${list.length})`; main.append(h);
    const grid = document.createElement("div"); grid.className = "grid"; main.append(grid);
    for (const t of list) grid.append(card(t));
  }
  count();
}
function card(t) {
  const c = document.createElement("div"); c.className = "card"; c.dataset.id = t.id;
  const w = t.watch.length ? `<div class="watch">⌚ Séance montre sans tracé : ce trajet peut lui donner sa carte</div>` : "";
  const reasons = t.reasons.map(r => `<div class="reason ${t.label === "a_verifier" ? "warn" : ""}">${r}</div>`).join("");
  c.innerHTML = `<div class="map"></div><div class="body"><div class="title">${t.day} · ${t.time}</div>
    <div class="meta">${t.km} km · ${t.min} min · moy. ${t.avg} km/h · médiane ${t.median} km/h</div>${w}${reasons}
    <div class="choices">${[["velo","🚲 Vélo"],["non","Pas vélo"],["ign","Ignorer"]].map(([v,l]) =>
      `<label><input type="radio" name="${t.id}" value="${v}" ${choices[t.id]===v?"checked":""}><span>${l}</span></label>`).join("")}</div></div>`;
  c.querySelectorAll("input").forEach(i => i.addEventListener("change", () => { choices[t.id] = i.value; save(); paint(c, i.value); count(); }));
  paint(c, choices[t.id]); observer.observe(c); return c;
}
function paint(c, v) { c.classList.remove("c-velo","c-non","c-ign"); if (v) c.classList.add("c-" + v); }
const observer = new IntersectionObserver(entries => { for (const e of entries) if (e.isIntersecting && !e.target.dataset.map) {
  e.target.dataset.map = 1; const t = TRIPS.find(x => x.id === e.target.dataset.id); drawMap(e.target.querySelector(".map"), t); } }, {rootMargin:"300px"});
function drawMap(el, t) {
  const m = L.map(el, {zoomControl:false, attributionControl:true});
  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {maxZoom:19, attribution:"© OpenStreetMap"}).addTo(m);
  const p = t.pts;
  for (let i = 1; i < p.length; i++) L.polyline([[p[i-1][0],p[i-1][1]],[p[i][0],p[i][1]]], {color:color(p[i][2]), weight:4, dashArray:p[i][3]?"6 6":null}).addTo(m);
  if (p.length) { L.circleMarker([p[0][0],p[0][1]], {radius:5, color:"#1f8a4c", fillOpacity:1}).addTo(m); L.circleMarker([p[p.length-1][0],p[p.length-1][1]], {radius:5, color:"#b3261e", fillOpacity:1}).addTo(m);
    m.fitBounds(L.latLngBounds(p.map(x => [x[0],x[1]])), {padding:[12,12]}); }
}
function count() { const v = TRIPS.filter(t => choices[t.id]==="velo"); const km = v.reduce((s,t)=>s+t.km,0);
  const todo = TRIPS.filter(t => !choices[t.id]).length;
  document.getElementById("count").textContent = `${v.length} vélo (${km.toFixed(1)} km) · ${todo} à choisir`; }
document.getElementById("filter").addEventListener("change", render);
document.getElementById("dl").addEventListener("click", () => {
  const blob = new Blob([JSON.stringify({generated: new Date().toISOString(), choices}, null, 1)], {type:"application/json"});
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "validation-trajets.json"; a.click(); });
render();
</script></body></html>
"""


def main(argv):
    work = Path(argv[1])
    data = json.loads((work / "trips.json").read_text())
    trips = [compact(t) for t in data["trips"] if t["label"] != "hors_idf"]
    (work / "review.html").write_text(PAGE.replace("__DATA__", json.dumps(trips, ensure_ascii=False)), encoding="utf-8")
    print(f"review.html : {len(trips)} trajets ({sum(1 for t in trips if t['label'] == 'velo')} proposés vélo)")


if __name__ == "__main__":
    main(sys.argv)
