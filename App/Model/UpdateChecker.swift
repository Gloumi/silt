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

/// Launch-to-launch state that a Debug build must keep to itself.
///
/// A Debug build and the installed Silt read the same `app.silt.mac` defaults.
/// Built with another version number, or run without Full Disk Access of its
/// own — the usual case, the grant belongs to a binary — it would tell the
/// installed app that it had just been updated, or had never had the access,
/// and the next real update would go unexplained.
enum LaunchStateKey {
    static func scoped(_ key: String) -> String {
        #if DEBUG
        "debug." + key
        #else
        key
        #endif
    }
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
        static let lastCheck = LaunchStateKey.scoped("lastUpdateCheck")
        static let latest = LaunchStateKey.scoped("latestKnownRelease")
        static let skipped = LaunchStateKey.scoped("skippedVersion")
        static let lastLaunched = LaunchStateKey.scoped("lastLaunchedVersion")
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
