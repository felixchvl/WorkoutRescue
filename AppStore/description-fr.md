# App Store — Français (fr-FR)

**Nom :** WorkoutRescue
**Sous-titre (≤ 30) :** Exportez séances et tracés GPS
**Texte promotionnel (≤ 170) :** Exportez les données d'entraînement de votre Apple Watch.

## Description

WorkoutRescue crée une copie personnelle des entraînements enregistrés sur votre Apple Watch, directement depuis la montre, sans iPhone.

L'app lit vos entraînements dans Apple Santé (HealthKit) en lecture seule, y compris les itinéraires GPS et les mesures d'entraînement, et envoie une archive complète vers un serveur HTTPS que vous contrôlez.

CE QUI EST EXPORTÉ
• Détails de l'entraînement : activité, dates, durée, distance, énergie, appareil source, métadonnées, tours et pauses
• Itinéraires GPS complets : chaque point avec horodatage, latitude, longitude, altitude, précision, vitesse et cap, sans lissage ni simplification
• Séries mesurées pendant l'entraînement lorsqu'elles existent : fréquence cardiaque, distance, vitesse, puissance et cadence vélo, mesures de course, énergie
• Une archive JSON versionnée (l'enregistrement complet) et une trace GPX 1.1 standard pour les logiciels de cartographie

FONCTIONNEMENT
• Fonctionne de manière autonome sur Apple Watch, sans app iPhone compagnon
• Liste des entraînements du plus récent au plus ancien, consultation avant export
• Export d'un entraînement ou de tous ; les entraînements déjà confirmés sont ignorés
• Un transfert n'est considéré comme réussi que lorsque votre serveur confirme la même empreinte SHA-256
• Fonctionne avec le récepteur WorkoutRescue, un petit programme Python à lancer sur votre ordinateur ou votre serveur

CONFIDENTIALITÉ
• Accès à Apple Santé en lecture seule : WorkoutRescue n'écrit, ne modifie et ne supprime jamais de données Santé
• Pas de compte, pas de publicité, pas de pistage, pas d'analytique
• Les données ne quittent la montre que lorsque vous touchez Exporter, et uniquement vers l'adresse de serveur que vous avez saisie
• Le jeton de votre serveur est conservé dans le trousseau de la montre

CONFIGURATION REQUISE
• Apple Watch sous watchOS 26 ou version ultérieure, avec accès Internet Wi-Fi ou cellulaire
• Un point d'accès HTTPS que vous gérez (par exemple le récepteur WorkoutRescue derrière votre propre domaine)
• Un mode Démo avec des entraînements fictifs clairement signalés permet d'essayer l'app sans données Santé
