<p align="center">
  <img src="Pressay/Brand/AppIcon-source.png" width="128" alt="Icône Pressay">
</p>

# Pressay

Une barre de commande vocale contrôlable pour écrire et transformer du texte
depuis n’importe quelle application macOS. Pressay conserve une dictée
universelle rapide, puis ajoute des modes contextuels et des transformations
réversibles sans perdre la cible initiale.

Maintiens **Fn**, parle, relâche : le texte apparaît là où se trouve ton
curseur. Pour transformer du texte, sélectionne-le, appuie sur **⌥⇧Espace**,
dicte l’instruction et valide l’aperçu.

## Comment ça marche ?

1. L'app vit dans ta barre de menu (en haut à droite de ton écran)
2. Tu choisis un mode : Fidèle, Propre, Message, Email, Prompt IA ou un mode
   personnalisé
3. Tu maintiens la touche **Fn**, tu parles, puis tu relâches
4. Pressay transcrit et, si le mode le demande, transforme le texte
5. Le résultat est inséré dans la cible capturée au début de la session

La transformation de sélection suit un parcours plus prudent : Pressay capture
la sélection initiale, affiche Original/Proposition, puis revérifie la cible et
la sélection avant le remplacement. Si elles ont changé, le résultat est copié
au lieu d’être collé au mauvais endroit.

La version publique fonctionne sans compte Pressay. La transcription propose
deux chemins explicites : OpenAI avec une clé API personnelle, ou WhisperKit
entièrement sur le Mac après téléchargement du modèle local. Les modes de
réécriture utilisent uniquement OpenAI ; le mode Fidèle peut donc rester 100 %
local avec WhisperKit.

## Télécharger et installer

Pressay possède deux canaux distincts :

- **Pressay direct** conserve la dictée universelle, l'insertion dans les autres
  apps, les raccourcis globaux et les mises à jour Sparkle ;
- **Pressay Companion pour le Mac App Store** fonctionne dans App Sandbox et
  livre le résultat au presse-papiers et à la Voice Inbox, sans demander
  Accessibilité ni installer un mécanisme de mise à jour externe.

Les détails et la checklist de soumission sont dans
[APP_STORE.md](APP_STORE.md).

### Prérequis

- macOS 14 (Sonoma) ou plus récent
- Une clé API OpenAI ou le modèle WhisperKit téléchargé dans les réglages
- Un Mac Intel ou Apple Silicon

### Étapes

