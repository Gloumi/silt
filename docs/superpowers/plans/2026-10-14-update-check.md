# Vérification des mises à jour — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Silt signale une release GitHub plus récente et donne le geste exact pour l'installer (Homebrew ou DMG), puis aide à rétablir l'accès complet au disque que la mise à jour a fait sauter.

**Architecture:** Un type pur `ReleaseVersion` (DiskCore, testé) compare les numéros. Un modèle `UpdateChecker` (`@Observable @MainActor`, singleton) interroge l'API GitHub au plus une fois par 24 h et garde son état dans `UserDefaults`. L'interface se branche dessus : capsule en pied de barre latérale, `UpdateSheet`, section dans Réglages › Général, élément du menu Silt. `WelcomeSheet` gagne une variante « après mise à jour ».

**Tech Stack:** Swift 6 (concurrence stricte), SwiftUI macOS 15, `URLSession`, swift-testing (DiskCore), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-14-update-check-design.md`

## Global Constraints

- Aucune dépendance ajoutée, aucun changement de CI.
- Silt ne télécharge ni n'installe rien : il ouvre une page ou montre une commande.
- Une seule requête : `GET https://api.github.com/repos/Gloumi/silt/releases/latest`, en-têtes `Accept: application/vnd.github+json` et `User-Agent: Silt/<version>`.
- Vérification automatique au plus une fois par 24 h, jamais bloquante, échecs silencieux.
- Interface entièrement en français ; commentaires et commits en anglais, dans le style du code voisin (commentaires qui expliquent le *pourquoi*).
- Après ajout de fichiers dans `App/` : `xcodegen generate` avant de compiler, sinon ils ne sont pas compilés.
- Juger un build sur son code de sortie (voir skill `run-silt`), et s'arrêter à `open` : Renan teste lui-même.

## Écarts assumés par rapport à la spec

- Les états `lastUpdateCheck`, `latestKnownRelease`, `skippedVersion`, `lastLaunchedVersion` vivent dans `UpdateChecker` (ses propres clés `UserDefaults`) et non dans `Preferences` : ce sont des états, pas des réglages. Seul `checksForUpdates` va dans `Preferences`.
- La variante « après mise à jour » de l'accueil exige aussi que l'accès ait été accordé au lancement précédent (clé `hadFullDiskAccess`) : sans cela on dirait « macOS a retiré l'accès » à quelqu'un qui ne l'a jamais donné. Clé absente (premier lancement de la version qui l'introduit) = supposée vraie.
- 0.5.0 n'écrit pas `lastLaunchedVersion`. Au premier lancement de la version qui l'introduit, une clé absente avec `hasSeenWelcome == true` compte comme une mise à jour, faute de quoi la toute première mise à jour réelle passerait inaperçue.

## Review Focus

1. **Hors ligne au lancement** : aucune erreur visible ; la capsule d'une release déjà connue reste affichée.
2. **Limite de taux GitHub (403/429) sur une vérification manuelle** : message lisible (« GitHub limite les requêtes… »), pas « réponse inattendue ».
3. **Build locale plus récente que la dernière release** (0.6.0 compilée avant le tag) : aucune capsule, « À jour » dans les réglages.
4. **Fenêtre principale fermée quand le menu trouve une mise à jour** : la fenêtre se rouvre et la feuille s'y affiche.
5. **Premier lancement de la version qui livre la fonctionnalité** (pas de `lastLaunchedVersion`) : traité comme une mise à jour si l'accueil a déjà été vu.

Le point 3 est épinglé par un test de `ReleaseVersion` (égalité ≠ plus récent) ; les autres sont des étapes de vérification manuelle des tâches 2 à 4.

---

## Fichiers

