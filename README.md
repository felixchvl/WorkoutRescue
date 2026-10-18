# WorkoutRescue

App **Apple Watch indépendante (Watch-only)** pour récupérer les entraînements stockés dans HealthKit sur la montre
(routes GPS, fréquence cardiaque, puissance, cadence, métadonnées…) et les envoyer directement en HTTPS vers un
serveur que tu contrôles — sans iPhone, sans WatchConnectivity.

## Garantie de non-destruction

- HealthKit en **lecture seule** : `requestAuthorization(toShare: [], read: …)`, uniquement des requêtes
  (`HKSampleQueryDescriptor`, `HKWorkoutRouteQueryDescriptor`, `HKQuantitySeriesSampleQueryDescriptor`).
  Aucun `save`, `delete`, `HKWorkoutSession`, `HKWorkoutBuilder` dans le code (`grep` le confirme).
- Aucune donnée ne quitte la montre sans un geste explicite (boutons Export), et seulement vers l'adresse saisie.
- Le récepteur n'écrase et ne supprime jamais un fichier.

## Où trouver quoi

| Chemin | Contenu |
|---|---|
| `WorkoutRescue Watch App/Shared/` | code portable (modèle JSON v2, GPX, client HTTPS, pipeline, registre, démo) — compilé dans l'app **et** testé sur macOS |
| `WorkoutRescue Watch App/Core/` | HealthKit (lecture seule), Keychain, journal, état de l'app |
| `WorkoutRescue Watch App/Views/` | écrans SwiftUI watchOS |
| `Tests/WorkoutRescueCoreTests/` | tests XCTest exécutés par `swift test` (macOS) |
| `WorkoutRescue Watch AppTests/` | tests spécifiques watchOS/HealthKit (nécessitent un simulateur watchOS ≥ 26) |
| `receiver/` | serveur de réception Python (stdlib), vérificateur d'intégrité, tests |
| `scripts/` | `test-all.sh`, `e2e.sh`, `make-icon.swift` |
| `docs/` | procédure de récupération, schéma JSON, distribution |
| `AppStore/` | textes FR/EN, mots-clés, politique de confidentialité, notes App Review, checklist |

## Écrans

Dashboard (nombre de workouts, dernier scan, état du récepteur, dernier export) → Workouts (liste du plus récent au
plus ancien : type, date, durée, distance) → Détail (points GPS, échantillons cardiaques, avertissements, Export
Workout / JSON / GPX) · Export All (séquentiel, saute les exports confirmés) · Settings (adresse, token, test de
connexion, mode Démo) · Diagnostics (HealthKit / Export / Réseau).

## Commandes

```bash
./scripts/test-all.sh                       # swift test + tests récepteur + bout en bout
xcodebuild -project WorkoutRescue.xcodeproj -scheme "WorkoutRescue Watch App" \
  -configuration Release -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild archive -project WorkoutRescue.xcodeproj -scheme "WorkoutRescue Watch App" \
  -destination 'generic/platform=watchOS' -archivePath /tmp/WorkoutRescue.xcarchive CODE_SIGNING_ALLOWED=NO
```

`Package.swift` à la racine sert uniquement de banc de test : il compile `WorkoutRescue Watch App/Shared` pour macOS
avec la même isolation par défaut (`MainActor`) que la cible Xcode. Ouvrir explicitement `WorkoutRescue.xcodeproj`.
Le dossier de build SwiftPM doit être hors du dépôt (`--scratch-path`, déjà fait par les scripts) : les attributs
étendus du dossier Documents font échouer la signature ad hoc du bundle de test.

## État de vérification (2026-10-18)

| Élément | Implémenté | Compilé | Testé (macOS / intégration) | Simulateur watchOS | Appareil réel |
|---|---|---|---|---|---|
| Liste des HKWorkout (tri récent → ancien) | ✅ | ✅ | — | ❌ runtime absent | ❌ |
| Routes GPS (tous les lots, contrôle `route.count`) | ✅ | ✅ | logique d'export ✅ ; requête HealthKit non testable hors appareil | ❌ | ❌ |
| Séries temporelles + expansion des séries | ✅ | ✅ | ❌ (HealthKit) | ❌ | ❌ |
| JSON v2 (round-trip, µs, NaN, métadonnées typées) | ✅ | ✅ | ✅ 32 tests unitaires | ❌ | ❌ |
| GPX 1.1 (XML, échappement, multi-routes, points invalides, 30 000 points) | ✅ | ✅ | ✅ | ❌ | ❌ |
| Client HTTPS (401, 500, timeout, coupure, retry, intégrité) | ✅ | ✅ | ✅ (stubs) + ✅ intégration réelle | ❌ | ❌ |
| Récepteur + vérification | ✅ | n/a | ✅ 17 tests API + bout en bout | n/a | n/a |
| UI watchOS | ✅ | ✅ | ❌ | ❌ | ❌ |
| Archive App Store | structure ✅ | ✅ Release | — | — | signature ❌ (compte inactif) |

Le simulateur n'a pas pu être utilisé : seuls les runtimes watchOS 11.0/11.5 sont installés, alors que la cible
minimale est watchOS 26 (le runtime watchOS 26/27, plusieurs Go, n'a pas été téléchargé).

## Limites connues

- Non validé sur appareil : autorisation HealthKit et profondeur réelle de l'historique sur une Watch au jumelage
  cassé ; comportement réseau quand l'écran s'éteint (export au premier plan : garder le poignet levé ; une coupure
  est rattrapée par les retries et la reprise d'Export All).
- Données non exportées en v2 : voir `docs/JSON-SCHEMA.md`.
- Upload en arrière-plan (`URLSession` background) non implémenté.
