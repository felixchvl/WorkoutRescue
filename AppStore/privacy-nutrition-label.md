# Étiquette de confidentialité App Store Connect — proposition (à valider par toi)

## Réponse proposée : « Données non collectées » (Data Not Collected)

Définition Apple : « collecter » = transmettre des données hors de l'appareil de façon à ce que **vous (le
développeur) et/ou vos partenaires tiers** puissiez y accéder plus longtemps que nécessaire pour servir la requête
en temps réel. Les données traitées uniquement sur l'appareil ne sont pas collectées.

Pourquoi cette réponse est défendable, d'après l'implémentation réelle :
- l'app n'envoie rien au développeur ni à un tiers : aucun serveur du développeur, aucun SDK, aucune analytique ;
- l'unique transmission va vers l'adresse saisie par l'utilisateur, sur un serveur que l'utilisateur contrôle,
  uniquement après un geste explicite ;
- `PrivacyInfo.xcprivacy` déclare `NSPrivacyTracking = false` et aucun type de donnée collecté.

Limite à connaître : la page Apple ne traite pas explicitement le cas « serveur choisi par l'utilisateur ».
Si un jour le développeur exploite un serveur de réception pour d'autres utilisateurs (ou donne un accès de
démonstration à App Review sur un serveur qu'il opère), il faudra déclarer : *Santé et forme → Santé, Forme* et
*Localisation → Localisation précise*, finalité « Fonctionnalité de l'app », liées à l'identité : non, pistage : non.

## Questions annexes
- Pistage (ATT) : non.
- Chiffrement : HTTPS standard uniquement → `ITSAppUsesNonExemptEncryption = NO` (déjà dans les Info.plist).