| Fichier | Rôle |
|---|---|
| `DiskCore/Sources/DiskCore/System/ReleaseVersion.swift` (créé) | lecture et comparaison des numéros de version |
| `DiskCore/Tests/DiskCoreTests/ReleaseVersionTests.swift` (créé) | tests |
| `App/Model/UpdateChecker.swift` (créé) | requête, cadence, état persistant, détection Homebrew |
| `App/Model/Preferences.swift` (modifié) | `checksForUpdates` |
| `App/Model/FullDiskAccess.swift` (modifié) | `wasRevoked(byUpdate:)` |
| `App/Model/ScanModel.swift` (modifié) | `welcomeAfterUpdate` |
| `App/Views/UpdateSheet.swift` (créé) | la feuille |
| `App/Views/SidebarView.swift` (modifié) | capsule |
| `App/Views/Settings/GeneralSettings.swift` (modifié) | section « Mises à jour » |
| `App/Views/WelcomeSheet.swift` (modifié) | variante après mise à jour |
| `App/SiltApp.swift` (modifié) | démarrage, menu, feuille, URL « Code source » |

---

### Task 1: `ReleaseVersion`

**Files:**
- Create: `DiskCore/Sources/DiskCore/System/ReleaseVersion.swift`
- Test: `DiskCore/Tests/DiskCoreTests/ReleaseVersionTests.swift`

**Interfaces:**
- Produces: `public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible` ; `public init?(_ string: String)` ; `description` = la chaîne sans le `v` initial (`"v0.6.0"` → `"0.6.0"`).

- [ ] **Step 1: Write the failing test**

```swift
import Testing

@testable import DiskCore

@Suite("Release versions")
struct ReleaseVersionTests {

    @Test("Compares numerically, not as text")
    func numeric() throws {
        let newer = try #require(ReleaseVersion("0.10.0"))
        let older = try #require(ReleaseVersion("0.9.2"))
        #expect(newer > older)
    }

    @Test("The same release is not newer than itself")
    func same() throws {
        let a = try #require(ReleaseVersion("v0.6.0"))
        let b = try #require(ReleaseVersion("0.6.0"))
        #expect(!(a > b))
        #expect(a == b)
    }

    @Test("Missing components count as zero")
    func missing() throws {
        #expect(ReleaseVersion("1.2") == ReleaseVersion("1.2.0"))
        let short = try #require(ReleaseVersion("1.2"))
        let patch = try #require(ReleaseVersion("1.2.1"))
        #expect(short < patch)
        #expect(Set([short, try #require(ReleaseVersion("1.2.0"))]).count == 1)
    }

    @Test("Keeps the spelling it was given, minus the v")
    func spelling() {
        #expect(ReleaseVersion("v0.6.0")?.description == "0.6.0")
        #expect(ReleaseVersion("1.2")?.description == "1.2")
    }

    @Test("Refuses what it cannot read",
          arguments: ["", "v", "abc", "1.2-beta", "1..2", "1.2.", "+1.2", "1.٢"])
    func refuses(_ text: String) {
        #expect(ReleaseVersion(text) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd DiskCore && swift test --filter ReleaseVersion`
Expected: échec de compilation, `cannot find 'ReleaseVersion' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// A release number as the tags spell it: "v0.10.0", "0.10.0", "1.2".
///
/// Compared component by component, numerically. As strings, "0.10.0" sorts
/// before "0.9.2" — which is how an update checker ends up telling people to
/// downgrade. Anything with letters past the optional leading "v" is refused
/// rather than guessed at: a pre-release tag is not an update to offer.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {

    /// Trailing zeros dropped, so that 1.2 and 1.2.0 — the same release —
    /// compare and hash alike.
    private let components: [Int]
    public let description: String

    public init?(_ string: String) {
        var text = Substring(string)
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            // ASCII digits only: Int() would take "+1", and Character.isNumber
            // takes "٢".
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        guard !numbers.isEmpty else { return nil }
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        components = numbers
        description = String(text)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.components == rhs.components
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(components)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd DiskCore && swift test --filter ReleaseVersion`
Expected: tous les tests de la suite « Release versions » passent. Puis `swift test --skip firmlinks` : toute la suite passe.