1. Télécharge `Pressay.dmg` depuis la
   [dernière release](https://github.com/YoannDrx/pressay/releases/latest).
2. Ouvre le DMG et glisse **Pressay** dans **Applications**.
3. Lance Pressay depuis Applications.
4. Configure ta clé OpenAI ou télécharge le modèle WhisperKit local.
5. Accorde les permissions **Microphone** et **Accessibilité** demandées par macOS.

La release publique est signée avec un certificat Developer ID, notarialisée par
Apple et distribuée sous la forme d'un binaire universel `arm64 + x86_64`. Tu peux
vérifier le téléchargement avec le fichier `Pressay.dmg.sha256` publié à côté du
DMG.

La page de téléchargement publique est également disponible sur
[yoann-andrieux.fr](https://www.yoann-andrieux.fr/fr/projects/pressay). La
version stable publiée est `v1.2.7` ; les utilisateurs ayant activé le canal
bêta recevront aussi cette version stable.

La stable `v1.2.7` (build `12106`) remplace Clerk par l’identité Pressay
auto-hébergée, conserve Google, ajoute passkeys et TOTP, et sécurise la connexion
macOS avec OAuth 2.1 + PKCE. La version en développement utilise une seule requête
`gpt-4o-mini-transcribe` après le relâchement de Fn, sans session Realtime. La
matrice interapplications, le test Intel réel et sept jours sans P0/P1 restent
des preuves QA à compléter avant la prochaine publication.

### Compiler depuis les sources

1. **Clone le dépôt**
   ```bash
   git clone https://github.com/YoannDrx/pressay.git
   cd pressay
   ```

2. **Ouvre le projet dans Xcode**
   ```bash
   open Pressay.xcodeproj
   ```

3. **Compile et lance** (Cmd + R)

4. **Configure un moteur de transcription**
   - Clique sur l'icône Pressay dans la barre de menu
   - Va dans les réglages
   - Ajoute une clé OpenAI ou télécharge le modèle WhisperKit local

5. **Accorde les permissions**
   - **Microphone** : pour enregistrer ta voix
   - **Accessibilité** : pour coller le texte automatiquement

La variante App Store se construit avec le schéma dédié :

```bash
xcodebuild build \
  -project Pressay.xcodeproj \
  -scheme "Pressay App Store" \
  -destination 'generic/platform=macOS'
```

Une compilation locale nécessite Xcode. Les builds de développement déjà
installées sous les anciens identifiants `com.hyrak.whisper` ou
`fr.yodev.whisper` devront réaccorder une fois les permissions Microphone et
Accessibilité après le passage à `fr.yodev.pressay`. Les préférences, la clé API,
la clé de l'historique chiffré et le dossier `Application Support/Whisper` sont
migrés automatiquement au premier lancement.

## Mises à jour

Pressay utilise Sparkle 2.9.2. L'application propose d'activer la vérification
automatique au second lancement, et le menu contient l'action
**Rechercher les mises à jour…**. Chaque mise à jour est une application complète
dans un DMG notarialisé et signé avec une clé Ed25519 dédiée.

Pressay n'envoie ni profil système ni télémétrie à Yodev. Le flux stable et les
items bêta optionnels partagent l’appcast canonique
`https://yoanndrx.github.io/pressay/appcast.xml`. Les versions bêta sont
désactivées par défaut.

## Lancer Pressay au démarrage du Mac

Pour que Pressay se lance automatiquement quand tu allumes ton Mac :

1. Ouvre **Réglages Système**
2. Va dans **Général** > **Ouverture**
3. Clique sur le **+** en bas de la liste
4. Cherche et sélectionne **Pressay** dans tes Applications
5. C'est bon !

Maintenant Pressay sera toujours prêt à t'écouter dès que tu démarres ton Mac.

## Fonctionnalités

### Transcription instantanée
Maintiens **Fn**, parle, relâche. Le texte apparaît. Simple.

### Historique privé
L'historique est optionnel, chiffré sur le Mac avec AES-256-GCM et peut être
conservé 24 heures, 7 jours ou 30 jours. Il conserve le brut/final et les
métadonnées utiles, permet recherche, filtres, favoris, tags, export Markdown ou
JSON et retraitement dans un autre mode sans écraser l’original.

- Clique sur l'icône dans la barre de menu
- Sélectionne "Historique"
- Clique sur une transcription pour la copier

Il se nettoie automatiquement et sa désactivation efface le fichier local.

### Feedback audio
Un petit son te confirme quand l'enregistrement commence et quand la transcription est prête.

### Protection contre les transcriptions fantômes
L'app mesure le niveau audio localement. Si aucune parole n'est détectée, le fichier n'est pas envoyé à l'API et aucun texte n'est collé.

### Reconnaissance personnalisable
Dans les préférences, tu peux choisir le français, l'anglais ou la détection automatique, puis ajouter les noms propres et acronymes que tu utilises souvent.

### Dictée flexible
Le raccourci peut être Fn/Globe, Option droite ou Commande droite. Le mode
« Maintenir » convient aux messages courts ; le mode « Bascule » permet les longues
dictées sans garder la touche enfoncée. Un HUD discret
indique le niveau micro, la durée, la langue et le mode.

### Annulation et délai maximum
Pressay traite une seule dictée à la fois. L’appel en cours peut être annulé avec
Échap ou depuis le HUD. Les échéances sont appliquées à la phase réellement en
cours : 30 secondes pour une transcription cloud batch, 75 secondes pour le
chargement ou la transcription locale et 45 secondes pour une transformation.
Le temps passé à lire ou confirmer un aperçu cloud n’est pas compté comme un
délai réseau. En cas d’échec, l’audio temporaire est gardé quelques minutes en
mémoire et le HUD propose **Réessayer**. Après une insertion compatible, le HUD
propose aussi une annulation locale pendant quelques secondes.

### Modes contextuels

Pressay inclut douze modes natifs : Fidèle, Propre, Message, Email, Prompt IA,
Note, Compte rendu, Ticket, Commit, Traduction, Résumé et Tâches. L’éditeur de
modes permet de définir un prompt, un format, un niveau de nettoyage et les
sources de contexte autorisées. Une règle par bundle ID peut choisir
automatiquement un mode pour chaque application.

### Transformation de sélection

Le raccourci **⌥⇧Espace** capture la sélection par l’API Accessibilité ou, si
nécessaire, par un `Cmd+C` temporaire dont le presse-papiers est restauré. La
parole est traitée comme l’instruction ; la sélection et le contexte restent des
données passives non fiables. Le remplacement n’a lieu qu’après validation de
l’aperçu et nouvelle vérification de l’élément ciblé.

### Contexte et cloud contrôlés

Chaque mode autorise explicitement ses sources de contexte. Les modes
`cloudAllowed` s’exécutent directement et indiquent le fournisseur ainsi que les
sources utilisées dans le HUD. Les champs sécurisés sont bloqués avant le
démarrage du micro. La politique `askBeforeCloud` exige un choix explicite à
chaque session et affiche le contenu exact avant l’envoi ; l’utilisateur peut
envoyer, annuler ou conserver la transcription brute lorsque ce choix est
compatible avec l’intention.

### Correction vocale et Voice Inbox

Le résultat peut être corrigé à la voix tant que sa cible reste vérifiable. Si
aucun champ éditable n’est disponible, Pressay peut conserver le résultat dans
une Voice Inbox activée explicitement, chiffrée localement et soumise à une
rétention indépendante. Elle structure localement titres, projets, tags, tâches
et dates, propose des vues Aujourd’hui/À traiter/Archivé et prépare des brouillons
de note, rappel ou événement dans un journal chiffré avec aperçu et validation.
Une politique par application permet aussi de choisir
l’injection automatique, l’aperçu, la copie seule ou l’exclusion complète.

### HUD configurable

Le HUD peut être compact ou confortable, placé en haut, en bas ou près du
pointeur. Sa durée de résultat est configurable et une croix permet de le
fermer immédiatement. Le mode peut être changé pendant l’écoute sans voler le
focus de l’application cible.

## Permissions requises

L'app a besoin de ces permissions pour fonctionner :

| Permission | Pourquoi ? |
|------------|-----------|
| **Microphone** | Pour enregistrer ta voix |
| **Accessibilité** | Pour coller le texte automatiquement dans n'importe quelle app |

## OpenAI ou WhisperKit local

Dans les réglages, choisis un seul moteur de transcription :

1. **OpenAI** : colle une clé de projet `sk-…`. Pressay la valide avant de
   l’enregistrer dans le Trousseau macOS. Après détection locale de la voix,
   l’enregistrement est finalisé au relâchement de Fn puis envoyé une seule fois
   à `gpt-4o-mini-transcribe`. Pressay n’ouvre aucune session WebSocket et ne prépare
   aucun second appel en parallèle.
2. **WhisperKit local** : télécharge le modèle Small une seule fois. L’audio et
   la transcription restent ensuite sur le Mac, même hors ligne. Le modèle est
   préchargé à la sélection du moteur et pendant la capture si nécessaire.

Les modes de transformation utilisent OpenAI. Pour une dictée intégralement
locale, utilise WhisperKit avec le mode Fidèle.

**Note** : Le téléchargement de Pressay est gratuit, mais l'utilisation de l'API
d’OpenAI peut être facturée directement par OpenAI. Le modèle WhisperKit est
gratuit mais occupe de l’espace disque.

## Comment ça fonctionne techniquement ?

1. `ShortcutRouter` demande au `SessionCoordinator` de créer une `VoiceSession`.
2. La cible AX, la sélection et les seules sources de contexte autorisées sont
   capturées avant l’enregistrement.
3. L’audio PCM 16 bits, mono, 24 kHz est écrit dans un WAV temporaire et analysé
   localement. Si aucune parole n’est détectée, le fichier est supprimé sans
   appel à OpenAI.
4. Avec OpenAI, le WAV temporaire est envoyé à `gpt-4o-mini-transcribe` dès le
   relâchement de Fn. WhisperKit reste un chemin local séparé, sans fallback
   cloud.
5. Le mode résolu choisit entre restitution fidèle et transformation via la
   Responses API avec `store: false`. Le mode Traduction utilise une langue
   cible explicite ; le traitement accéléré reste une option distincte car son
   coût API peut être supérieur.
6. Une transformation de sélection attend un aperçu éditable.
7. Une dictée simple colle directement si l’application initiale est toujours
   au premier plan ; les transformations conservent la validation AX stricte.
8. Si la cible n’est plus sûre, le texte reste dans le presse-papiers au lieu
   d’être envoyé à la mauvaise application.

Les types de domaine et les frontières de services sont détaillés dans
[ARCHITECTURE.md](ARCHITECTURE.md).

## Confidentialité

- **Audio** : envoyé à OpenAI uniquement si ce moteur est choisi et qu’une voix
  est détectée ; avec WhisperKit, il reste sur le Mac ; le fichier temporaire
  est ensuite supprimé. Après un échec, une copie en mémoire expire après
  quelques minutes pour permettre **Réessayer**
- **Transformation** : le texte et les sources autorisées sont envoyés à OpenAI
  uniquement pour un mode non fidèle ; la requête désactive le stockage de
  réponse avec `store: false`
- **Contexte** : capturé à la demande, limité, jamais surveillé en continu ; les
  sources utilisées sont affichées par Pressay
- **Champs sécurisés** : capture refusée avant l’enregistrement
- **Clé API** : Stockée dans le Keychain macOS (chiffré)
- **Historique** : Optionnel, chiffré localement, rétention configurable
- **Voice Inbox** : Optionnelle, chiffrée séparément et conservée uniquement sur
  le Mac
- **Modes** : enregistrés localement avec des permissions de fichier limitées à
  l’utilisateur
- **Métriques** : Optionnelles et locales ; médiane/p95, phases réseau et
  catégories d’échec, sans URL, audio, texte ni clé
- **Aucune télémétrie distante** : aucune donnée n'est envoyée à l'auteur du projet
- **Mises à jour** : aucun profil système n'est joint aux requêtes Sparkle

Consulte la [politique de confidentialité](PRIVACY.md), le [plan de
test](TESTING.md) et le [guide de distribution](DISTRIBUTION.md).

Pressay par Yodev est une application indépendante utilisant l'API OpenAI. Elle
n'est ni éditée ni approuvée par OpenAI.

## Roadmap

L’état exact du code et la vision produit — moteurs locaux, wedge développeur,
Voice Inbox, mémoire, actions contrôlées, intégrations, Pressay Pro, réunions et
App Intents — sont détaillés dans [ROADMAP.md](ROADMAP.md). Chaque version
possède son propre gate de tests, sécurité, accessibilité, confidentialité et
mise à jour depuis la version publique précédente.

## Contribuer

Les PRs sont les bienvenues ! Si tu trouves un bug ou tu as une idée de feature, ouvre une issue.

## Licence

MIT - Fais-en ce que tu veux !
