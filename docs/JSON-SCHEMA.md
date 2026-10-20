# Archive JSON WorkoutRescue — schéma v2

Format principal d'archivage (source de vérité). Un fichier `workout.json` par entraînement.
Modèle Swift : `WorkoutRescue Watch App/Shared/WorkoutArchive.swift`.

## Racine

| Clé | Type | Contenu |
|---|---|---|
| `format` | string | toujours `"workoutrescue.workout"` |
| `schemaVersion` | int | `2` (v1 = prototype précédent, jamais exporté) |
| `exportedAt` | date | moment de l'export sur la montre |
| `exporter` | objet | app, version, build, plateforme, version d'OS |
| `isDemoData` | bool | `true` uniquement pour les données fictives du mode démo |
| `workout` | objet | voir ci-dessous |
| `quantityTypes` | tableau | séries temporelles par type HealthKit |
| `routes` | tableau | routes GPS (`HKWorkoutRoute`) avec tous les points |
| `warnings` | tableau de string | problèmes non bloquants rencontrés pendant la lecture |

## `workout`

`uuid`, `activityType {rawValue, name}` (`HKWorkoutActivityType`, vélo = 13), `startDate`, `endDate`,
`durationSeconds`, `totalDistance`, `totalEnergyBurned`, `totalSwimmingStrokeCount`, `totalFlightsClimbed`
(`{value, unit}` ou absent), `source` (nom, bundle id, version, productType, version d'OS de la source),
`device` (`HKDevice` : nom, fabricant, modèle, versions matériel/firmware/logiciel, identifiants),
`metadata` (typées, voir plus bas), `statistics` (agrégats `HKStatistics` : sum/average/minimum/maximum/mostRecent
avec unité — **résumés globaux, pas des séries**), `activities` (`HKWorkoutActivity`, multisport/intervalles),
`events` (`HKWorkoutEvent` : pause, reprise, tour, segment, marqueur…).

## `quantityTypes[]`

`typeIdentifier` (ex. `HKQuantityTypeIdentifierHeartRate`), `unit` (chaîne `HKUnit`, ex. `count/min`, `m`, `W`),
`strategy`, `samples[]`, `error`.

- `strategy = associatedWithWorkout` : échantillons associés au workout (`HKQuery.predicateForObjects(from:)`).
- `strategy = workoutTimeRange` : aucun échantillon associé ; échantillons dont l'intervalle est entièrement
  inclus dans celui du workout, toutes sources confondues.
- Chaque échantillon : `uuid`, `startDate`, `endDate`, `value` (dans `unit`), `count`, source, appareil,
  métadonnées. Si `count > 1` (échantillon « série »), `series[]` contient chaque valeur horodatée lue via
  `HKQuantitySeriesSampleQuery`.
- Types lus : fréquence cardiaque, énergie active/basale, distances vélo/marche-course/natation,
  vitesse/puissance/cadence vélo, FTP vélo, vitesse/puissance/foulée/oscillation verticale/temps de contact course,
  pas, étages, mouvements de nage, effort physique, minutes d'exercice, récupération cardiaque à 1 min,
  score d'effort (saisi et estimé).
- Pour la récupération cardiaque et les scores d'effort (enregistrés après la fin ou rattachés par relation), la
  fenêtre de repli va du début du workout à **fin + 15 min**. Un type absent n'est pas listé ; un type en erreur est
  listé avec `error` et n'empêche jamais l'export du reste.

## `routes[]`

`uuid`, `startDate`, `endDate`, `expectedPointCount` (= `HKWorkoutRoute.count`), `metadata`, `points[]`, `error`,
`association` (`associatedWithWorkout`, ou `workoutTimeRange` si aucune route n'était associée et qu'une route
enregistrée pendant le workout, ±5 min, a été trouvée).
Une route est complète quand `error` est absent et que le nombre de points lus = `expectedPointCount`.

Chaque point conserve les valeurs **brutes** de `CLLocation`, dans l'ordre renvoyé par HealthKit :
`timestamp`, `latitude`, `longitude`, `altitude`, `ellipsoidalAltitude`, `horizontalAccuracy`,
`verticalAccuracy`, `speed`, `speedAccuracy`, `course`, `courseAccuracy`, `floor`.
Les valeurs négatives sont les marqueurs « invalide » de CoreLocation (ex. `speed = -1`) et sont gardées telles
quelles. Aucun lissage, aucune simplification, aucun arrondi.

## Conversions explicites

| Donnée source | Représentation JSON |
|---|---|
| `Date` | chaîne ISO 8601 UTC à la **microseconde** : `2026-09-12T07:30:00.250000Z` (le format `.iso8601` standard de Swift perdrait les fractions de seconde) |
| `Double` non fini | chaînes `"NaN"`, `"Infinity"`, `"-Infinity"` (l'export n'échoue jamais pour ça) |
| `HKQuantity` | `{value, unit}` — l'unité est toujours écrite à côté de la valeur |
| métadonnées `[String: Any]` | `{"type": "string"|"integer"|"double"|"bool"|"date", "value": …}` ; quantités : `{"type":"quantity","value","unit","description"}` ; type inconnu : `{"type":"unsupported","typeName","description"}` |
| `NSNumber` booléen | distingué d'un entier via `CFBooleanGetTypeID` |

## Ce qui n'est PAS exporté (limites assumées)

L'export n'est pas « lossless » pour tout HealthKit. Non couverts en v2 : séries battement-à-battement
(`HKHeartbeatSeriesSample`), ECG, zones, VO₂ max, profondeur/température de l'eau (plongée), types de catégorie,
pièces jointes, et tout type pour lequel l'app ne demande pas de permission. Les métadonnées dont le type n'a pas de
correspondance JSON documentée sont conservées sous forme de description textuelle (`unsupported`).
L'altitude n'existe pas comme type de quantité HealthKit : elle est dans chaque point GPS et dans les métadonnées
(`HKMetadataKeyElevationAscended/Descended`) quand elles existent.
