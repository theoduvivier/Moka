# Moka

<p align="center"><img src="docs/moka.png" width="360" alt="Moka : maintien éveillé, capot fermé et seuil de batterie"></p>

Version **1.1.0** · [Téléchargements](https://github.com/theoduvivier/Moka/releases/latest).

Une application native dans la barre des menus, avec trois commandes :

- **Garder le Mac éveillé** : les tâches peuvent continuer, l’écran peut s’éteindre normalement. **Arrêter la session** libère la protection de Moka. Le bouton affiche le temps écoulé.
- **Aussi capot fermé** : visible uniquement sur les Mac portables, même branchés ou reliés à un écran externe. La présence du capot est détectée via IOKit, indépendamment de l’alimentation. Cette option continue les tâches en refermant le Mac. Le service demande une autorisation administrateur à sa première installation ; les activations suivantes n’en demandent pas.
- **Seuil de batterie** : arrêt automatique entre 5 et 50 %, par pas de 5 %. Sur secteur, ce seuil ne s’applique pas. Recharger ne relance jamais une session automatiquement.

## Usage et autonomie

Moka empêche la veille globale ; il ne choisit pas quelles applications ont le droit de travailler. Claude Code, VS Code, Codex et Chrome restent soumis à leur propre comportement en arrière-plan, aux demandes de validation et à la connexion réseau. Moka ne suspend pas de force d’autres applications et ne garantit pas la poursuite d’un onglet que son navigateur met au repos.

L’écran n’est pas maintenu allumé. Aucun minuteur de surveillance de la batterie ne tourne lorsque Moka est arrêté et son panneau fermé. En session, les contrôles ont lieu toutes les cinq secondes en arrière-plan ; le compteur ne se rafraîchit chaque seconde que lorsque le panneau est visible. Le service capot n’a pas de minuteur actif au repos. Le personnage cligne brièvement des yeux toutes les 5 à 11 secondes, uniquement pendant une session avec le panneau ouvert. Aucun clignement en arrière-plan ni lorsque Réduire les animations est activé.

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

## Désinstaller

Dans le panneau, ouvrir **… → Désinstaller Moka…**. Après confirmation, Moka arrête la session, attend la restauration du réglage de veille, retire le service capot, puis place cette copie de l’application et ses préférences/caches dans la corbeille. Une autorisation macOS est nécessaire si le service administrateur est installé. En cas d’annulation ou d’échec de restauration, l’application est conservée. Une commande Terminal encore en cours bloque la désinstallation ; elle n’est jamais tuée.

Les sources, documents, archives téléchargées, autres copies de l’application et clés de signature sont conservés. Quelques conteneurs temporaires WebKit protégés par macOS peuvent rester vides. La suppression du service est définitive ; une prochaine activation du capot pourra le réinstaller avec une nouvelle autorisation.

Depuis les sources, il reste possible de quitter Moka puis d’exécuter `sudo zsh Tools/uninstall-helper.sh` pour retirer uniquement le service. Le script conserve le journal et le service si la restauration échoue. Supprimer seulement Moka.app ne désinstalle pas le service.

## Interface et technologie

Swift, SwiftUI, AppKit, IOKit, Security et NSXPCConnection. Les mises à jour utilisent Sparkle 2.10.1 et GitHub, sans télémétrie ni serveur Moka. Binaire universel Apple Silicon + Intel, macOS 13 minimum. Liquid Glass à partir de macOS 26 ; fond translucide sur les versions précédentes. Vérifications réelles sur Apple Silicon avec macOS 27.2 ; les autres configurations ne sont pas validées sur matériel.

Le personnage ouvre les yeux pendant la session. Point vert : maintien éveillé ordinaire. Ligne rouge : capot actif, restauration en cours ou non confirmée. Un deuxième clic sur l’icône referme le panneau. Option-clic active ou arrête la session. Les animations respectent Réduire les animations. Le panneau de 360 × 470 points s’adapte à la hauteur disponible avec défilement. Le bouton de session garde la même position entre marche et arrêt. Le menu **…** regroupe les mises à jour, l’accès au Terminal, la désinstallation et Quitter. Aucun panneau de réglages supplémentaire.

Les arrêts sur batterie et surchauffe apparaissent dans le titre principal. Une ligne discrète affiche la baisse de batterie pendant la session, puis sa durée et son bilan à l’arrêt. Il s’agit de la variation de **tout le Mac**, pas de l’énergie consommée par Moka. Aucun bilan de batterie n’est affiché si une recharge, une mesure manquante ou une hausse de la jauge rend la comparaison incertaine. Le bilan reste en mémoire pour la session courante ; aucun historique n’est enregistré.

## Utiliser avec une commande Terminal

Dans **… → Utiliser dans le Terminal…**, cliquer sur **Copier l’accès Terminal**, puis coller dans un Terminal zsh ou bash. Cette fonction reste valable dans ce Terminal et ne modifie aucun fichier de configuration. Installer Moka à son emplacement définitif avant de copier l’accès.

```sh
moka run npm run build
moka run --reserve 20 -- python3 mon_script.py
```

Le Mac reste éveillé jusqu’à la fin de la commande, tandis que l’écran peut s’éteindre. La commande conserve ses arguments, entrées/sorties, signaux et code de sortie. Moka n’active pas le mode capot. Le seuil est lu dans les réglages au démarrage, ou fixé avec `--reserve` entre 5 et 50 %. Au seuil ou en cas de forte chaleur, Moka libère sa protection sans tuer la commande. Une autre session Moka ou une autre application peut toujours maintenir le Mac éveillé.

La protection suit la durée du processus lancé : pour un serveur ou un agent, garder la commande au premier plan plutôt que la faire se détacher en daemon. Plusieurs commandes peuvent fonctionner simultanément, chacune avec sa propre assertion. Elles sont indépendantes de la session du panneau. Si la batterie est déjà au seuil ou si le Mac est trop chaud, Moka refuse de lancer la commande.

## Construire et tester

Prérequis : macOS et les outils en ligne de commande Xcode avec un SDK macOS 26 ou ultérieur. La première compilation télécharge Sparkle depuis sa release officielle et vérifie son SHA-256 épinglé dans `Tools/fetch-sparkle.sh`. Les dépendances téléchargées restent dans `build/`.

```sh
git clone https://github.com/theoduvivier/Moka.git
cd Moka
./build.sh
./run-tests.sh
```

L’application est créée dans `build/Moka.app`. **131 vérifications automatisées** couvrent les assertions IOKit réelles, l’arrêt sur batterie et chaleur, les transitions d’interface, les erreurs de restauration, les journaux, les sessions concurrentes, la perte de connexion, les autorisations tardives, la commande de vérification de l’installateur et le refus de signatures XPC incorrectes. Les nouveaux tests vérifient aussi les bilans de session, les verrous entre commandes et désinstallation, et le script de retrait du service sur un système de fichiers et un launchd simulés. Les tests XPC nécessitent un environnement macOS non bloqué par un sandbox de développement. Aucun test n’écrit dans les réglages `pmset` ni n’ouvre un dialogue administrateur.

Pour vérifier aussi la commande sur le binaire construit :

```sh
python3 Tests/CLIIntegrationTests.py /chemin/vers/Moka.app
```

Le cycle complet de désinstallation peut aussi être exécuté sur une application et des données factices isolées :

```sh
python3 Tests/UninstallerIntegrationTests.py
```

Ces 4 vérifications ne touchent ni l’installation courante, ni son service administrateur. Les éléments factices sont placés dans la corbeille.

Les 15 vérifications Terminal lancent des commandes courtes et contrôlent les entrées/sorties, codes de sortie, signaux et assertions IOKit réelles. Elles n’activent pas le mode capot.

Validation locale du 30 octobre 2026 : service installé avec autorisation macOS, deux activations consécutives sans nouvelle demande de mot de passe, `SleepDisabled` passant de 0 à 1 à l’activation puis revenant à 0 à l’arrêt. La restauration a aussi été vérifiée en quittant Moka avec le capot actif ; un relancement laisse la session arrêtée. La fermeture physique du capot et l’autonomie sur longue durée restent à vérifier sur chaque modèle.

## Partager et avertissement macOS

Envoyer `Moka-macOS.zip` ou le [lien de téléchargement public](https://github.com/theoduvivier/Moka/releases/latest). Le destinataire le décompresse, place Moka dans Applications et l’ouvre. Le ZIP ne contient ni réglage personnel, ni certificat privé, ni mot de passe. Le dépôt et ses releases sont publics.

**Cette version a une signature locale ad hoc, sans Developer ID et sans notarisation Apple.** Un avertissement ou un blocage Gatekeeper sur une copie téléchargée est donc attendu. Pour une application dont l’origine est connue, Apple documente l’ouverture via [Réglages Système → Confidentialité et sécurité → Ouvrir quand même](https://support.apple.com/fr-fr/102445). Ne pas désactiver Gatekeeper globalement. Le service privilégié de la copie téléchargée doit également être validé sur le Mac destinataire.

Pour supprimer l’avertissement « développeur non vérifié », il faut un abonnement Apple Developer, un certificat **Developer ID Application**, puis la [notarisation Apple](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Une confirmation normale de première ouverture d’une application téléchargée peut subsister.

Le parcours de distribution est prêt :

```sh
MOKA_SIGN_IDENTITY='Developer ID Application: Votre nom (TEAMID)' \
MOKA_NOTARY_PROFILE='votre-profil-notarytool' ./distribute.sh
```

Il signe les composants Sparkle, l’assistant de mise à jour, le service puis l’application avec Hardened Runtime, soumet l’archive à Apple, vérifie l’acceptation, agrafe le ticket, évalue Gatekeeper et produit un ZIP avec SHA-256. Il s’arrête sans certificat ou identifiants, sans retirer la quarantaine. Ne jamais versionner les clés privées ou identifiants Apple.

## Mises à jour intégrées

Pour une version antérieure à **1.0.2**, installer la version actuelle une première fois manuellement : ces anciennes versions ne possèdent pas le moteur de mise à jour. Ensuite, Moka recherche une nouvelle version une fois par jour au repos. Une session en cours reporte la recherche automatique jusqu’à son arrêt. Dans le panneau, **… → Rechercher les mises à jour…** (ou clic droit sur l’icône) pour une recherche immédiate, ou **Rechercher automatiquement** pour activer/désactiver les recherches quotidiennes.

Sparkle affiche la version disponible. L’utilisateur choisit de l’installer ; Moka quitte proprement, restaure son réglage de veille si nécessaire, puis se relance sans redémarrer de session. Le téléchargement et l’installation ne sont pas forcés. Une recherche manuelle peut être faite en session ; choisir d’installer termine celle-ci.

Le flux `updates/appcast.xml` et chaque archive sont signés avec Ed25519. Sparkle vérifie le flux et la signature de l’archive avant extraction. La clé privée reste dans le trousseau macOS du mainteneur, compte `fr.local.moka.updates`. Seule la clé publique figure dans l’application. Conserver une sauvegarde sécurisée de cette clé hors du dépôt pour publier les futures mises à jour.

L’assistant Sparkle est un processus séparé, sans privilèges administrateur et sans accès au service capot. Dans les builds ad hoc, lui seul est compilé sans Hardened Runtime pour pouvoir charger le framework tiers. **Moka et son service conservent Hardened Runtime et Library Validation.** Les outils internes Sparkle gardent leurs signatures officielles. Avec un Developer ID, tous les composants sont signés avec Hardened Runtime. La signature des mises à jour ne remplace pas la notarisation Apple ; l’avertissement de première ouverture et une éventuelle réautorisation du service après mise à jour restent possibles.

Pour préparer une prochaine release, incrémenter la version `1.x.y` et le numéro de build dans les deux fichiers Info.plist, puis :

```sh
./Tools/package-update.sh
```

Le script construit un ZIP, vérifie sa signature après extraction et génère un appcast signé dans `build/release/`. Avec `MOKA_SIGN_IDENTITY` et `MOKA_NOTARY_PROFILE`, il utilise également la notarisation. Publier d’abord ce ZIP et son SHA-256 dans la release `v1.x.y`, puis copier l’appcast signé dans `updates/appcast.xml` et pousser le commit. Ne jamais modifier un appcast après signature. Le script ne publie rien automatiquement.

Validation 1.1.0 : panneau vérifié au repos, en session et après arrêt, position du bouton stable, confirmation de désinstallation annulable, assertions Terminal et cycle de désinstallation validés. Le retrait du service administrateur est testé avec launchd simulé ; aucune installation active n’est modifiée par ces essais.

Validation 1.0.2 : détection de version par Sparkle, refus d’un flux modifié, refus d’une archive modifiée, installation et relancement réels depuis un flux local signé. La distribution notarisée et le matériel Intel restent à valider lorsqu’un certificat et une machine sont disponibles.

La numérotation de Moka commence à 1.0.0.
