#!/usr/bin/env python3
"""Local page comparing raw Arc tracks with their map-matched repair (compare.html).
One card per bike trip, sorted by how much was changed; choice "Corrigé / Brut" per trip,
exported with "Télécharger mes choix" (validation-recalage.json).

Usage: python3 make_compare_page.py WORK_DIR
"""
import json
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

PARIS = ZoneInfo("Europe/Paris")
DAYS = ["lun.", "mar.", "mer.", "jeu.", "ven.", "sam.", "dim."]


def thin(points, keep=800):
    step = max(1, len(points) // keep)
    return points[::step] + ([points[-1]] if points and (len(points) - 1) % step else [])


def main(argv):
    work = Path(argv[1])
    trips = {t["id"]: t for t in json.loads((work / "trips.json").read_text())["trips"]}
    cards = []
    for m in json.loads((work / "matched.json").read_text())["trips"]:
        raw = [[round(p["lat"], 6), round(p["lon"], 6)] for p in thin(trips[m["id"]]["points"]) if p["hacc"] and p["hacc"] <= 200]
        rep = [[round(p["lat"], 6), round(p["lon"], 6), {"raw": 0, "snapped": 1, "interpolated": 2}[p["src"]]] for p in thin(m["points"])]
        changed = (m.get("snapped", 0) + m.get("interpolated", 0) + m.get("dropped_outliers", 0)) if m["status"] == "ok" else 0
        total = (m.get("raw", 0) + m.get("snapped", 0) + m.get("dropped_outliers", 0)) or 1
        t0 = datetime.fromisoformat(m["start"]).astimezone(PARIS)
        t1 = datetime.fromisoformat(m["end"]).astimezone(PARIS)
        cards.append({
            "id": m["id"], "title": f"{DAYS[t0.weekday()]} {t0:%d/%m} · {t0:%H:%M}–{t1:%H:%M}", "status": m["status"],
            "conf": round(m.get("confidence", 0), 2), "share": round(changed / total * 100), "snapped": m.get("snapped", 0),
            "interp": m.get("interpolated", 0), "dropped": m.get("dropped_outliers", 0),
            "km_raw": round(m.get("distance_raw_m", 0) / 1000, 2), "km_rep": round(m.get("distance_repaired_m", 0) / 1000, 2),
            "watch": bool(m["watch_overlap"]), "raw": raw, "rep": rep,
        })
    cards.sort(key=lambda c: -c["share"])
    page = (work / "review.html").read_text()  # reuse styles/libraries of the first page
    head = page[:page.index("<header>")].replace("Trajets à valider", "Recalage à vérifier")
    body = """<header><h1>Recalage à vérifier</h1><span class="count" id="count"></span>
<button class="primary" id="dl">Télécharger mes choix</button>
<span class="legend">gris = brut Arc · <b style="background:#1565c0"></b>corrigé · <b style="background:#ef6c00"></b>point recalé · <b style="background:#8e24aa"></b>trou comblé</span></header>
<main><div class="grid" id="grid"></div></main>
<script>
const CARDS = __DATA__;
let choices = {}; try { choices = JSON.parse(localStorage.getItem("recalage") || "{}"); } catch (e) {}
for (const c of CARDS) if (!(c.id in choices)) choices[c.id] = c.status === "ok" ? "corrige" : "brut";
const save = () => { try { localStorage.setItem("recalage", JSON.stringify(choices)); } catch (e) {} };
const grid = document.getElementById("grid");
const obs = new IntersectionObserver(es => { for (const e of es) if (e.isIntersecting && !e.target.dataset.map) { e.target.dataset.map = 1; draw(e.target); } }, {rootMargin:"300px"});
for (const c of CARDS) {
  const el = document.createElement("div"); el.className = "card"; el.dataset.id = c.id;
  const info = c.status === "ok" ? `${c.share} % de points modifiés · ${c.snapped} recalés · ${c.interp} ajoutés · ${c.dropped} aberrants retirés · confiance ${c.conf}`
                                 : "Recalage non fiable : tracé brut conservé";
  el.innerHTML = `<div class="map"></div><div class="body"><div class="title">${c.title}</div>
    <div class="meta">${c.km_raw} km brut → ${c.km_rep} km corrigé</div><div class="reason">${info}</div>
    ${c.watch ? '<div class="watch">⌚ Séance montre sans tracé</div>' : ""}
    <div class="choices">${[["corrige","Corrigé"],["brut","Brut"]].map(([v,l]) =>
      `<label><input type="radio" name="${c.id}" value="${v}" ${choices[c.id]===v?"checked":""} ${c.status!=="ok"&&v==="corrige"?"disabled":""}><span>${l}</span></label>`).join("")}</div></div>`;
  el.querySelectorAll("input").forEach(i => i.addEventListener("change", () => { choices[c.id] = i.value; save(); count(); }));
  grid.append(el); obs.observe(el);
}
function draw(el) {
  const c = CARDS.find(x => x.id === el.dataset.id); const m = L.map(el.querySelector(".map"), {zoomControl:false});
  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {maxZoom:19, attribution:"© OpenStreetMap"}).addTo(m);
  L.polyline(c.raw, {color:"#9e9e9e", weight:3, dashArray:"4 4"}).addTo(m);
  L.polyline(c.rep.map(p => [p[0], p[1]]), {color:"#1565c0", weight:3}).addTo(m);
  for (const p of c.rep) if (p[2]) L.circleMarker([p[0], p[1]], {radius:2.5, color:p[2] === 1 ? "#ef6c00" : "#8e24aa", fillOpacity:1, weight:0}).addTo(m);
  m.fitBounds(L.latLngBounds(c.raw.concat(c.rep.map(p => [p[0], p[1]]))), {padding:[12,12]});
}
function count() { const n = Object.values(choices).filter(v => v === "corrige").length;
  document.getElementById("count").textContent = `${CARDS.length} trajets · ${n} en version corrigée`; }
document.getElementById("dl").addEventListener("click", () => {
  const blob = new Blob([JSON.stringify({generated: new Date().toISOString(), choices}, null, 1)], {type:"application/json"});
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "validation-recalage.json"; a.click(); });
count();
</script></body></html>"""
    (work / "compare.html").write_text(head + body.replace("__DATA__", json.dumps(cards)), encoding="utf-8")
    print(f"compare.html : {len(cards)} trajets, {sum(c['share'] >= 10 for c in cards)} avec au moins 10 % de points modifiés")


if __name__ == "__main__":
    main(sys.argv)
