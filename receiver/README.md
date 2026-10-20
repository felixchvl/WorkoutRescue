# Récepteur WorkoutRescue

Serveur minimal qui reçoit les exports envoyés **directement par la Watch** (URLSession, HTTPS).
Python ≥ 3.9, **bibliothèque standard uniquement** (aucune dépendance à installer).

## Démarrage local

```bash
cp example.env .env                 # .env est ignoré par git
python3 scripts/gen_token.py        # → WR_TOKEN (ex. 4 groupes de 4 caractères, 80 bits)
./run.sh                            # 127.0.0.1:8787, fichiers dans ./exports
```

Le serveur refuse de démarrer si `WR_TOKEN` fait moins de 10 caractères.

## API

| Méthode | Chemin | Auth | Rôle |
|---|---|---|---|
| GET | `/health` | non | vivant (`{"status":"ok"}`), aucune information |
| GET | `/api/ping` | oui | « Test Connection » de la Watch |
| GET | `/api/workouts` | oui | liste des entraînements reçus |
| POST | `/api/workouts/{uuid}/metadata` | oui | `workout.json` (`application/json`) |
| POST | `/api/workouts/{uuid}/route` | oui | `route.gpx` (`application/gpx+xml`) |

En-têtes d'upload : `Authorization: Bearer <token>`, `X-WorkoutRescue-SHA256: <hex>`, `Content-Length`.

Réponses : `201 stored`, `200 duplicate` (fichier identique déjà présent), `201 stored_revision` (fichier différent
pour le même entraînement : stocké à côté, **rien n'est écrasé**), `400 sha256_mismatch|incomplete_body|invalid_json|uuid_mismatch`,
`401`, `404`, `411`, `413`, `415`, `429` (verrouillage après 10 échecs d'authentification en 10 min), `500`.

## Mode démo-seulement (endpoint pour App Review)

`WR_DEMO_ONLY=1 ./run.sh` (ou `--demo-only`) : le récepteur n'accepte que les entraînements **fictifs** du mode Démo
de l'app (UUID `D3E00000-0000-4000-8000-…` et `isDemoData = true`). Toute autre donnée est refusée en `403
demo_only_receiver` avant d'être écrite : un examinateur peut tester l'export de bout en bout sans qu'aucune vraie
donnée de santé ne puisse arriver chez toi. Utiliser un **autre token** et un **autre dossier** que pour ta récupération.

## Stockage

```
exports/
  receipts.jsonl                 # journal global (date, uuid, type, statut, sha256, taille, client)
  <WORKOUT-UUID>/
    workout.json                 # octets exactement tels que reçus
    route.gpx
    workout.rev-<date>-<sha>.json  # uniquement si un export différent arrive plus tard
    receipts.jsonl
  .incoming/                     # fichiers temporaires (vidés après chaque requête)
```

Écriture : flux vers un fichier temporaire + SHA-256 au fil de l'eau → contrôle de taille et d'empreinte →
`fsync` → publication atomique par `os.link` (échoue si la cible existe : impossible d'écraser).
Le serveur ne supprime ni ne modifie jamais un fichier publié. Dossiers créés en `0700`.

## Vérification

```bash
python3 verify.py exports          # recalcule les SHA-256, relit JSON et GPX, signale routes incomplètes
python3 verify.py exports --json   # rapport machine
```

## Sécurité

- Token comparé en temps constant (`hmac.compare_digest`), jamais journalisé ; casse, espaces et tirets ignorés
  pour faciliter la saisie sur la Watch.
- UUID validé et canonisé (`uuid.UUID`) → pas de traversée de répertoire ; type de fichier pris dans une liste fixe.
- Taille maximale (`WR_MAX_BYTES`, 64 Mio par défaut) vérifiée **avant** lecture du corps ; `Content-Length` obligatoire.
- Timeout socket 120 s par connexion (un upload bloqué ne monopolise pas un thread).
- Le contenu des fichiers n'est jamais écrit dans les logs.
- Le serveur écoute en HTTP sur `127.0.0.1` : l'exposition se fait par un proxy/tunnel HTTPS, ou directement en TLS
  (`WR_TLS_CERT` / `WR_TLS_KEY`, TLS ≥ 1.2).
- `http.server` de Python n'est pas conçu pour une exposition permanente : ce récepteur est prévu pour la durée
  de la récupération, puis arrêté.

## Exposer en HTTPS (aucune de ces options n'a été activée)

**Tailscale Funnel** (Tailscale est installé sur le Mac) : `tailscale funnel 8787`, puis arrêter avec
`tailscale funnel 8787 off` (ou `Ctrl-C` en mode premier plan). Funnel doit être autorisé dans la politique de la tailnet.

**Cloudflare quick tunnel** : `cloudflared tunnel --url http://127.0.0.1:8787` (installation de `cloudflared` requise).

**VPS + Caddy** (`/etc/caddy/Caddyfile`) :

```
rescue.example.org {
    request_body {
        max_size 64MB
    }
    reverse_proxy 127.0.0.1:8787
}
```

Derrière un proxy, toutes les requêtes semblent venir de `127.0.0.1` : le verrouillage anti-force-brute devient
global (un attaquant peut bloquer l'accès 10 min ; il suffit alors de redémarrer le récepteur).

## Tests

```bash
python3 -m unittest discover -s tests -v     # 18 tests API
../scripts/e2e.sh                            # client Swift réel → serveur → verify.py
```
