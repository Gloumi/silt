# Silt

Analyseur d'espace disque pour macOS. Natif, rapide, open source.

Les bons analyseurs d'espace disque macOS sont payants ; les gratuits ont vieilli.
Silt vise les deux bouts : un moteur très rapide et une interface qui ressemble
à une app macOS d'aujourd'hui.

---

## Installation

Silt demande **macOS 15 Sequoia** ou plus récent. L'interface est en français.

```sh
brew tap Gloumi/silt https://github.com/Gloumi/silt
brew install --cask --no-quarantine silt
```

Ou téléchargez le DMG depuis les [releases](https://github.com/Gloumi/silt/releases).

> **Accès complet au disque.** macOS protège Mail, Messages, Photos et les
> sauvegardes d'appareils. Sans autorisation, ces dossiers sont signalés comme
> illisibles et manquent aux totaux. L'app explique la marche à suivre au premier
> lancement — aucune application ne peut demander cette permission autrement.

### Le premier lancement, sans signature Apple

Les binaires publiés ici ne sont pas signés par un certificat Developer ID —
celui-ci coûte 99 €/an et le projet n'y est pas encore. macOS met donc en
quarantaine tout ce qui vient du web et refuse le premier lancement.

Le `--no-quarantine` ci-dessus règle le problème en amont : le drapeau n'est
jamais posé, l'app s'ouvre normalement. Si vous passez par le DMG, deux voies :

```sh
xattr -dr com.apple.quarantine /Applications/Silt.app
```

ou, sans terminal : lancez Silt, laissez macOS refuser, puis ouvrez **Réglages
Système › Confidentialité et sécurité**. Un bouton *Ouvrir quand même* y apparaît
juste après la tentative. Depuis macOS 15, le clic droit → *Ouvrir* ne suffit
plus ; c'est ce passage par les Réglages qui l'a remplacé.

Rien de tout cela ne remplace une vraie signature : ces manipulations désactivent
une vérification, elles ne prouvent pas que le binaire est celui compilé depuis
ces sources. La seule garantie réelle, tant qu'il n'y a pas de notarisation,
c'est de compiler soi-même — voir [Développement](#développement).

## Ce que ça fait

**Voir où va l'espace**

- **Cinq vues** sur la même arborescence : anneaux, blocs, liste triée,
  fichiers volumineux (les plus gros d'un sous-arbre, à plat) et doublons. Les
  anneaux s'adaptent à la profondeur réelle du dossier au lieu de laisser les
  niveaux inutilisés en blanc.
- **Recherche** : un seul champ filtre toutes les vues à la fois, tailles
  recalculées.
- **Couleur par âge** : les dates de modification sont conservées, et les vues
  peuvent se colorer par ancienneté plutôt que par dossier.
- **L'espace qu'aucun scan ne voit** : les jauges de volume affichent le même
  chiffre que le Finder et montrent à part ce que macOS s'est réservé.

**Récupérer de la place**

- **Caches et résidus** : 49 règles orientées développement — `node_modules`,
  DerivedData, simulateurs iOS, caches d'outils, builds des frameworks JS
  courants, caches Python. Sur une machine de dev réelle : 62 Go repérés.
- **Doublons** : on choisit la copie qui reste, pas celles qui partent. Le
  disque n'est lu que là où les tailles ne suffisent plus à trancher, un
  fichier iCloud non téléchargé n'est jamais rapatrié pour être comparé, et un
  clone APFS n'est compté qu'une fois ([détails](#trouver-les-doublons-sans-lire-tout-le-disque)).
- **Applications** : la liste de tout ce qui est installé, triée par la place
  réellement occupée, et une désinstallation qui retrouve ce qu'une app laisse
  dans `~/Library`. Seul l'indiscutable est coché
  ([pourquoi](#désinstaller-large-sans-emporter-le-voisin)).
- **Redémarrage** : ce qu'un redémarrage libérerait (swap, caches système de
  l'utilisateur), et la suppression de ce qui peut l'être tout de suite.
- **Snapshots** : les instantanés APFS locaux, cause la plus fréquente de
  l'espace « fantôme », et leur suppression avec le mot de passe administrateur.

**Supprimer sans regret**

- Tout passe par la corbeille, une liste d'interdiction protège le système, et
  l'outil **Corbeille** garde la trace de ce que Silt y a mis pour le remettre
  en place, même après avoir quitté l'app.
- Une suppression est vérifiée après coup : sur certains volumes externes, la
  corbeille se contente de copier — Silt le détecte, le dit, et ne compte pas
  l'espace comme libéré. Une suppression définitive, quand aucune corbeille
  n'est possible, est annoncée ligne par ligne et confirmée deux fois.
- **Les scans restent en mémoire** : revenir sur un volume déjà analysé est
  instantané, et l'actualisation est un geste explicite (⇧⌘R).

## Le moteur

`DiskCore` est un package Swift sans aucune dépendance, utilisable seul.

```sh
cd DiskCore
swift run -c release diskscan ~ --depth 2   # arborescence
swift run -c release diskscan ~ --junk      # récupérable
swift run -c release diskscan --uninstall /Applications/X.app  # essai à blanc
swift test
```

Trois décisions font la performance :

- **`getattrlistbulk(2)`** — des centaines d'entrées par appel système, au lieu
  d'un `stat()` par fichier.
- **Tableaux parallèles indexés par `Int32`**, pas un graphe d'objets : à un
  million de nœuds, le trafic ARC domine tout le reste. Les enfants d'un
  répertoire sont contigus, la remontée des tailles tient en une passe linéaire.
- **Quatre à six workers**, pas un par cœur. Le scan est de la pure latence
  syscall — un seul worker consomme moins de 0,3 s de processeur pour 400 000
  fichiers — donc le parallélisme rapporte beaucoup, puis plafonne net.

Mesuré sur un MacBook 10 cœurs : **2,4 millions de fichiers en 15 s**, soit
10 M/min. Totaux vérifiés identiques à `du -sk`.

### Ce que le moteur fait correctement, et qui se rate facilement

| | |
|---|---|
| **Firmlinks** | Depuis Catalina, le disque de démarrage est scindé en deux volumes cousus par des firmlinks. Les ignorer fait rendre 12 Go pour un disque de 494 Go. `getattrlistbulk` rapporte le device du firmlink et non de sa cible, donc chaque répertoire lit le sien par `fstat` après ouverture. |
| **Taille allouée** | La taille sur disque, pas la taille logique : correcte pour les fichiers creux et la compression APFS. |
| **Liens durs** | Comptés une seule fois, comme `du`. |
| **Liens symboliques** | Jamais suivis — un lien vers un parent boucle à l'infini. `du` lui-même abandonne sur ce cas. |
| **Paquets** | `.app`, `.photoslibrary` traités comme un élément, comme dans le Finder. |
| **Dossiers illisibles** | Signalés, jamais silencieusement omis. |

## Limites connues

- Dans les **totaux du scan**, un clone APFS (fichier partageant ses blocs avec
  un autre, ce que produit ⌘D dans le Finder) compte à chaque copie, comme avec
  `du`. Seule la vue Doublons mesure les blocs réellement partagés : le faire
  pendant le scan coûterait un appel système par fichier.
- L'écart entre le total d'un scan et l'espace libre du Finder vient de l'espace
  qu'**macOS s'est réservé** — ce qu'il appelle « purgeable » — et qu'aucun parcours
  de fichiers ne peut voir. Les jauges de volume l'affichent désormais, et l'outil
  **Snapshots** liste les copies APFS locales qui en sont la cause la plus fréquente.
  Aucune **taille par snapshot** n'est annoncée :
  les snapshots partagent leurs blocs entre eux et avec le disque vivant, si bien
  qu'aucun nombre par snapshot n'existe — macOS n'en publie d'ailleurs aucun.
  Seul l'écart réel du volume, et ce qu'une suppression a effectivement libéré,
  sont mesurés.
- Dans un dossier replié, les liens durs sont dédupliqués au sein du sous-arbre,
  pas rétroactivement contre le reste du scan.

## Développement

Il faut Xcode 26 ou plus récent (Swift 6) et [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate          # produit Silt.xcodeproj, non versionné
open Silt.xcodeproj
```

Le projet se décrit dans [`project.yml`](project.yml) ; le `.xcodeproj` est un
artefact généré, ce qui garde les diffs lisibles.

```sh
swift Scripts/make-icon.swift  # régénère l'icône depuis la palette
./Scripts/release.sh           # tests, build, DMG signé si un certificat existe
```

### Les couleurs sont vérifiées, pas choisies à l'œil

Les huit teintes sont attribuées dans un ordre fixe autour du cercle, jamais
générées ni cyclées. Cet ordre est le mécanisme de sûreté : il garantit que deux
tranches voisines restent distinguables, y compris en cas de déficience de la
vision des couleurs (pire paire protanopie ΔE 9,1 en clair, 8,4 en sombre). La
couture, où la dernière tranche rejoint la première, est vérifiée à part. La
profondeur est une rampe séquentielle calculée en OKLab, parce que des pas égaux
en RVB paraissent irréguliers.

### Ajouter une règle de nettoyage

Les règles vivent dans
[`rules.json`](DiskCore/Sources/DiskCore/Rules/Resources/rules.json), pas dans le
code — c'est la partie qui demandera le plus d'entretien, puisque chaque outil
invente ses propres caches. Les matcheurs sont déclaratifs :

```json
{
  "id": "composer-vendor",
  "category": "dependencies",
  "title": "Dépendances Composer",
  "safety": "safe",
  "recovery": "composer install",
  "match": { "directoryName": "vendor", "siblingFile": "composer.json" }
}
```

`siblingFile` évite les faux positifs : un dossier `vendor` ne compte que si un
`composer.json` est à côté. `safety` vaut `safe` (régénéré tout seul) ou
`caution` (récupérable, mais ça coûte quelque chose).

**L'ordre du fichier fait office de priorité.** La première règle qui réclame un
dossier le garde. Une règle qui balaye les enfants d'un répertoire doit donc être
déclarée *après* toute règle qui nomme quelque chose de précis à l'intérieur —
sinon cette dernière ne s'appliquera jamais. C'est arrivé : `generic-cache`
placée avant `.cache/huggingface` faisait passer 464 Mo de modèles pour un cache
générique « sans risque ». Un test vérifie l'invariant sur le fichier livré.

### Trouver les doublons sans lire tout le disque

Comparer des contenus est la seule partie de l'app qui lit le corps des
fichiers plutôt que leurs métadonnées ; tout hacher reviendrait à relire des
centaines de gigaoctets pour rien. Les preuves sont donc dépensées par ordre de
coût :

1. **La taille**, gratuite puisque le scan l'a déjà mesurée. Une taille vue une
   seule fois ne peut être le doublon de rien.
2. **Les 128 premiers Kio**, qui séparent presque tout ce qui pèse le même
   poids par hasard.
3. **Le contenu entier**, pour ce qui reste seulement.

Trois cas faussent les chiffres si on ne les traite pas :

- **Liens durs** : deux chemins vers le même inode partagent leurs octets ;
  en supprimer un ne libère rien. Ils sont repliés avant toute lecture.
- **Clones APFS** : un clone a son propre inode et la taille pleine pour `du`,
  mais ses blocs restent partagés. Silt les identifie par l'emplacement
  physique de leurs blocs (`F_LOG2PHYS_EXT`), sur le descripteur déjà ouvert
  pour le hachage — un `fcntl` par fichier, aucune lecture en plus.
- **Fichiers iCloud évincés** : ils annoncent leur taille logique mais
  n'occupent rien sur le disque. Les hacher les téléchargerait, pour remplir le
  disque qu'on cherche à vider. Ils sont exclus, et le résumé le dit.

La copie conservée par défaut est la plus récente **hors des stockages gérés**
par une application : un gestionnaire de presse-papiers garde une copie plus
récente que le document d'origine, et « garder la plus récente » jetterait le
fichier de l'utilisateur pour préserver un cache.

### Désinstaller large sans emporter le voisin

Un `.app` ne représente presque jamais la place qu'une application occupe. Silt
lit son `CFBundleIdentifier` et balaye les dossiers de `~/Library` et
`/Library`, en classant chaque trouvaille selon **la façon dont elle a été
rapprochée** :

| Niveau | Critère | Coché |
|---|---|---|
| Certain | Porte l'identifiant de paquet (`com.x.y`, `com.x.y.plist`, `group.com.x.y`) | ✅ |
| Probable | Porte exactement le nom de l'application | ❌ |
| À vérifier | Nom approchant, ou même préfixe éditeur | ❌ |

Les deux moitiés sont nécessaires. Anarlog se nomme `com.hyprnote.stable` :
l'identifiant seul trouve son cache de 1,2 Go mais rate
`~/Library/Application Support/anarlog`, et le nom seul fait l'inverse.

Le dernier niveau est celui qui justifie tout le dispositif. Android Studio est
`com.google.android.studio`, donc le préfixe `com.google.` fait remonter les
préférences de Chrome. Les cocher d'office effacerait la configuration de Chrome
en désinstallant Android Studio. Elles sont **montrées** — balayer large est le
but — et jamais présélectionnées. Il n'y a volontairement pas de « tout cocher ».

`diskscan --uninstall` fait le même travail en affichage seul, sans rien
supprimer.

## Licence

MIT — voir [LICENSE](LICENSE).
