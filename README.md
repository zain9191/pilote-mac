# Pilote — piloter le Mac depuis l'iPhone

Deux apps natives, un seul projet Xcode :

- **Pilote** (iPhone, iOS 17+) : état du Mac, actions rapides, bureau à distance.
- **Pilote Agent** (Mac, macOS 14+) : petite app de la barre des menus, sans icône
  dans le Dock, qui exécute ce que l'iPhone demande.

```
iPhone ── wss:// (Tailscale, HTTPS) ──► tailscale serve ──► agent sur 127.0.0.1:8770
```

L'agent n'écoute que sur la boucle locale du Mac. `tailscale serve` le publie en
HTTPS **dans le tailnet seulement** ; un jeton de 32 octets s'ajoute par-dessus.

## Ce que fait l'app

| Onglet | Contenu |
|---|---|
| **Mac** | processeur, mémoire, disque, batterie, app au premier plan, température, durée d'allumage ; verrouiller, écran noir, veille ; lecture/pause, piste précédente/suivante, volume, sourdine ; ouvrir une adresse web ou une app ; actions personnalisées |
| **Écran** | écran du Mac en direct, toucher = clic, double toucher = double clic, appui long = clic droit, deux doigts = défilement, pincer = zoom local ; clavier de l'iPhone, touches spéciales et modificateurs ⌘ ⌥ ⌃ ⇧ |
| **Réglages** | adresse du Mac et jeton |

## Installation

### 1. Générer le projet

Le `.xcodeproj` n'est pas versionné : il est produit par XcodeGen depuis
`project.yml`.

```bash
brew install xcodegen
git clone git@github.com:zain9191/pilote-mac.git
cd pilote-mac
xcodegen generate
open PiloteMac.xcodeproj
```

Dans Xcode, pour chacune des cibles **Pilote** et **PiloteAgent** : onglet
*Signing & Capabilities*, choisir son équipe (un identifiant Apple gratuit suffit,
« Personal Team »). Si Xcode refuse l'identifiant de paquet, remplacer
`com.zain9191.pilote` par un autre dans `project.yml` puis relancer
`xcodegen generate`.

### 2. L'agent sur le Mac

Le plus simple : schéma **PiloteAgent**, destination « My Mac », ⌘R. Pour une
installation durable, compiler en Release et copier l'app dans `/Applications` :

```bash
xcodebuild -project PiloteMac.xcodeproj -scheme PiloteAgent -configuration Release \
  -derivedDataPath build DEVELOPMENT_TEAM=<ID_EQUIPE> build
cp -R "build/Build/Products/Release/Pilote Agent.app" /Applications/
open "/Applications/Pilote Agent.app"
```

Une icône d'iPhone apparaît dans la barre des menus. Dans son menu :

