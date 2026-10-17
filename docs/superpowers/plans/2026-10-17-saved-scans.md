# Analyses sauvegardées — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Les analyses terminées survivent à la fermeture de Silt, reviennent au lancement avec leur âge bien visible, et sont refusées au-delà d'un seuil réglable.

**Architecture:** DiskCore (seule cible testée) gagne l'archivage d'un `ScanResult` (`SavedScan`), la mise sous scellé (LZFSE + AES-GCM optionnel, `ScanSealing`), la remesure d'un nœud restauré et la revérification d'un fichier avant suppression. L'app gagne `ScanVault` (fichiers + clé du trousseau) et le câblage dans `ScanModel` : sauvegarde à la fin d'un scan et après chaque suppression, chargement au lancement dans le cache existant, propagation des suppressions à tous les arbres en mémoire, filtrage par âge dans `tree(holding:)`.

**Tech Stack:** Swift 6 (concurrence stricte), SwiftUI macOS 15, CryptoKit, Security (trousseau), Foundation (`NSData.compressed(using: .lzfse)`), swift-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-17-saved-scans-design.md`

## Global Constraints

- Aucune dépendance ajoutée, aucun changement de CI.
- Jamais de dialogue du trousseau : lectures avec `kSecUseAuthenticationUI` = `kSecUseAuthenticationUIFail`.
- `#if DEBUG` : pas de chiffrement, dossier `Scans-debug/`. Sinon : AES-GCM, dossier `Scans/`. Les deux dans `~/Library/Caches/app.silt.mac/`.
- Au plus `cacheLimit + 1` (= 4) fichiers sauvegardés : le disque suit la mémoire.
- Seuil d'âge : réglage en jours, valeurs `[1, 3, 7, 14, 30]`, défaut `7`. Mention « ancienne » au-delà de 24 h.
- Jamais d'analyse annulée sauvegardée.
- Toute écriture hors du thread principal, atomique (`Data.write(to:options: .atomic)`).
- Tout fichier illisible est supprimé sans bruit.
- Interface en français ; commentaires et commits en anglais, dans le style du code voisin (commentaires qui expliquent le *pourquoi*).
- Après ajout de fichiers dans `App/` : `xcodegen generate` avant de compiler.
- Juger un build sur son code de sortie (skill `run-silt`) et s'arrêter à `open` : Renan teste lui-même. Tests DiskCore : `cd DiskCore && swift test --skip firmlinks`.

## Écarts et précisions par rapport à la spec

- **Racine absente au lancement** (volume externe débranché, dossier supprimé) : l'analyse n'est pas chargée, mais son fichier est gardé. La resservir montrerait un disque qui n'est pas là.
- **Écriture à la sortie :** `ScanModel` écrit les arbres modifiés au `willTerminate`, de façon synchrone, pour ne pas perdre une suppression faite dans les 3 secondes avant de quitter.
- **Dernier emplacement :** stocké dans `Preferences` (`lastLocation`, chemin + nom). Au lancement, s'il n'existe plus, on retombe sur le volume de démarrage.
- **Dates des analyses expirées :** `Preferences.expiredScans: [String: Date]` (racine → date). Une entrée est ajoutée quand un arbre est écarté pour son âge, et retirée quand sa racine est réanalysée.

## Review Focus

1. **Archive corrompue ou incohérente** (tronquée, octets modifiés, tableaux de longueurs différentes, `parent` hors bornes) : le décodage rend `nil`, sans plantage. Couvert par la tâche 1.
2. **Build qui ne peut plus lire la clé** (mise à jour) : aucun dialogue, nouvelle clé, anciens fichiers supprimés, l'app démarre comme sans analyse. Vérification manuelle à la tâche 5.
3. **Fichier remplacé sous le même nom depuis l'analyse :** la fiche de suppression le signale et compte sa taille actuelle. Couvert par la tâche 3.
4. **Volume externe analysé puis débranché :** au lancement, ni son analyse ni ses dossiers ne s'affichent. Tâche 6, vérification manuelle.
5. **Un élément supprimé puis restauré depuis l'outil Corbeille** réapparaît dans l'analyse du disque comme dans celle du dossier, avec sa taille. Couvert par la tâche 2 (remesure) et la tâche 4 (câblage).