- [ ] **Step 5: Commit**

```bash
git add DiskCore/Sources/DiskCore/System/ReleaseVersion.swift DiskCore/Tests/DiskCoreTests/ReleaseVersionTests.swift
git commit -m "Read release numbers the way they are meant"
```

---

### Task 2: `UpdateChecker` et le réglage

**Files:**
- Create: `App/Model/UpdateChecker.swift`
- Modify: `App/Model/Preferences.swift` (enum `Key`, propriétés, `init`, `resetToDefaults`)
- Modify: `App/SiltApp.swift` (`.task` de la fenêtre principale)

**Interfaces:**
- Consumes: `ReleaseVersion` (Task 1).
- Produces:
  - `struct Release: Codable, Equatable, Identifiable, Sendable { tag: String; page: URL; publishedAt: Date; id: String; version: ReleaseVersion?; displayVersion: String }`
  - `UpdateChecker.shared`, `UpdateChecker.repository: URL`, `UpdateChecker.installedWithHomebrew: Bool` (static)
  - instance : `currentVersionText: String`, `state: State` (`.idle`, `.checking`, `.checked(Date)`, `.failed(String)`), `newerRelease: Release?`, `offeredRelease: Release?`, `sheetRelease: Release?` (lecture/écriture), `statusText: String`, `launchedAfterUpdate: Bool`, `start()`, `check(manual: Bool) async`, `skip(_ release: Release)`
  - `Preferences.shared.checksForUpdates: Bool`

- [ ] **Step 1: Ajouter `checksForUpdates` à `Preferences`**

Dans `enum Key` : `static let checksForUpdates = "checksForUpdates"`.

Après `hasSeenWelcome` :

```swift
    /// The daily request to GitHub. On by default: an update nobody hears of is
    /// one nobody installs, and the request carries nothing but the version.
    var checksForUpdates: Bool {
        didSet { UserDefaults.standard.set(checksForUpdates, forKey: Key.checksForUpdates) }
    }
```

Dans `init`, remplacer le `register` par :

```swift
        defaults.register(defaults: [
            Key.collapseDependencies: true,
            Key.checksForUpdates: true,
        ])
```

et ajouter après `hasSeenWelcome = …` : `checksForUpdates = defaults.bool(forKey: Key.checksForUpdates)`.

Dans `resetToDefaults()`, ajouter `checksForUpdates = true`.

- [ ] **Step 2: Créer `App/Model/UpdateChecker.swift`**

