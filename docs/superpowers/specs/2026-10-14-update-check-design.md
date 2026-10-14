# Vérification des mises à jour — design

Date : 2026-10-14 · Statut : validé en discussion, spec à relire

## Intention

Prévenir l'utilisateur qu'une nouvelle version de Silt existe et lui donner le
geste exact pour l'installer, selon qu'il a installé Silt par Homebrew ou par le
DMG. Silt ne télécharge ni n'installe rien lui-même.

### Contraintes

- Les builds publiées sont signées **ad hoc** (pas de Developer ID). Une mise à
  jour à un clic (Sparkle) promettrait une fluidité que la perte de l'accès
  complet au disque contredit : TCC attache l'autorisation au cdhash du binaire,
  qui change à chaque version. Sparkle reste l'étape suivante le jour où un
  certificat existe ; ce design en est la moitié réutilisable (détection,
  feuille, réglages).
- Deux canaux de distribution : le cask du tap `Gloumi/silt` et le DMG des
  releases GitHub.
- Aucune dépendance ajoutée, aucun changement de CI.

### Critères de réussite

- Une release publiée sur GitHub apparaît dans Silt en moins de 24 h, sans
  action de l'utilisateur, et sans jamais bloquer l'interface.
- L'utilisateur Homebrew voit la commande `brew upgrade --cask silt` ; l'utilisateur
  DMG voit la page de téléchargement et le rappel sur la quarantaine.
- Après une mise à jour qui a fait sauter l'accès complet au disque, Silt le dit
  au lieu de laisser des totaux silencieusement incomplets.
- Hors ligne, rien ne s'affiche d'alarmant ; une erreur n'apparaît que sur une
  vérification demandée à la main.

## Composants

### `ReleaseVersion` (DiskCore)

`DiskCore/Sources/DiskCore/System/ReleaseVersion.swift`. Un type `Comparable`
construit depuis une chaîne `"v0.10.0"` / `"0.10.0"` / `"1.2"` ; composants
numériques séparés par des points, préfixe `v` toléré, composants manquants
valant 0. Tout le reste (suffixe `-beta`, lettres, chaîne vide) donne `nil`.

Il vit dans DiskCore uniquement parce que c'est la seule cible testée : c'est le
seul calcul du chantier qui peut se tromper sans bruit (`0.10.0` contre `0.9.2`
comparés en chaînes).

### `UpdateChecker` (App/Model)

`App/Model/UpdateChecker.swift`. `@Observable @MainActor final class`, instance
partagée `UpdateChecker.shared`.

- `check(manual: Bool) async` : un `GET
  https://api.github.com/repos/Gloumi/silt/releases/latest` (en-têtes `Accept:
  application/vnd.github+json` et `User-Agent: Silt/<version>`). Décode
  `tag_name`, `html_url`, `published_at`. Ce point d'accès exclut brouillons et
  pré-releases.
- `state` : `.idle`, `.checking`, `.upToDate(checkedAt)`, `.available(Release)`,
  `.failed(message)`.
- `availableRelease: Release?` : la release connue si elle est plus récente que
  `CFBundleShortVersionString` **et** différente de `skippedVersion`. C'est ce
  que la barre latérale observe.
- `start()` : appelé une fois au lancement. Vérifie si `checksForUpdates` est
  vrai et que `lastUpdateCheck` date de plus de 24 h, puis reboucle toutes les
  24 h (`Task.sleep`) tant que l'app vit.
- `installedWithHomebrew: Bool` : présence de `Caskroom/silt` sous
  `/opt/homebrew` ou `/usr/local`.

### Préférences (`Preferences`)

| Clé | Type | Défaut | Rôle |
|---|---|---|---|
| `checksForUpdates` | Bool | `true` | interrupteur des vérifications automatiques |
| `lastUpdateCheck` | Date? | nil | cadence de 24 h, survit aux relances |
| `latestKnownRelease` | tag + URL + date | nil | la capsule reste visible hors ligne |
| `skippedVersion` | String? | nil | « Ignorer cette version » |
| `lastLaunchedVersion` | String? | nil | détecte le premier lancement d'une version |

`resetToDefaults()` remet `checksForUpdates` à `true` et ne touche à rien
d'autre de cette liste : ce sont des états, pas des réglages.

