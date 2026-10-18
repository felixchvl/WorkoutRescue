# Procédure de récupération — le jour J

> **Règle absolue : ne pas réinitialiser, ne pas désjumeler, ne pas effacer la Watch tant que l'étape 8 n'est
> pas validée.** WorkoutRescue lit HealthKit en lecture seule ; il ne supprime rien et ne modifie rien.

## 0. Pré-requis (à vérifier sans rien modifier)

- La Watch a accès à Internet par elle-même : réseau Wi-Fi déjà connu (icône Wi-Fi dans le Centre de contrôle)
  ou cellulaire actif. Rejoindre un nouveau réseau Wi-Fi depuis Réglages est possible mais c'est **ta** décision.
- La Watch est chargée (> 50 %) et le restera pendant l'export.
- WorkoutRescue est installé depuis l'App Store **de la montre** (voir `docs/DISTRIBUTION.md`).

## 1. Démarrer le récepteur sur le Mac

```bash
cd receiver
cp example.env .env
python3 scripts/gen_token.py        # copier la valeur dans WR_TOKEN de .env
./run.sh                             # écoute sur 127.0.0.1:8787, stocke dans receiver/exports
```

Vérifier : `curl -s http://127.0.0.1:8787/health` → `{"status": "ok"}`.

## 2. Exposer le récepteur en HTTPS (la Watch n'accepte que HTTPS avec un certificat valide)

Un `localhost` du Mac n'est **pas** joignable depuis la Watch. Choisir **une** option (aucune n'a été activée) :

| Option | Commande / action | Remarques |
|---|---|---|
| Tailscale Funnel (Tailscale est déjà installé sur ce Mac) | `tailscale funnel 8787` | URL publique `https://<machine>.<tailnet>.ts.net` ; Funnel doit être autorisé dans la tailnet. La Watch n'a pas besoin de Tailscale. |
| Cloudflare quick tunnel | `brew install cloudflared` puis `cloudflared tunnel --url http://127.0.0.1:8787` | URL aléatoire `https://xxx.trycloudflare.com` (longue à taper). Service tiers. |
| Serveur personnel (VPS) + Caddy | `reverse_proxy 127.0.0.1:8787` dans le Caddyfile | Certificat Let's Encrypt automatique. Voir `receiver/README.md`. |

Ces options **publient une URL sur Internet** : elle est protégée par le token (verrouillage après 10 échecs),
mais ne l'ouvre que pendant la récupération et ferme-la ensuite.

Test depuis le Mac (remplacer URL et TOKEN) :

```bash
curl -s https://URL/health
curl -s -H "Authorization: Bearer TOKEN" https://URL/api/ping
```

## 3. Sur la Watch : autoriser Santé

1. Ouvrir WorkoutRescue → **Allow Health Access**.
2. Dans la feuille système, activer **tous** les types (Entraînements, Itinéraires, Fréquence cardiaque, etc.).
3. L'app lance un scan. HealthKit ne dit jamais si une lecture a été refusée : si 0 entraînement apparaît,
   vérifier les accès Santé de WorkoutRescue dans l'app Réglages de la Watch, puis **Scan Workouts**.

## 4. Configurer le récepteur

**Settings** → saisir l'adresse (sans `https://`, ajouté automatiquement) → saisir le token (tirets et
majuscules facultatifs) → **Save** → **Test Connection** → statut `OK`.
Le token est stocké dans le trousseau de la Watch (cet appareil uniquement).

## 5. Exporter une sortie test

**Workouts** → ouvrir une sortie vélo → attendre « Data read » → vérifier *GPS points* et *Heart rate samples*
→ **Export Workout** → attendre `✅ JSON confirmed · GPX confirmed`.
Garder l'écran allumé (poignet levé) tant que le ✅ n'est pas affiché. Un export n'est considéré comme réussi que
si le serveur a confirmé le même SHA-256 et la même taille.

## 6. Tout exporter

**Export All** → **Send All to Receiver**. Traitement séquentiel : lecture d'un entraînement, envoi, libération,
puis le suivant. En cas de coupure, relancer : les entraînements déjà confirmés sont sautés (option
*Skip confirmed*), et le serveur reconnaît les fichiers identiques (`duplicate`) sans rien écraser.

## 7. Vérifier sur le Mac

```bash
python3 receiver/verify.py receiver/exports
```

Chaque ligne doit être `OK`. Comparer le nombre d'entraînements et de points GPS avec l'écran de la Watch.
Une route `incomplete` est signalée explicitement. Ouvrir quelques `route.gpx` dans un logiciel local de
visualisation pour contrôle visuel.

## 8. Sauvegarder avant toute autre action

```bash
cd receiver && tar czf ~/WorkoutRescue-exports-$(date +%Y%m%d).tgz exports
shasum -a 256 ~/WorkoutRescue-exports-*.tgz
```

Copier l'archive sur **deux** supports distincts (ex. disque externe + un autre ordinateur), vérifier la somme
SHA-256 sur chaque copie. Arrêter le tunnel et le récepteur (`Ctrl-C`), puis **Forget Token** sur la Watch.

## 9. Seulement ensuite

Envisager le rejumelage/réinitialisation de la Watch. C'est ta décision, hors du périmètre de l'app.