```swift
import AppKit
import DiskCore
import Foundation
import Observation

/// A release published on GitHub — as much of it as the update sheet shows.
struct Release: Codable, Equatable, Identifiable, Sendable {
    let tag: String
    let page: URL
    let publishedAt: Date

    var id: String { tag }
    var version: ReleaseVersion? { ReleaseVersion(tag) }
    var displayVersion: String { version?.description ?? tag }
}

/// Whether GitHub has a newer Silt than this one.
///
/// Says so and stops there. Installing in place is what Sparkle is for, and it
/// would promise a smoothness the unsigned builds cannot keep: macOS ties Full
/// Disk Access to the exact binary of an ad-hoc signed app, so every update
/// loses it. Until there is a Developer ID, the honest offer is the gesture
/// that installs the update — and a word about the permission afterwards.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let repository = URL(string: "https://github.com/Gloumi/silt")!
    /// Drafts and pre-releases are left out by this endpoint, which is exactly
    /// the set of releases worth telling anyone about.
    private static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/Gloumi/silt/releases/latest")!
    private static let interval: TimeInterval = 24 * 3600

    enum State: Equatable {
        case idle, checking
        case checked(Date)
        case failed(String)
    }

    private enum Key {
        static let lastCheck = "lastUpdateCheck"
        static let latest = "latestKnownRelease"
        static let skipped = "skippedVersion"
        static let lastLaunched = "lastLaunchedVersion"
    }

    let currentVersionText: String
    private let currentVersion: ReleaseVersion?
    /// This launch is the first of a version other than the last one run here.
    let launchedAfterUpdate: Bool

    private(set) var state: State = .idle
    private(set) var lastCheck: Date? {
        didSet { UserDefaults.standard.set(lastCheck, forKey: Key.lastCheck) }
    }
    /// Kept across launches so the sidebar can say "available" while offline.
    private(set) var latest: Release? {
        didSet {
            UserDefaults.standard.set(
                latest.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.latest)
        }
    }
    private(set) var skippedTag: String? {
        didSet { UserDefaults.standard.set(skippedTag, forKey: Key.skipped) }
    }
    /// The release whose sheet is up, wherever it was asked for from.
    var sheetRelease: Release?

    private var loop: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        currentVersionText = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        currentVersion = ReleaseVersion(currentVersionText)
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
        latest = defaults.data(forKey: Key.latest)
            .flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
        skippedTag = defaults.string(forKey: Key.skipped)

        if let previous = defaults.string(forKey: Key.lastLaunched) {
            launchedAfterUpdate = previous != currentVersionText
        } else {
            // 0.5.0 recorded nothing. A welcome already seen means some earlier
            // version ran here — and the first update is the one that matters.
            launchedAfterUpdate = Preferences.shared.hasSeenWelcome
        }
        defaults.set(currentVersionText, forKey: Key.lastLaunched)
    }

    /// The latest release, if it is newer than this build. A local build ahead
    /// of the last tag is not offered a downgrade.
    var newerRelease: Release? {
        guard let latest, let theirs = latest.version, let ours = currentVersion,
              theirs > ours else { return nil }
        return latest
    }

    /// What the sidebar offers: the newer release, unless it was skipped.
    var offeredRelease: Release? {
        guard let release = newerRelease, release.tag != skippedTag else { return nil }
        return release
    }

    func skip(_ release: Release) {
        skippedTag = release.tag
    }

    /// Wakes hourly and checks when a day has gone by since the last success.
    /// Hourly rather than one 24 h sleep: a Mac that slept through the night
    /// would otherwise wait another full day.
    func start() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                if Preferences.shared.checksForUpdates, isDue {
                    await check(manual: false)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private var isDue: Bool {
        guard let lastCheck else { return true }
        return Date().timeIntervalSince(lastCheck) >= Self.interval
    }

    /// One request. An automatic check fails in silence and leaves the last
    /// success standing, so the next cycle simply tries again; a check someone
    /// asked for says what went wrong.
    func check(manual: Bool) async {
        guard state != .checking else { return }
        state = .checking
        do {
            latest = try await fetchLatest()
            let now = Date()
            lastCheck = now
            state = .checked(now)
        } catch {
            state = manual
                ? .failed(Self.message(for: error))
                : lastCheck.map(State.checked) ?? .idle
        }
    }

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: URL
        let publishedAt: Date

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
        }
    }

    private enum CheckError: Error {
        case status(Int)
        case unreadableTag
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Silt/\(currentVersionText)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CheckError.status(status) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)
        // A tag that cannot be read is never presented as an update.
        guard ReleaseVersion(payload.tagName) != nil else { throw CheckError.unreadableTag }
        return Release(tag: payload.tagName, page: payload.htmlURL,
                       publishedAt: payload.publishedAt)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case is URLError:
            "Connexion à GitHub impossible."
        case CheckError.status(403), CheckError.status(429):
            "GitHub limite les requêtes ; réessayez dans une heure."
        default:
            "Réponse inattendue de GitHub."
        }
    }

    /// The one line the settings show under the toggle.
    var statusText: String {
        if state == .checking { return "Recherche…" }
        if let newerRelease { return "Silt \(newerRelease.displayVersion) est disponible." }
        if case .failed(let message) = state { return message }
        guard let lastCheck else { return "Jamais vérifié." }
        let when = lastCheck.formatted(.relative(presentation: .named))
        return "À jour — vérifié \(when)."
    }

    /// Homebrew keeps one folder per installed cask; its presence is how a
    /// cask install tells itself apart from a dragged-in DMG.
    static var installedWithHomebrew: Bool {
        ["/opt/homebrew/Caskroom/silt", "/usr/local/Caskroom/silt"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }
}
```

