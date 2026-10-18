# Distribution — signature et App Store

État au 2026-10-18 : **rien n'a été signé, envoyé ni publié.** Aucune action n'a été faite sur le compte Apple.

## Voie retenue : App Store public, installation depuis l'App Store de la Watch

- Architecture : container `com.felixchevalier.WorkoutRescue` (`watchapp2-container`, sans exécutable iOS,
  `ITSWatchOnlyContainer = true`, `LSApplicationLaunchProhibited = true`) qui embarque
  `Watch/WorkoutRescue Watch App.app` (`com.felixchevalier.WorkoutRescue.watchkitapp`, `WKApplication`,
  `WKWatchOnly = true`, pas de `WKCompanionAppBundleIdentifier`, minOS watchOS 26.0, `arm64` + `arm64_32`).
- **TestFlight n'est pas une voie démontrée** pour cette Watch : la procédure Apple pour tester une app watchOS
  passe par l'app TestFlight installée sur l'**iPhone jumelé** (y compris pour les apps « Apple Watch only »).
  Avec un jumelage cassé, rien ne prouve qu'une installation TestFlight soit possible. À ne pas considérer comme
  plus rapide.
- L'installation directe depuis Xcode sur la Watch physique est exclue (consigne de non-modification, et elle
  exige de toute façon un appareil appairé pour le développement).
- Conséquence : il faut passer App Review (délai typique de 24 à 48 h, non garanti). Choisir la **publication
  manuelle** pour garder la main sur la mise en ligne.

## Points d'attention avant la signature

1. **Équipe** : le projet référence `DEVELOPMENT_TEAM = LJUBJ5GTAT`, qui est l'équipe **personnelle gratuite**
   (« Félix Chevalier (Personal Team) »). Une fois l'abonnement actif, sélectionner l'équipe payante dans
   *Signing & Capabilities* pour les **deux** cibles (`WorkoutRescue` et `WorkoutRescue Watch App`).
2. **Bundle IDs** : ne pas les changer. Si App Store Connect répond qu'un identifiant « n'est pas disponible »
   (enregistré ailleurs), solution de repli : `com.felixchevalier.workoutrescue2` + `…workoutrescue2.watchkitapp`
   (à décider avec toi).
3. **Nom** : « WorkoutRescue » doit être libre sur l'App Store. Replis possibles : « WorkoutRescue Export »,
   « Workout Rescue: GPX Export ».
4. **URL de politique de confidentialité et URL de support** : obligatoires dans App Store Connect. Il faut une
   page publique (ex. GitHub Pages) — à publier seulement avec ton accord. Contenu prêt : `AppStore/privacy-policy.md`.
5. **Container iOS** : `IPHONEOS_DEPLOYMENT_TARGET = 27.0` (valeur du template). Sans impact connu pour une app
   Watch-only, à surveiller si App Store Connect émet un avertissement.

## Procédure le jour où le compte est actif (chaque étape « compte » attend ton feu vert)

1. **Xcode → Settings → Accounts** : vérifier que l'Apple ID apparaît avec l'équipe payante (Team ID ≠ LJUBJ5GTAT).
2. Ouvrir `WorkoutRescue.xcodeproj` → cible **WorkoutRescue Watch App** → *Signing & Capabilities* :
   *Automatically manage signing* ✓, Team = équipe payante. Vérifier que la capacité **HealthKit** est listée
   (entitlement `com.apple.developer.healthkit` déjà présent dans `WorkoutRescue.entitlements`). Pas de
   *Clinical Health Records*, pas de *Background Delivery*.
3. Même chose sur la cible **WorkoutRescue** (container).
4. Archive signée :
   ```bash
   xcodebuild archive -project WorkoutRescue.xcodeproj -scheme "WorkoutRescue Watch App" \
     -destination 'generic/platform=watchOS' -archivePath build/WorkoutRescue.xcarchive \
     -allowProvisioningUpdates DEVELOPMENT_TEAM=<PAID_TEAM_ID>
   ```
   (`-allowProvisioningUpdates` crée les App IDs/profils sur le compte : **action compte**.)
5. Contrôles locaux de l'archive :
   ```bash
   codesign -d --entitlements :- "build/WorkoutRescue.xcarchive/Products/Applications/WorkoutRescue.app/Watch/WorkoutRescue Watch App.app"
   plutil -p "build/WorkoutRescue.xcarchive/Products/Applications/WorkoutRescue.app/Info.plist" | grep -E "ITSWatchOnly|LSApplicationLaunch"
   ```
   L'entitlement doit contenir `com.apple.developer.healthkit = true`.
6. **App Store Connect → Apps → +** : plateforme iOS (une app Watch-only est enregistrée via son container),
   nom, langue principale, bundle ID `com.felixchevalier.WorkoutRescue`, SKU `workoutrescue-001`. *(action compte)*
7. Validation puis envoi : Organizer → *Validate App*, puis *Distribute App → App Store Connect → Upload*.
   En ligne de commande : `docs/ExportOptions-AppStore.plist` (remplacer `PAID_TEAM_ID` ; `destination=export`
   par défaut, passer à `upload` seulement après ton accord). *(action compte)*
8. Métadonnées : textes `AppStore/description-*.md`, `keywords.md`, catégorie **Health & Fitness**
   (secondaire : Utilities), prix gratuit, URL de confidentialité/support, étiquette de confidentialité
   (`AppStore/privacy-nutrition-label.md`), classification d'âge (aucun contenu sensible), captures 410×502
   (Ultra 2) dans `AppStore/screenshots/`.
9. Notes App Review : `AppStore/review-notes.md`.
10. **Soumission à App Review : uniquement après ton autorisation explicite.** Puis publication manuelle.

## Après approbation

Sur la Watch : App Store → rechercher « WorkoutRescue » → Obtenir. Puis suivre `docs/RUNBOOK-RECUPERATION.md`.
Point non vérifiable à l'avance : comportement de l'App Store et de HealthKit sur une Watch dont le jumelage est
cassé. L'installation d'une autre app depuis l'App Store de la Watch a déjà fonctionné (constat utilisateur).