1. **Autoriser** « Clavier, souris, verrouillage » (Accessibilité) ;
2. **Autoriser** « Bureau à distance » (Enregistrement de l'écran), puis
   **quitter et relancer l'agent** — macOS ne prend l'autorisation d'écran en
   compte qu'au lancement suivant ;
3. cocher **Lancer à l'ouverture de session** (depuis `/Applications` de
   préférence : l'inscription retient l'emplacement de l'app).

Signer avec son équipe compte : macOS rattache les autorisations à la signature.
Avec une signature ad hoc, chaque recompilation les ferait perdre.

### 3. Publier l'agent dans le tailnet

```bash
tailscale serve --bg --https=443 http://127.0.0.1:8770
```

Si la commande `tailscale` n'existe pas, l'app Tailscale pour Mac propose
d'installer l'outil en ligne de commande dans ses réglages ; sinon il se trouve
dans `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.

**Ne pas utiliser `tailscale funnel`** : cela publierait l'agent sur Internet.

### 4. L'app sur l'iPhone

1. Brancher l'iPhone, l'activer en *Mode développeur* (Réglages › Confidentialité
   et sécurité), schéma **Pilote**, destination l'iPhone, ⌘R.
2. Au premier lancement, autoriser le profil développeur : Réglages › Général ›
   VPN et gestion de l'appareil.
3. Dans l'app, onglet **Réglages** :
   - adresse : le nom Tailscale du Mac, par exemple `mon-mac.tailXXXX.ts.net` ;
   - jeton : sur le Mac, menu Pilote › **Copier le jeton**, puis **Coller** dans
     l'app (le presse-papiers universel le fait passer si les deux appareils
     partagent le même identifiant Apple).

> **Identifiant Apple gratuit : l'app iPhone expire au bout de 7 jours.** Il faut
> la réinstaller depuis Xcode (⌘R, iPhone branché). Seul l'abonnement payant
> Apple Developer Program lève cette limite.

## Actions personnalisées

Fichier `~/Library/Application Support/PiloteMac/config.json`, ouvert par le menu
**Modifier…** puis pris en compte par **Relire** :

```json
{
  "listen" : "127.0.0.1",
  "port" : 8770,
  "actions" : [
    { "id" : "eveil", "label" : "Empêcher la veille 1 h",
      "command" : ["/usr/bin/caffeinate", "-d", "-t", "3600"], "confirm" : false },
    { "id" : "sauvegarde", "label" : "Lancer Time Machine",
      "command" : ["/usr/bin/tmutil", "startbackup"], "confirm" : true }
  ]
}
```

- `command` : exécutable en **chemin absolu** puis ses arguments. Pas de shell :
  pour une chaîne shell, écrire `["/bin/zsh", "-lc", "…"]` en connaissance de cause.
- `confirm` : l'iPhone demande confirmation avant de lancer.
- L'iPhone ne voit que `id` et `label`, jamais la commande. Il ne peut lancer que
  ce qui est écrit dans ce fichier.
- L'agent attend la fin jusqu'à 15 s ; au-delà il répond « toujours en cours ».
  La sortie de la commande n'est pas renvoyée.
- `listen` et `port` ne sont relus qu'au redémarrage de l'agent.

## Sécurité

- Agent sur `127.0.0.1` : rien n'est joignable depuis le réseau local.
- Accès par `tailscale serve` : HTTPS, appareils du tailnet seulement.
- Jeton de 32 octets aléatoires, comparé en temps constant, fichier en mode 600 ;
  côté iPhone, dans le trousseau, non synchronisé.
- 5 jetons faux en 15 minutes → tout est refusé pendant 15 minutes, bon jeton
  compris (derrière `tailscale serve` toutes les connexions viennent de
  127.0.0.1, impossible de verrouiller par adresse).
- **Nouveau jeton** dans le menu : l'ancien ne vaut plus rien et l'iPhone est
  déconnecté.
- Ouvrir une adresse : `http` et `https` uniquement. Commandes : uniquement
  celles de `config.json`.
- Rien n'est enregistré : les images de l'écran sont produites en mémoire et
  envoyées, jamais écrites sur disque.

## Limites connues

- **Écran principal seulement** pour le bureau à distance.
- **Pas de glisser-déposer** à la souris, pas de son du Mac sur l'iPhone.
- **Mac en veille = injoignable** : l'app ne sait pas le réveiller.
- Le défilement à deux doigts peut se déclencher pendant un pincement de zoom.
- macOS 15 et suivants peuvent redemander périodiquement de confirmer
  l'autorisation d'enregistrement de l'écran, sur le Mac lui-même.
- L'image est une suite de JPEG (≈ 8 à 15 images/s selon la qualité choisie) :
  fluide pour piloter, pas pour regarder une vidéo.

## Dépannage

| Symptôme | Piste |
|---|---|
| « Mac injoignable » | Mac allumé et éveillé ? Tailscale actif des deux côtés ? `tailscale serve status` sur le Mac |
| « Jeton refusé » | recopier le jeton ; après 5 échecs, attendre 15 min |
| Rien ne se passe au clic | autorisation Accessibilité manquante : l'onglet Mac l'indique |
| Écran noir ou erreur de capture | autorisation Enregistrement de l'écran, puis relancer l'agent |
| Verrouiller ne fait rien | le raccourci système ⌃⌘Q a-t-il été modifié dans Réglages › Clavier ? |
| Volume absent | la sortie audio actuelle n'a pas de volume réglable (certains écrans HDMI) |

## Développement

```bash
xcodegen generate
xcodebuild test -project PiloteMac.xcodeproj -scheme PiloteTests -destination 'platform=macOS'
```

La CI GitHub (`.github/workflows/build.yml`) génère le projet, lance les tests et
compile les deux apps sur un runner macOS à chaque pull request.

Arborescence :

```
project.yml        spécification XcodeGen (fait foi)
Shared/            protocole, WebSocket, adresse, jeton — compilé dans les deux apps
Agent/             agent macOS : serveur, actions, état, écran, clavier/souris, menu
iOS/               app iPhone : lien, tableau de bord, bureau à distance, réglages
Tests/             tests unitaires du code partagé
```

### Protocole

Une connexion WebSocket. L'iPhone envoie du JSON (`Request`), l'agent répond en
JSON (`Response`) avec le même `id`, et pousse l'écran en JPEG binaire. Première
requête obligatoire : `{"id":1,"type":"auth","token":"…"}`, dans les 5 s, sinon
l'agent raccroche. Au plus deux images en vol : l'iPhone accuse réception de
chacune (`screen.ack`), l'agent n'envoie que la plus récente. Détail dans
`Shared/Protocol.swift`.