- [ ] **Step 3: Démarrer la vérification au lancement**

Dans `App/SiltApp.swift`, sur le `ContentView` de la scène `Window("Silt", id: "main")`, ajouter après `.task { await model.refreshRestorable() }` :

```swift
                // Owns its own cadence; calling it again when the window is
                // reopened is a no-op.
                .task { UpdateChecker.shared.start() }
```

- [ ] **Step 4: Construire**

```sh
xcodegen generate
xcodebuild -project Silt.xcodeproj -scheme Silt -configuration Debug build -quiet \
  > "$TMPDIR/silt-build.log" 2>&1; echo "exit=$?"
grep -E "error:" "$TMPDIR/silt-build.log" | grep -v -i coresimulator
```

Expected: `exit=0`, aucune vraie erreur. Puis vérifier la requête à la main : `curl -s -H 'Accept: application/vnd.github+json' https://api.github.com/repos/Gloumi/silt/releases/latest | grep -E '"(tag_name|html_url|published_at)"' | head -3` doit montrer `v0.5.0` et une date ISO 8601 sans fractions de seconde (sinon `.iso8601` échoue au décodage — dans ce cas, décoder la date en `String` et passer par `ISO8601DateFormatter` avec `.withFractionalSeconds`).

- [ ] **Step 5: Commit**

```bash
git add App/Model/UpdateChecker.swift App/Model/Preferences.swift App/SiltApp.swift
git commit -m "Ask GitHub once a day whether there is a newer Silt"
```

---

### Task 3: L'interface — feuille, capsule, réglages, menu

**Files:**
- Create: `App/Views/UpdateSheet.swift`
- Modify: `App/Views/SidebarView.swift:141-155` (le `safeAreaInset` du bas)
- Modify: `App/Views/Settings/GeneralSettings.swift`
- Modify: `App/SiltApp.swift` (commands : `.appInfo`, lien « Code source » ; `ContentView.body` : la feuille)

**Interfaces:**
- Consumes: tout ce que Task 2 produit.
- Produces: `struct UpdateSheet: View { init(release: Release, onDismiss: @escaping () -> Void) }`.

- [ ] **Step 1: Créer `App/Views/UpdateSheet.swift`**

```swift
import AppKit
import SwiftUI

/// A newer release, and the one gesture that installs it on this Mac.
///
/// Two gestures, because Silt arrives two ways. A cask install is upgraded by
/// Homebrew — downloading the DMG over it would leave `brew` believing in a
/// version that is no longer there. A DMG install goes back to the release
/// page, with the Gatekeeper detour spelled out since the build is unsigned.
struct UpdateSheet: View {
    let release: Release
    let onDismiss: () -> Void

    private let checker = UpdateChecker.shared
    private let viaHomebrew = UpdateChecker.installedWithHomebrew
    private let command = "brew upgrade --cask silt"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Silt \(release.displayVersion) est disponible")
                        .font(.title3.weight(.semibold))
                    Text("Vous utilisez la \(checker.currentVersionText) · publiée le \(release.publishedAt.formatted(date: .long, time: .omitted))")
                        .foregroundStyle(.secondary)
                }
            }

            Link("Notes de version", destination: release.page)

            if viaHomebrew { homebrew } else { download }

            Text("Après la mise à jour, macOS retire à Silt l'accès complet au disque. Silt vous guidera pour le lui rendre.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Button("Ignorer cette version") {
                    checker.skip(release)
                    onDismiss()
                }
                Spacer()
                Button("Plus tard", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                if !viaHomebrew {
                    Button("Ouvrir la page de téléchargement") {
                        NSWorkspace.shared.open(release.page)
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var homebrew: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Silt a été installé avec Homebrew. Dans le Terminal :")
                .font(.callout)
            HStack {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
                Button(copied ? "Copié" : "Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var download: some View {
        Text("Téléchargez le DMG et remplacez Silt dans Applications. La build n'étant pas signée, macOS refusera le premier lancement : ouvrez alors Réglages Système › Confidentialité et sécurité, et cliquez sur « Ouvrir quand même ».")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
```