---

### Task 1: Archiver un `ScanResult` (DiskCore)

**Files:**
- Create: `DiskCore/Sources/DiskCore/Model/SavedScan.swift`
- Modify: `DiskCore/Sources/DiskCore/Model/NodeStore.swift` (un `init` interne depuis les tableaux, avec validation)
- Test: `DiskCore/Tests/DiskCoreTests/SavedScanTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SavedScan: Sendable {
      public static let formatVersion: UInt32   // 1
      public var rootPath: String     // chemin tel que demandé (clé du cache)
      public var scannedAt: Date
      public var result: ScanResult
      public init(rootPath: String, scannedAt: Date, result: ScanResult)
      public func encoded() -> Data            // binaire en clair, non compressé
      public init?(decoding data: Data)        // nil : version, troncature, incohérence
  }
  ```
  Le format est libre (en-tête magique + version, puis métadonnées, puis les 11 tableaux du `NodeStore` bout à bout, petit-boutiste). `encoded()` refuse un résultat `wasCancelled` par `precondition`.
- Validation obligatoire au décodage, avant de construire le `NodeStore` : tous les tableaux par nœud ont la même longueur `n` ; `parent[0] == 0` et `parent[i] < i` pour `i > 0` ; `childStart[i] + childCount[i] <= n` et `childCount[i] >= 0` ; `nameOffset[i] + nameLength[i] <= nameBlob.count`.

- [ ] **Step 1: Write the failing tests** dans `SavedScanTests.swift` (suite `"Saved scan"`) :
  - `roundTrip` : scanner une `Fixture` (`a/b/c.bin` 10 000 o, `a/d.bin` 3 000 o, `e/f.bin` 500 o), `markDeleted` le nœud de `a/d.bin`, encoder puis décoder. Vérifier l'égalité de tous les tableaux publics du store (`parent`, `childStart`, `childCount`, `totalAlloc`, `totalLogical`, `fileCount`, `modTime`, `flags.map(\.rawValue)`, `nameBlob`), ainsi que `rootPath`, `scannedAt` (à la seconde près), `unreadablePaths`, `filesSeen`, `directoriesSeen`, `duration`. Vérifier aussi que `node(atPath: root + "/a/b")` donne le même index, et que `flags` de `d.bin` contient `.deleted`.
  - `rejectsTruncated` : pour chaque longueur `k` dans `stride(from: 0, to: data.count, by: max(1, data.count / 50))`, `SavedScan(decoding: data.prefix(k)) == nil`.
  - `rejectsOtherVersion` : modifier les octets de version de l'en-tête → `nil`.
  - `rejectsInconsistentTree` : construire une archive dont un `parent` vaut `n + 5` (en modifiant l'octet à l'offset correspondant, ou via un helper de test `encoded(corrupting:)` marqué `internal`) → `nil`.

- [ ] **Step 2: Run tests to verify they fail**
  Run: `cd DiskCore && swift test --filter "Saved scan"` — Expected: échec de compilation (`SavedScan` inconnu).

- [ ] **Step 3: Implement `SavedScan` and `NodeStore.init?(validating:...)`**

- [ ] **Step 4: Run tests to verify they pass**
  Run: `cd DiskCore && swift test --skip firmlinks` — Expected: tous verts.

- [ ] **Step 5: Commit** — `git commit -m "Archive a finished scan so it can outlive the app"`

### Task 2: Sceller une archive, et remesurer un nœud restauré (DiskCore)

**Files:**
- Create: `DiskCore/Sources/DiskCore/Model/ScanSealing.swift`
- Modify: `DiskCore/Sources/DiskCore/Model/NodeStore.swift` (extension `reinstatedSizes`)
- Test: `DiskCore/Tests/DiskCoreTests/SavedScanTests.swift` (même fichier, suites séparées)

