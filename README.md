# Silt

Analyseur d'espace disque pour macOS. Natif, rapide, open source.

Les bons analyseurs d'espace disque macOS sont payants ; les gratuits ont vieilli.
Silt vise les deux bouts : un moteur très rapide et une interface qui ressemble
à une app macOS d'aujourd'hui.

---

## Installation

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

- **Quatre vues** sur la même arborescence — anneaux, blocs, liste triée,
  nettoyage.
- **Suppression sécurisée** : tout passe par la corbeille, une liste
  d'interdiction protège le système, et l'annulation restaure.
- **Détection de gras** orientée développement : `node_modules`, DerivedData,
  simulateurs iOS, caches d'outils, builds. Sur une machine de dev réelle, elle
  a repéré 75 Go, dont 48 Go régénérables sans effort.

## Le moteur

`DiskCore` est un package Swift sans aucune dépendance, utilisable seul.

```sh
cd DiskCore
swift run -c release diskscan ~ --depth 2   # arborescence
swift run -c release diskscan ~ --junk      # récupérable
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

- Les **clones APFS** (fichiers partageant des blocs) sont comptés plusieurs
  fois. Les détecter demanderait un appel par bloc ; DaisyDisk a la même limite.
- L'écart avec l'espace libre annoncé par le Finder vient des **snapshots APFS**
  et de l'espace purgeable, qu'aucun parcours de fichiers ne peut voir.
- Dans un dossier replié, les liens durs sont dédupliqués au sein du sous-arbre,
  pas rétroactivement contre le reste du scan.

## Développement

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

## Licence

MIT.