- [ ] **Step 2: Présenter la feuille depuis la fenêtre principale**

Dans `ContentView` (`App/SiltApp.swift`), ajouter la propriété :

```swift
    @Bindable private var updates = UpdateChecker.shared
```

et sur le `VStack(spacing: 0)` de `body` :

```swift
        // Up here so the sidebar's capsule and the menu item open the same
        // sheet, over the window that has the browser in it.
        .sheet(item: $updates.sheetRelease) { release in
            UpdateSheet(release: release) { updates.sheetRelease = nil }
        }
```

- [ ] **Step 3: La capsule en pied de barre latérale**

Dans `SidebarView`, ajouter `private let updates = UpdateChecker.shared` à côté des autres propriétés, puis dans le `HStack` du `safeAreaInset(edge: .bottom…)`, avant le `Spacer()` :

```swift
                // Next to the gear rather than in a banner: an update is worth
                // knowing about, not worth interrupting a scan for.
                if let release = updates.offeredRelease {
                    Button { updates.sheetRelease = release } label: {
                        Text("Silt \(release.displayVersion) disponible")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(.tint)
                            .background(Color.accentColor.opacity(0.15), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .help("Voir la mise à jour")
                }
```

- [ ] **Step 4: L'élément de menu et le lien « Code source »**

Dans `.commands` de `SiltApp`, ajouter :

```swift
            CommandGroup(after: .appInfo) { CheckForUpdates() }
```

et remplacer `Link("Code source", destination: URL(string: "https://github.com/")!)` par `Link("Code source", destination: UpdateChecker.repository)`.

À côté de `OpenSettings`, ajouter :

```swift
/// « Rechercher les mises à jour… », under « À propos de Silt » where every Mac
/// app keeps it. A skipped version is shown anyway: asking is overriding.
private struct CheckForUpdates: View {
    @Environment(\.openWindow) private var openWindow
    private let checker = UpdateChecker.shared

    var body: some View {
        Button("Rechercher les mises à jour…") {
            Task {
                await checker.check(manual: true)
                if let release = checker.newerRelease {
                    // The sheet hangs off the main window, which may be closed.
                    openWindow(id: "main")
                    checker.sheetRelease = release
                } else {
                    let alert = NSAlert()
                    if case .failed(let message) = checker.state {
                        alert.messageText = "Recherche impossible"
                        alert.informativeText = message
                    } else {
                        alert.messageText = "Silt est à jour"
                        alert.informativeText = "La version \(checker.currentVersionText) est la plus récente."
                    }
                    alert.runModal()
                }
            }
        }
        .disabled(checker.state == .checking)
    }
}
```

- [ ] **Step 5: La section des réglages**

Dans `GeneralSettings`, ajouter les propriétés :

```swift
    private let updates = UpdateChecker.shared
    /// Its own sheet rather than the main window's: the one asked for from
    /// here should open in front of here.
    @State private var shownRelease: Release?
```

Une section entre « Taille affichée » et « Réglages » :

