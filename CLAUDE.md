# Pilote — passation pour la prochaine session Claude

Créé le 2026-10-21. App iPhone native + agent macOS pour piloter le Mac de
l'utilisateur. `README.md` documente l'usage (installation, config, sécurité) ;
ce fichier-ci donne l'état, les raisons et les pièges, sans répéter le README.

## Langue et posture

Répondre en **français**, ton pro et concis. Ne rien inventer : sur une API
Apple dont on n'est pas sûr, le dire et le vérifier par la compilation plutôt
que d'affirmer. Signaler les erreurs de l'utilisateur sans complaisance.

## État au 2026-10-21

**Écrit sans compilateur.** La session qui a produit le code tournait dans un
conteneur Linux sans Xcode. La seule vérification possible est la **CI GitHub**
(runner macOS) : `.github/workflows/build.yml` génère le projet, lance les tests
du code partagé et compile les deux apps. Tant que la CI n'est pas verte, rien
n'est vérifié.

Une relecture par un second agent (sans compilateur non plus) a été faite avant
le premier envoi ; ses corrections sont intégrées (capture orpheline, cycle de
rétention, ping, isolement de `.refreshable`, versions dans l'Info.plist…).

**Jamais exécuté sur un vrai Mac ni un vrai iPhone.** Tout ce qui suit reste à
confirmer sur l'appareil : injection clavier/souris, verrouillage ⌃⌘Q, touches
multimédia, capture d'écran, `tailscale serve` sur le Mac, presse-papiers
universel pour le jeton.

Demande d'origine : « une app sur iPhone pour contrôler mon Mac ». Choix faits
par l'utilisateur au départ : **actions rapides + bureau à distance + état du
Mac**, **app iOS native en Swift**, **projet séparé** de `maison-supervision`.

## Architecture et pourquoi

- **Un projet XcodeGen, trois cibles** (`Pilote` iOS, `PiloteAgent` macOS,
  `PiloteTests`). `project.yml` fait foi, le `.xcodeproj` n'est pas versionné :
  un `.pbxproj` écrit à la main sans Xcode pour le valider aurait été un pari.
- **Agent = vraie app (.app) de barre des menus, pas un binaire en ligne de
  commande.** macOS rattache les autorisations Accessibilité et Enregistrement de
  l'écran à la signature : un binaire ad hoc les perdrait à chaque recompilation.
  `LSUIElement` = pas d'icône dans le Dock. Hors bac à sable (`ENABLE_APP_SANDBOX
  = NO`) : sandboxé, il ne pourrait ni injecter d'événements ni lancer `pmset`.
- **Network.framework des deux côtés** (`Shared/Channel.swift`), pas URLSession :
  un seul code client/serveur, et ATS ne s'applique pas — `ws://` direct vers
  l'IP Tailscale reste un secours possible si `tailscale serve` pose problème.
- **Écoute sur 127.0.0.1 + `tailscale serve`**, même schéma que le tableau de
  bord du Pi : HTTPS avec un vrai certificat, accès limité au tailnet. Jeton de
  32 octets par-dessus.
- **Bureau à distance maison**, pas VNC : ScreenCaptureKit → JPEG → WebSocket,
  CGEvent pour les clics. Un client VNC Swift (RFB + authentification Apple)
  aurait été bien plus lourd, et l'agent avait déjà le canal et l'auth.
- **Pas de dépendance externe** au runtime. XcodeGen n'est qu'un outil de
  génération.
- **Swift 5, concurrence stricte minimale.** Les callbacks vers l'interface sont
  typés `@MainActor` et appelés via `Task { @MainActor in … }` ; côté iPhone la
  connexion livre ses événements sur la file principale.

## Décisions à ne pas défaire

- **Actions personnalisées : liste fixe dans `config.json`, sans shell, chemin
  absolu.** Jamais de commande libre envoyée par le téléphone. L'iPhone ne voit
  que `id` et `label`.
- **Ouvrir une URL : http/https seulement.**
- **Verrouillage anti-force brute global**, pas par IP : derrière `tailscale
  serve`, tout arrive de 127.0.0.1.
- **Raccourcis clavier résolus selon la disposition active** (`Input.keyCode
  (forCharacter:)`, UCKeyTranslate). Sur AZERTY, le code de la touche « Q »
  QWERTY produit « A » : envoyer ⌃⌘ + ce code ferait ⌃⌘A au lieu de verrouiller.
  Le texte tapé, lui, passe par `keyboardSetUnicodeString`, indépendant de la
  disposition.
- **Contre-pression de l'écran** : au plus 2 images en vol, accusé `screen.ack`
  par l'iPhone, l'agent n'envoie que la plus récente. Sans ça, un lien lent
  (relais DERP) accumulerait des secondes de retard.
- **Ping WebSocket toutes les 10 s des deux côtés** (`Channel.keepAlive`),
  fermeture après deux pings sans pong. Derrière `tailscale serve`, le pair TCP
  de l'agent est tailscaled en local : sans ping, un iPhone parti sans fermer
  laisserait la session — et la capture d'écran — vivre indéfiniment.
- **Capture d'écran annulable pendant son démarrage** (`ScreenStreamer`, verrou
  + drapeau `stopped`) et chaque rappel vérifie `self.streamer === streamer`.
  Sans ça, quitter vite l'onglet Écran laissait un SCStream orphelin capturer.
- **Résolution de capture en pixels** (`pointPixelScale`), pas en points : sinon
  la qualité « Nette » plafonnait à la largeur en points de l'écran.
- **La veille demande confirmation** : un Mac endormi n'est plus joignable, l'app
  ne sait pas le réveiller.
- **Rien n'est écrit sur disque** par la capture d'écran.

## Pièges connus ou probables

1. **Autorisation d'écran : relancer l'agent** après l'avoir accordée.
2. **Identifiant Apple gratuit : l'app iPhone expire après 7 jours.** Le dire
   plutôt que de laisser croire à une panne.
3. **SMAppService retient l'emplacement de l'app** : inscrire le lancement
   automatique depuis `/Applications`, pas depuis le dossier de build.
4. Touches multimédia : codes `NX_KEYTYPE_FAST`/`REWIND` (19/20) pour
   suivant/précédent, comme les touches F9/F7 des claviers Apple. **Non testé** —
   si une app de musique les ignore, essayer `NX_KEYTYPE_NEXT`/`PREVIOUS` (17/18).
5. Sens du défilement à deux doigts : choisi sur le papier (translation du doigt
   = delta de molette), **non vérifié**. S'il est inversé, changer le signe dans
   `RemoteScreenView.twoFingerPan`.
6. `Response` sans `id` et `ok: false` arrive en `notice` sur l'iPhone : c'est
   ainsi que remontent les erreurs des gestes envoyés sans attendre de réponse.

## Chantiers ouverts

1. **Faire passer la CI**, puis premier essai réel sur le Mac et l'iPhone de
   l'utilisateur ; noter ici ce qui a été vérifié.
2. Glisser-déposer (appui maintenu puis déplacement).
3. Plusieurs écrans : choisir l'écran capturé.
4. Widget / raccourcis Siri pour les actions rapides (app native : possible).

## Dépôt

`github.com/zain9191/pilote-mac`, privé. Commits au nom de l'utilisateur
(`Zain Frayha`), **sans ligne Co-Authored-By** : demande explicite de
l'utilisateur.
