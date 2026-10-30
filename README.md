# Moka

<p align="center"><img src="docs/moka.png" width="360" alt="Moka : maintien éveillé, capot fermé et seuil de batterie"></p>

Version **1.0.0** · [Téléchargements](https://github.com/theoduvivier/Moka/releases/latest).

Une application native dans la barre des menus, avec trois commandes :

- **Garder le Mac éveillé** : les tâches peuvent continuer, l’écran peut s’éteindre normalement. **Arrêter la session** libère la protection de Moka. Le bouton affiche le temps écoulé.
- **Aussi capot fermé** : continue en refermant le Mac. Le service demande une autorisation administrateur à sa première installation ; les activations suivantes n’en demandent pas.
- **Seuil de batterie** : arrêt automatique entre 5 et 50 %, par pas de 5 %. Sur secteur, ce seuil ne s’applique pas. Recharger ne relance jamais une session automatiquement.

## Usage et autonomie

Moka empêche la veille globale ; il ne choisit pas quelles applications ont le droit de travailler. Claude Code, VS Code, Codex et Chrome restent soumis à leur propre comportement en arrière-plan, aux demandes de validation et à la connexion réseau. Moka ne suspend pas de force d’autres applications et ne garantit pas la poursuite d’un onglet que son navigateur met au repos.

L’écran n’est pas maintenu allumé. Aucun minuteur de surveillance ne tourne lorsque Moka est arrêté et son panneau fermé. En session, les contrôles ont lieu toutes les cinq secondes en arrière-plan ; le compteur ne se rafraîchit chaque seconde que lorsque le panneau est visible. Le service capot n’a pas de minuteur actif au repos. Aucune animation ne tourne en boucle.

Pour économiser davantage, utiliser le [mode économie d’énergie de macOS](https://support.apple.com/fr-fr/101613) sur batterie ; les calculs peuvent être plus lents. Moka ne change pas ce réglage sans votre accord.

**Ne pas maintenir un Mac actif dans un sac fermé.** Un écran éteint n’empêche pas le processeur de chauffer. Utiliser une surface dure et ventilée. Moka et son service arrêtent leur protection lorsque macOS signale un état thermique sérieux ou critique ; ce mécanisme n’est pas une garantie contre la surchauffe. Pour les tâches pendant le transport, utiliser une machine distante et laisser le portable dormir.

## Mode capot et autorisation

La session ordinaire utilise IOKit `PreventUserIdleSystemSleep`, équivalent à `caffeinate -i`, sans privilèges administrateur. Le capot utilise temporairement le réglage global `pmset disablesleep`.

À la première activation du capot, un dialogue macOS autorise l’installation d’un service `launchd`. Aucun mot de passe n’est lu ou conservé par Moka. Ensuite, les boutons communiquent avec ce service par XPC, sans lancer de script administrateur à chaque session. Une nouvelle autorisation peut être nécessaire après une mise à jour, notamment avec les builds ad hoc dont l’identité change à chaque compilation.

Le service ne reçoit que quatre opérations : commencer, renouveler avec un seuil de 5 à 50 %, arrêter et lire l’état. Il n’accepte aucun chemin ni aucune commande à exécuter. Il vérifie l’utilisateur et l’identité signée de l’application ; Moka vérifie également celle du service. Les binaires et la configuration du service appartiennent à root et ne sont pas modifiables par un utilisateur standard.

Avant d’activer le mode, le service enregistre le réglage initial. Il le restaure à l’arrêt, à la déconnexion de Moka, si la surveillance est interrompue pendant 25 secondes, au seuil batterie, en cas de forte chaleur ou après quatre heures. Il récupère également un journal laissé par un arrêt brutal du service. Une restauration échouée reste visible et fait l’objet de nouvelles tentatives. Le réglage de veille est contrôlé toutes les 30 secondes ; les changements externes réautorisant la veille sont respectés.

**Si la veille était déjà désactivée avant Moka, cette valeur est conservée.** Le panneau le signale : libérer la protection de Moka ne suffit alors pas à rétablir la veille. Les assertions d’autres applications sont également conservées. Le comportement physique du capot doit être vérifié sur chaque modèle ; les tests automatisés ne le prouvent pas.

Fichiers du service :

- `/Library/PrivilegedHelperTools/fr.local.moka.helper`
- `/Library/LaunchDaemons/fr.local.moka.helper.plist`
- `/Library/Application Support/Moka/helper.plist` et, pendant une session, `session.plist`.

Pour retirer le service, quitter Moka puis exécuter `sudo zsh Tools/uninstall-helper.sh` depuis les sources. Le script attend la restauration avant suppression ; si elle échoue, il conserve le service pour permettre une nouvelle tentative. Supprimer seulement Moka.app ne désinstalle pas ce service.

## Interface et technologie

Swift, SwiftUI, AppKit, IOKit, Security et NSXPCConnection. Aucune dépendance tierce, aucun serveur et aucun accès réseau. Binaire universel Apple Silicon + Intel, macOS 13 minimum. Liquid Glass à partir de macOS 26 ; fond translucide sur les versions précédentes. Vérifications réelles sur Apple Silicon avec macOS 27.2 ; les autres configurations ne sont pas validées sur matériel.

Le personnage ouvre les yeux pendant la session. Point vert : maintien éveillé ordinaire. Ligne rouge : capot actif, restauration en cours ou non confirmée. Un deuxième clic sur l’icône referme le panneau. Option-clic active ou arrête la session. Les animations respectent Réduire les animations. Le panneau de 360 × 470 points s’adapte à la hauteur disponible avec défilement.

## Construire et tester

Prérequis : macOS et les outils en ligne de commande Xcode avec un SDK macOS 26 ou ultérieur.

```sh
git clone https://github.com/theoduvivier/Moka.git
cd Moka
./build.sh
./run-tests.sh
```

L’application est créée dans `build/Moka.app`. **100 vérifications automatisées** couvrent les assertions IOKit réelles, l’arrêt sur batterie et chaleur, les transitions d’interface, les erreurs de restauration, les journaux, les sessions concurrentes, la perte de connexion, les autorisations tardives, la commande de vérification de l’installateur et le refus de signatures XPC incorrectes. Les tests XPC nécessitent un environnement macOS non bloqué par un sandbox de développement. Aucun test n’écrit dans les réglages `pmset` ni n’ouvre un dialogue administrateur.

Validation locale du 30 octobre 2026 : service installé avec autorisation macOS, deux activations consécutives sans nouvelle demande de mot de passe, `SleepDisabled` passant de 0 à 1 à l’activation puis revenant à 0 à l’arrêt. La restauration a aussi été vérifiée en quittant Moka avec le capot actif ; un relancement laisse la session arrêtée. La fermeture physique du capot et l’autonomie sur longue durée restent à vérifier sur chaque modèle.

## Partager et avertissement macOS

Envoyer `Moka-macOS.zip`. Le destinataire le décompresse, place Moka dans Applications et l’ouvre. Le ZIP ne contient ni réglage personnel, ni certificat privé, ni mot de passe. Le dépôt est privé : seuls les collaborateurs autorisés peuvent télécharger directement depuis GitHub ; le ZIP peut être envoyé séparément.

**Cette version a une signature locale ad hoc, sans Developer ID et sans notarisation Apple.** Un avertissement ou un blocage Gatekeeper sur une copie téléchargée est donc attendu. Pour une application dont l’origine est connue, Apple documente l’ouverture via [Réglages Système → Confidentialité et sécurité → Ouvrir quand même](https://support.apple.com/fr-fr/102445). Ne pas désactiver Gatekeeper globalement. Le service privilégié de la copie téléchargée doit également être validé sur le Mac destinataire.

Pour supprimer l’avertissement « développeur non vérifié », il faut un abonnement Apple Developer, un certificat **Developer ID Application**, puis la [notarisation Apple](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Une confirmation normale de première ouverture d’une application téléchargée peut subsister.

Le parcours de distribution est prêt :

```sh
MOKA_SIGN_IDENTITY='Developer ID Application: Votre nom (TEAMID)' \
MOKA_NOTARY_PROFILE='votre-profil-notarytool' ./distribute.sh
```

Il signe le service puis l’application avec Hardened Runtime, soumet l’archive à Apple, vérifie l’acceptation, agrafe le ticket, évalue Gatekeeper et produit un ZIP avec SHA-256. Il s’arrête sans certificat ou identifiants, sans retirer la quarantaine. Ne jamais versionner les clés privées ou identifiants Apple.

La release 3.0.1 était un prototype ; 1.0.0 est la première version numérotée de Moka.