```swift
            Section {
                Toggle("Rechercher les mises à jour automatiquement",
                       isOn: $preferences.checksForUpdates)
                LabeledContent {
                    HStack {
                        if let release = updates.newerRelease {
                            Button("Voir…") { shownRelease = release }
                        }
                        Button("Rechercher maintenant") {
                            Task { await updates.check(manual: true) }
                        }
                        .disabled(updates.state == .checking)
                    }
                } label: {
                    Text("Version \(updates.currentVersionText)")
                    Text(updates.statusText)
                }
                SettingHelp("Une requête anonyme vers GitHub une fois par jour ; rien d'autre n'est envoyé. Silt ne télécharge rien lui-même.")
            }
```

et, à côté du `.confirmationDialog` :

```swift
        .sheet(item: $shownRelease) { release in
            UpdateSheet(release: release) { shownRelease = nil }
        }
```

- [ ] **Step 6: Construire et lancer avec une version ancienne simulée**

```sh
xcodegen generate
xcodebuild -project Silt.xcodeproj -scheme Silt -configuration Debug build -quiet \
  MARKETING_VERSION=0.4.0 > "$TMPDIR/silt-build.log" 2>&1; echo "exit=$?"
grep -E "error:" "$TMPDIR/silt-build.log" | grep -v -i coresimulator
APP="$(xcodebuild -project Silt.xcodeproj -scheme Silt -configuration Debug \
       -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/Silt.app"
pkill -x Silt; sleep 1; open "$APP"; sleep 4; pgrep -x Silt >/dev/null && echo "Silt tourne"
```

Expected: `exit=0`, Silt tourne. S'arrêter là ; Renan vérifie : capsule « Silt 0.5.0 disponible », feuille (variante Homebrew ou DMG), menu, section des réglages, réseau coupé → « Connexion à GitHub impossible. » sur « Rechercher maintenant » seulement.

- [ ] **Step 7: Commit**

```bash
git add App/Views/UpdateSheet.swift App/Views/SidebarView.swift App/Views/Settings/GeneralSettings.swift App/SiltApp.swift
git commit -m "Say when a newer Silt is out, and how to get it"
```

---

### Task 4: L'accès complet au disque après une mise à jour

**Files:**
- Modify: `App/Model/FullDiskAccess.swift`
- Modify: `App/Model/ScanModel.swift:632` (à côté de `showsWelcome`)
- Modify: `App/Views/WelcomeSheet.swift`
- Modify: `App/SiltApp.swift` (`.task` de la fenêtre principale, `.sheet` de `WelcomeSheet`)

**Interfaces:**
- Consumes: `UpdateChecker.shared.launchedAfterUpdate` (Task 2).
- Produces: `FullDiskAccess.wasRevoked(byUpdate: Bool) -> Bool` ; `ScanModel.welcomeAfterUpdate: Bool` ; `WelcomeSheet(unreadableCount:afterUpdate:onDismiss:)`.

- [ ] **Step 1: `FullDiskAccess.wasRevoked(byUpdate:)`**

Dans `enum FullDiskAccess`, après `isGranted` :

```swift
    /// Whether an update just took the access away, recording this launch's
    /// answer for the next one.
    ///
    /// An ad-hoc signed app is known to TCC by the hash of its binary, and an
    /// update is a new binary: the old entry stays in the list, ticked, and
    /// applies to nothing. Only worth saying when the previous launch had the
    /// access — telling someone it was "taken away" when they never gave it
    /// would be wrong. A missing record (the first launch that keeps one) is
    /// read as granted, so the first update is not the one that goes unsaid.
    static func wasRevoked(byUpdate updated: Bool) -> Bool {
        let key = "hadFullDiskAccess"
        let defaults = UserDefaults.standard
        let had = defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
        let has = isGranted
        defaults.set(has, forKey: key)
        return updated && had && !has
    }
```

- [ ] **Step 2: `ScanModel.welcomeAfterUpdate`**

Sous `var showsWelcome = …` :

```swift
    /// The welcome sheet is up because an update cost the app its access —
    /// which wants different words from a first launch.
    var welcomeAfterUpdate = false
```

- [ ] **Step 3: Déclencher au lancement**