**Interfaces:**
- Produces:
  ```swift
  public enum ScanSealing {
      /// LZFSE, puis AES-GCM si `key` n'est pas nil.
      public static func seal(_ plain: Data, key: SymmetricKey?) throws -> Data
      /// Nil si la clé ne correspond pas, si les octets ont été modifiés, ou si la décompression échoue.
      public static func open(_ sealed: Data, key: SymmetricKey?) -> Data?
  }

  extension NodeStore {
      /// Tailles à rendre à un nœud marqué `.deleted` qui est revenu sur disque à `path`, sans les tailles d'avant suppression.
      /// Nil si `path` n'existe pas.
      public func reinstatedSizes(of node: Int32, at path: String)
          -> (alloc: Int64, logical: Int64, files: Int32)?
  }
  ```
  `reinstatedSizes` : pour un fichier, `lstat` (`st_blocks * 512`, `st_size`, `1`). Pour un dossier parcouru (sans `.notDescended`), `lstat` du dossier lui-même plus la somme des totaux des enfants non `isEffectivelyDeleted` (les enfants n'ont pas été mis à zéro par `markDeleted`). Pour un dossier non parcouru (paquet, dossier replié), `PathSize.measure` (`logical = allocated`).

- [ ] **Step 1: Write the failing tests**
  - Suite `"Scan sealing"` :
    - `roundTripWithKey` : `open(seal(d, key: k), key: k) == d` pour `d` = 1 Mo de données répétitives, et la taille scellée est inférieure à `d.count / 4`.
    - `roundTripWithoutKey` : idem avec `key: nil`.
    - `wrongKeyFails` : `open(seal(d, key: k1), key: k2) == nil`.
    - `tamperingFails` : inverser un octet au milieu du scellé → `open(...) == nil` (avec clé).
  - Suite `"Reinstated sizes"` :
    - `fileComesBackWithItsSize` : scanner une `Fixture` (`x/one.bin` 8 000 o, `x/two.bin` 4 000 o), noter les totaux de `one.bin` et de la racine, `markDeleted(one)`, puis `unmarkDeleted(one, sizes de reinstatedSizes)`. Les totaux de `one.bin` et de la racine (`totalAlloc`, `totalLogical`, `fileCount`) sont revenus à leurs valeurs d'origine.
    - `folderComesBackWithItsSize` : même chose avec le dossier `x`.
    - `missingPathIsNil` : supprimer `x/one.bin` du disque → `reinstatedSizes(of: one, at: path) == nil`.

- [ ] **Step 2: Run tests to verify they fail** — `swift test --filter "Scan sealing|Reinstated sizes"` : échec de compilation.

- [ ] **Step 3: Implement `ScanSealing` and `reinstatedSizes`** (`import CryptoKit`, `AES.GCM.seal(...).combined`).

- [ ] **Step 4: Run tests** — `swift test --skip firmlinks` : tous verts.

- [ ] **Step 5: Commit** — `git commit -m "Seal saved scans, and measure what comes back from the Trash"`

### Task 3: Revérifier un élément avant de le supprimer

**Files:**
- Create: `DiskCore/Sources/DiskCore/Delete/DiskCheck.swift`
- Modify: `App/Model/ScanModel.swift` — `requestDeletion(_ nodes: Set<Int32>)`
- Test: `DiskCore/Tests/DiskCoreTests/DeletionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum DiskCheck {
      public enum Verdict: Equatable, Sendable {
          case unchanged
          case changed(alloc: Int64)   // taille allouée actuelle
          case missing                 // absent, ou n'est plus du même type (fichier ↔ dossier)
      }
      /// `logical` et `modified` ne sont comparés que pour un fichier (`isDirectory == false`).
      /// `modified` est en secondes Unix, bornées comme dans `NodeStore.modTime`.
      public static func verdict(path: String, isDirectory: Bool,
                                 logical: Int64, modified: Int32) -> Verdict
  }
  ```
- Dans `requestDeletion`, pour chaque nœud retenu : `isDirectory` = `store.isDirectory(node)`, `logical` = `store.totalLogical`, `modified` = `store.modTime`.
  - `.missing` → `plan.refused.append("\(name) — n'existe plus sur le disque")`, non mis en file, ne réclame pas son sous-arbre.
  - `.changed(alloc)` → `plan.cautions.append("\(name) — modifié depuis l'analyse")`, requête mise en file avec `bytes: alloc`, et `alloc` ajouté au total.
  - `.unchanged` → comportement actuel.
  - La vérification se fait après le refus de la `DenyList` (un élément protégé reste refusé pour sa raison à lui).

- [ ] **Step 1: Write the failing tests** (suite existante de `DeletionTests.swift`, ou une suite `"Disk check"`) :
  - `unchangedFile` : fixture `f.bin` de 5 000 o, scanner, `verdict(...)` avec les valeurs du store → `.unchanged`.
  - `rewrittenFile` : réécrire `f.bin` avec 9 000 o après le scan → `.changed(alloc:)` avec `alloc > 0`.
  - `touchedFile` : même taille, mais `setAttributes([.modificationDate: created - 3600])` → `.changed`.
  - `missingFile` : supprimer `f.bin` → `.missing`.
  - `fileBecameFolder` : supprimer `f.bin`, créer un dossier `f.bin` → `.missing`.
  - `folderIgnoresSizes` : dossier `d/` avec un fichier ajouté après le scan → `.unchanged`.

- [ ] **Step 2: Run to verify failure** — `swift test --filter "Disk check"` : échec de compilation.

- [ ] **Step 3: Implement `DiskCheck.verdict`** (`lstat`, `st_size`, `st_mtimespec.tv_sec` borné à `Int32`), puis l'appeler dans `requestDeletion` comme décrit.

- [ ] **Step 4: Run** — `swift test --skip firmlinks` vert ; build de l'app (`xcodebuild … build -quiet`, exit 0).

- [ ] **Step 5: Commit** — `git commit -m "Check an item is still what the scan saw before trashing it"`

### Task 4: Appliquer suppressions et restaurations à tous les arbres en mémoire

**Files:**
- Modify: `App/Model/ScanModel.swift`

**Interfaces:**
- Consumes: `NodeStore.node(atPath:)` (existant), `NodeStore.reinstatedSizes(of:at:)` (tâche 2), `markDeleted` / `unmarkDeleted` (existants).
- Produces (privé à `ScanModel`, utilisé par la tâche 6) :
  ```swift
  /// Racines (`treeRootPath` ou clé de cache) dont l'arbre a changé depuis sa dernière sauvegarde.
  private var unsavedRoots: Set<String>
  private func propagateDeletion(_ items: [TrashedItem])
  private func reinstate(_ paths: [String], skipping handled: Set<Int32>)
  ```
- `CachedScan.result` devient `var`.
- `propagateDeletion` : pour l'arbre à l'écran, `item.node ?? store.node(atPath: item.originalPath)` ; pour chaque arbre en cache, `node(atPath: item.originalPath)`. `markDeleted` sur chacun (idempotent). Chaque racine touchée va dans `unsavedRoots`. Remplace les trois boucles `for item in report.trashed { … markDeleted … }` (`confirmDeletion`, la confirmation de la suppression de résidus et `uninstall`).
- `reinstate` : pour chaque arbre (à l'écran, puis en cache) et chaque chemin, nœud trouvé par chemin et encore `.deleted` → `unmarkDeleted` avec `reinstatedSizes(of:at:)`. `skipping` contient les nœuds de l'arbre à l'écran déjà rétablis par l'annulation (`undoSizes`), qui garde ses tailles exactes.
  - `undoLastDeletion` : après la boucle actuelle, `reinstate(chemins restaurés, skipping: nœuds déjà rétablis)`.
  - `restoreFromTrash` : `reinstate(entries réussies .map(\.originalPath), skipping: [])`. Mettre à jour le commentaire « cannot repair the tree's roll-up », qui devient faux.

- [ ] **Step 1: Implement** les trois fonctions et leurs appels.
- [ ] **Step 2: Build** — `xcodebuild … build -quiet` : exit 0.
- [ ] **Step 3: Commit** — `git commit -m "Keep every tree in memory in step with a deletion"`

### Task 5: `ScanVault` — fichiers et clé

**Files:**
- Create: `App/Model/ScanVault.swift`
- Run: `xcodegen generate`

**Interfaces:**
- Consumes: `SavedScan`, `ScanSealing` (tâches 1-2).
- Produces:
  ```swift
  /// Lecture et écriture des analyses sauvegardées. Pas d'acteur principal : tout s'exécute en tâche de fond.
  enum ScanVault {
      static func save(_ scan: SavedScan)                // écrit ou remplace le fichier de scan.rootPath
      static func remove(rootPath: String)
      static func loadAll() -> [SavedScan]               // supprime au passage les fichiers illisibles
  }
  ```
- Dossier : `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]` + `app.silt.mac/Scans` (ou `Scans-debug` en `#if DEBUG`). Nom de fichier : 16 premiers octets hex de `SHA256(rootPath)` + `.siltscan`.
- Clé (Release uniquement) : `kSecClassGenericPassword`, service `app.silt.mac.scans`, compte lu dans `UserDefaults` (`scanKeyAccount`). Lecture avec `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail`. Si le compte est absent ou si la lecture échoue : générer `SymmetricKey(size: .bits256)`, l'ajouter sous le compte `scans-<UUID>`, enregistrer ce compte, et vider le dossier (les fichiers existants sont scellés avec une clé perdue). La clé est mise en cache dans une variable statique protégée par un verrou (`Mutex` de Synchronization ou `NSLock`) après la première lecture.

- [ ] **Step 1: Implement `ScanVault`**, puis `xcodegen generate`.
- [ ] **Step 2: Build** — exit 0.
- [ ] **Step 3: Commit** — `git commit -m "Store saved scans in Caches, sealed with a key from the keychain"`

### Task 6: Sauvegarder et recharger depuis `ScanModel`

**Files:**
- Modify: `App/Model/ScanModel.swift`, `App/Model/Preferences.swift`, `App/Views/SidebarView.swift`, `App/SiltApp.swift`

**Interfaces:**
- Consumes: `ScanVault` (tâche 5), `unsavedRoots` (tâche 4), `tree(holding:)` et `show(_:at:)` (existants).
- Produces :
  ```swift
  // Preferences
  var lastLocation: (path: String, name: String)?     // clé "lastLocation", tableau [path, name]
  // ScanModel
  func loadSavedScans()                               // appelée une fois au lancement
  func flushUnsavedScans()                            // synchrone, appelée au willTerminate
  private func scheduleSave()                         // regroupe sur 3 s puis écrit unsavedRoots en tâche de fond
  ```
- Sauvegarde : à la fin d'un scan réussi (`scannedAt` posé), ajouter `treeRootPath` à `unsavedRoots` puis `scheduleSave()`. Après `propagateDeletion` / `reinstate` : `scheduleSave()`. L'écriture capture les `ScanResult` (des valeurs) sur l'acteur principal, puis encode, scelle et écrit dans un `Task.detached`.
- Éviction : dans `stashCurrentScan`, chaque entrée retirée par la boucle `while cache.count > cacheLimit` → `ScanVault.remove(rootPath:)` en tâche de fond. Un rescan forcé remplace naturellement le fichier de sa racine à la sauvegarde suivante.
- `loadSavedScans` : `Task.detached { ScanVault.loadAll() }`, puis sur l'acteur principal :
  - écarter les analyses dont la racine n'existe plus sur disque (fichier gardé) ;
  - écarter les analyses expirées (tâche 7 : `isExpired(_:)`), supprimer leur fichier, et noter leur date dans `expiredScans` ;
  - verser les autres dans `cache`, les plus récentes en dernier, sans doublon avec l'arbre à l'écran ou une entrée existante, en respectant `cacheLimit` ;
  - puis, si `result == nil && !isScanning`, et que `selectedRoot` est couvert par `tree(holding:)` → `show(found, at: selectedRoot)`.
- `lastLocation` : écrit dans `select(path:name:)` et dans `scan(path:force:)` quand `selectedRoot` change. Dans `SidebarView.task`, quand `model.selectedRoot == nil` : utiliser `lastLocation` si son chemin existe (`FileManager.default.fileExists`), sinon le premier volume (comportement actuel). Appeler `model.loadSavedScans()` au même endroit, avant la sélection.
- `SiltApp` : `NotificationCenter` `NSApplication.willTerminateNotification` → `model.flushUnsavedScans()`.

- [ ] **Step 1: Implement** ce qui précède.
- [ ] **Step 2: Build and launch** (skill `run-silt`) — exit 0, Silt tourne.
- [ ] **Step 3: Commit** — `git commit -m "Bring the last analyses back at launch"`

### Task 7: Ancienneté — seuil, mention, écran vide

**Files:**
- Modify: `App/Model/Preferences.swift`, `App/Model/ScanModel.swift`, `App/Views/Settings/ScanSettings.swift`, `App/Views/BrowserView.swift`

**Interfaces:**
- Produces :
  ```swift
  // Preferences
  static let scanMaxAgeChoices = [1, 3, 7, 14, 30]
  var scanMaxAgeDays: Int                     // défaut 7, clé "scanMaxAgeDays", remis à 7 par resetToDefaults
  private(set) var expiredScans: [String: Date]
  func noteExpired(root: String, scannedAt: Date)
  func forgetExpired(root: String)
  // ScanModel
  func isExpired(_ date: Date) -> Bool        // âge > scanMaxAgeDays jours
  var isOld: Bool                             // arbre à l'écran de plus de 24 h
  /// Pour l'écran vide : l'analyse expirée qui couvrait l'emplacement sélectionné, et le nom du parent si ce n'est pas lui.
  var expiredAnalysis: (date: Date, parentName: String?)?
  ```
- `tree(holding:)` : un candidat dont `isExpired(date)` est vrai est ignoré. `select` et `scan` purgent d'abord le cache des entrées expirées (fichier supprimé, `noteExpired`). L'arbre à l'écran n'est jamais retiré sous les yeux de l'utilisateur.
- `scan(path:force:)` réussi → `forgetExpired(root: path)`.
- `expiredAnalysis` : correspondance exacte de `selectedRoot` dans `expiredScans`, sinon la racine la plus longue qui en est un préfixe (`root == "/"` ou `selectedRoot.hasPrefix(root + "/")`). `parentName` = `QuickLocation.displayName(of: root)` quand `root != selectedRoot`.
- Textes exacts :
  - Réglages › Analyse, nouvelle section : `Picker("Ne plus afficher une analyse après", …)`, libellés `"1 jour"`, `"3 jours"`, `"7 jours"`, `"14 jours"`, `"30 jours"`, et `SettingHelp("Au-delà, l'emplacement repasse en « Prêt à analyser » : des chiffres trop anciens induiraient en erreur.")`.
  - Barre d'état, si `model.isOld` : `Text("ancienne")` en `.orange` juste après « analysé … » (et « avec « … » »), avec `.help("Cette analyse a plus d'un jour : les chiffres ont pu changer. Actualisez pour les mettre à jour.")`.
  - `EmptyStateView`, sous la description, si `model.expiredAnalysis` existe :
    - sans parent : `"Dernière analyse \(Format.age(since: date)), trop ancienne pour être affichée."`
    - avec parent : `"La dernière analyse de « \(parentName) », \(Format.age(since: date)), est trop ancienne pour être affichée."`

- [ ] **Step 1: Implement** ce qui précède.
- [ ] **Step 2: Build and launch** — exit 0, Silt tourne.
- [ ] **Step 3: Commit** — `git commit -m "Say when an analysis is old, and stop showing it past a limit"`

### Task 8: Vérification d'ensemble

- [ ] `cd DiskCore && swift test --skip firmlinks` : tous verts.
- [ ] Build Release (`-configuration Release`), exit 0 : le chemin chiffré compile.
- [ ] Build Debug et lancement (skill `run-silt`). Renan vérifie à la main les scénarios de la spec (« Tests attendus ») et les points 2 et 4 du Review Focus.
