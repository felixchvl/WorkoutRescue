# Checklist de publication

Légende : ✅ fait et vérifié · 🔶 préparé, à confirmer · ⬜ à faire (souvent action compte → ton accord requis)

## Technique (local, sans compte)
- ✅ Container Watch-only `com.felixchevalier.WorkoutRescue`, `ITSWatchOnlyContainer`, `LSApplicationLaunchProhibited`
- ✅ Watch app `com.felixchevalier.WorkoutRescue.watchkitapp`, `WKApplication`, `WKWatchOnly`, sans compagnon
- ✅ Deployment target watchOS 26.0 ; binaire `arm64` + `arm64_32` (vérifié avec `lipo`/`otool`)
- ✅ Version 1.0 (1)
- ✅ Entitlement `com.apple.developer.healthkit` ; `NSHealthShareUsageDescription` ; aucune permission d'écriture
- ✅ `ITSAppUsesNonExemptEncryption = NO` (container + Watch)
- ✅ `PrivacyInfo.xcprivacy` (UserDefaults CA92.1, pas de pistage, pas de collecte)
- ✅ Icône 1024×1024 opaque intégrée dans `Assets.car`
- ✅ Build Debug + Release, archive non signée structurellement correcte
- ⬜ Archive **signée** + *Validate App* (nécessite l'équipe payante)

## Compte (après activation — chaque étape avec ton feu vert)
- ⬜ Remplacer l'équipe personnelle `LJUBJ5GTAT` par l'équipe payante (2 cibles)
- ⬜ App IDs + capacité HealthKit (signature automatique)
- ⬜ Fiche App Store Connect (nom disponible ? bundle ID, SKU)
- ⬜ Upload du build
- ⬜ Captures Watch 410×502 (`AppStore/screenshots/`)
- ⬜ URL politique de confidentialité + URL support publiées (contenu prêt)
- ⬜ Rendre le récepteur téléchargeable par d'autres utilisateurs (ex. dépôt public) si l'app est destinée à d'autres que toi — la description y fait référence
- 🔶 Étiquette de confidentialité : « Data Not Collected » (voir `privacy-nutrition-label.md`)
- ⬜ Classification d'âge, catégorie Health & Fitness, prix gratuit, disponibilité
- 🔶 Notes App Review (`review-notes.md`) — décider si un récepteur de test public est fourni
- ⬜ Soumission (après ton accord) → publication **manuelle**

## Risques App Review identifiés
- 2.1 / 4.2 : l'export exige un serveur de l'utilisateur ; le mode Démo et les notes l'expliquent. Un récepteur de
  test fourni à Apple réduirait le risque de rejet (à décider : cela implique un déploiement public).
- 2.5.1 : HealthKit doit être clairement identifié → « Apple Health » visible dans l'UI et la description.
- 5.1.1 / 5.1.3 : transfert de données de santé vers un serveur → justifié par l'action explicite de l'utilisateur,
  destination choisie par l'utilisateur, politique de confidentialité exacte.