Dans `SiltApp`, remplacer le `.task { UpdateChecker.shared.start() }` de Task 2 par :

```swift
                // Owns its own cadence; calling it again when the window is
                // reopened is a no-op. The access check runs once per launch
                // for the same reason the welcome flag does.
                .task {
                    let updates = UpdateChecker.shared
                    // Called unconditionally: it also records this launch's
                    // answer, which the next launch needs even when the
                    // welcome has not been seen yet.
                    let revoked = FullDiskAccess.wasRevoked(
                        byUpdate: updates.launchedAfterUpdate)
                    if revoked, Preferences.shared.hasSeenWelcome {
                        model.welcomeAfterUpdate = true
                        model.showsWelcome = true
                    }
                    updates.start()
                }
```

Et dans la `.sheet` de `WelcomeSheet` de `ContentView` :

```swift
            WelcomeSheet(
                unreadableCount: model.result?.unreadablePaths.count ?? 0,
                afterUpdate: model.welcomeAfterUpdate
            ) {
                model.showsWelcome = false
                model.welcomeAfterUpdate = false
                Preferences.shared.hasSeenWelcome = true
            }
```

- [ ] **Step 4: La variante de `WelcomeSheet`**

Ajouter `var afterUpdate = false` après `let unreadableCount: Int` (avant `onDismiss`, pour que l'initialiseur mémberwise accepte `afterUpdate:` entre les deux).

Dans l'en-tête, remplacer les deux `Text` du titre et du sous-titre par :

```swift
                    Text(granted ? "Accès complet accordé"
                         : afterUpdate ? "Silt a été mis à jour"
                         : "Accès complet au disque")
                        .font(.title3.weight(.semibold))
                    Text(granted
                         ? "Silt peut analyser l'intégralité de votre disque."
                         : afterUpdate
                         ? "macOS lui a retiré l'accès complet au disque."
                         : "Sans cette autorisation, certains dossiers restent invisibles.")
                        .foregroundStyle(.secondary)
```

Dans `steps`, remplacer l'étape 2 :

```swift
            step(2, afterUpdate
                 ? "Silt y est encore coché, mais l'autorisation visait l'ancienne version : retirez Silt avec −, puis remettez-le avec + ou en le faisant glisser depuis le Finder."
                 : "Activez Silt dans la liste, ou faites-la glisser depuis le Finder.")
```

- [ ] **Step 5: Construire et lancer**

```sh
xcodebuild -project Silt.xcodeproj -scheme Silt -configuration Debug build -quiet \
  > "$TMPDIR/silt-build.log" 2>&1; echo "exit=$?"
grep -E "error:" "$TMPDIR/silt-build.log" | grep -v -i coresimulator
APP="$(xcodebuild -project Silt.xcodeproj -scheme Silt -configuration Debug \
       -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/Silt.app"
pkill -x Silt; sleep 1; open "$APP"; sleep 4; pgrep -x Silt >/dev/null && echo "Silt tourne"
```

Expected: `exit=0`, Silt tourne. Le build Debug (0.5.0, 1er lancement avec `lastLaunchedVersion` absent mais accueil déjà vu, accès sans doute non accordé à cette copie) doit afficher la variante « Silt a été mis à jour ». Relancer : la feuille ne revient pas. Renan vérifie.

- [ ] **Step 6: Commit**

```bash
git add App/Model/FullDiskAccess.swift App/Model/ScanModel.swift App/Views/WelcomeSheet.swift App/SiltApp.swift
git commit -m "Tell people an update cost Silt its disk access, and how to give it back"
```

---

## Après le plan

- Vérification sur une vraie mise à jour 0.5.0 → 0.6.0 (installée) : confirmer que retirer/remettre est le bon geste et ajuster le texte de l'étape 2 sinon.
- Ajouter au cask `auto_updates false` n'est pas nécessaire (valeur par défaut) ; rien à changer côté Homebrew.
