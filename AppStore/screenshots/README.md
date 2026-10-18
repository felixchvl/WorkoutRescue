# Captures Apple Watch

Format exigé par App Store Connect pour Ultra 2 / Ultra : **410 × 502 px**, PNG/JPEG sans transparence,
même taille pour toutes les langues.

`provisional-watchOS11.5/` : captures de **contrôle** prises le 2026-10-18 sur le simulateur Apple Watch Ultra 2
(49 mm) **watchOS 11.5**, avec un build Debug rétro-déployé (minOS 11.0, uniquement pour ce test — le projet
cible watchOS 26.0) et le **mode Démo** (données fictives, étiquetées « DEMO »).
Elles servent de test de fumée de l'interface. **Ne pas les envoyer telles quelles** : l'apparence de watchOS 26
diffère. À refaire sur un simulateur watchOS 26 (runtime à installer via Xcode → Settings → Components) avec
`SIMCTL_CHILD_WR_SCREEN=<écran> xcrun simctl launch …` (voir `ContentView.swift`, routage DEBUG).