## Interface

### Barre latérale

Dans le `safeAreaInset` du bas, à gauche de la roue dentée : une capsule
discrète « Silt 0.6 disponible » (texte `caption`, fond teinté accent), présente
seulement si `availableRelease != nil`. Un clic ouvre la feuille.

### Feuille de mise à jour (`App/Views/UpdateSheet.swift`)

- Titre « Silt 0.6 est disponible », sous-titre « Vous utilisez 0.5.0 · publiée
  le 12 octobre ».
- Lien « Notes de version » → `html_url`. Le corps de la release n'est pas
  rendu : il embarque le bloc d'installation générique.
- **Installée par Homebrew** : la commande `brew upgrade --cask silt` en police
  à chasse fixe, bouton « Copier ».
- **Sinon** : bouton principal « Ouvrir la page de téléchargement », et une
  ligne rappelant qu'après remplacement, macOS refusera le premier lancement et
  qu'il faudra passer par Réglages Système › Confidentialité et sécurité ›
  *Ouvrir quand même* (même texte que le README).
- Une ligne commune : après la mise à jour, l'accès complet au disque sera à
  redonner (voir plus bas).
- Boutons « Ignorer cette version » (pose `skippedVersion`) et « Plus tard ».

### Réglages › Général

Nouvelle section « Mises à jour » :

- Toggle « Rechercher automatiquement les mises à jour ».
- `LabeledContent` avec la ligne d'état (« À jour — vérifié il y a 2 h »,
  « Silt 0.6 disponible » + bouton « Voir… », ou le message d'erreur) et un
  bouton « Rechercher maintenant ».
- `SettingHelp` : « Une requête anonyme vers GitHub une fois par jour ; rien
  d'autre n'est envoyé. »

### Menu

Dans le menu de l'app, sous « À propos de Silt » : « Rechercher les mises à
jour… ». Lance `check(manual: true)` puis ouvre la feuille si une version est
disponible, sinon une alerte « Silt est à jour ». Une version ignorée réapparaît
par ce chemin : la demande manuelle passe outre `skippedVersion`.

Au passage : Aide › « Code source » pointe vers `https://github.com/` ; il
pointera vers `https://github.com/Gloumi/silt`, URL désormais partagée avec
`UpdateChecker`.

## Après une mise à jour : l'accès complet au disque

Au lancement : si `lastLaunchedVersion` est non nil et différent de la version
courante, que `hasSeenWelcome` est vrai et que `FullDiskAccess.isGranted` est
faux, `showsWelcome` passe à vrai avec un drapeau `afterUpdate`. `WelcomeSheet`
affiche alors un en-tête différent : « Silt a été mis à jour — macOS a retiré
son accès », et l'explication qu'il faut retirer Silt de la liste (bouton −)
puis l'y remettre. `lastLaunchedVersion` est mis à jour à chaque lancement.

**À vérifier sur une vraie mise à jour** : que l'entrée restée cochée est bien
inopérante, et que retirer/remettre est le geste qui marche (et pas un simple
décocher/recocher). Le texte de la feuille suivra ce que l'essai montre.

## Erreurs

- Vérification automatique : tout échec (réseau, HTTP ≠ 200, limite de taux,
  JSON inattendu, tag illisible) est silencieux ; `lastUpdateCheck` n'avance pas
  et le cycle suivant réessaie.
- Vérification manuelle : l'échec s'affiche dans la ligne d'état des réglages,
  ou dans l'alerte du menu.
- Un tag que `ReleaseVersion` ne sait pas lire n'est jamais présenté comme une
  mise à jour.

## Tests

- `DiskCoreTests/ReleaseVersionTests.swift` : ordre numérique (`0.10.0 >
  0.9.2`), préfixe `v`, composants manquants (`1.2 == 1.2.0`), rejets (`""`,
  `"1.2-beta"`, `"abc"`).
- Manuel : build + lancement ; un `MARKETING_VERSION` local forcé à `0.4.0` pour
  faire apparaître la capsule et la feuille ; réseau coupé pour la vérification
  manuelle en échec.

## Hors périmètre

- Téléchargement et installation dans l'app (Sparkle) — à reprendre avec un
  certificat Developer ID.
- Rendu des notes de version dans l'app.
- Canal bêta / pré-releases.
