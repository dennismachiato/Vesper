//
//  VesperApp.swift
//  Vesper
//

import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseAppCheck
import OSLog

private let appLogger = Logger(subsystem: "Vesper", category: "App")

private struct SplashView: View {
    var body: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(Color.vesperAccent)
                Text("Vesper")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .tracking(2)
            }
        }
    }
}

private struct DataRecoveryView: View {
    var body: some View {
        ZStack {
            LinearGradient.vesperBg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 42, weight: .thin))
                    .foregroundStyle(Color.vesperAccent)
                Text("Vesper couldn't open its local data")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Your Photos library was not changed. Close and reopen Vesper. If this continues, reinstalling resets Vesper's local learning data.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
        }
    }
}

@main
struct VesperApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasCompletedStyleQuiz")  private var hasCompletedStyleQuiz  = false
    @State private var splashDone = false

    let modelContainer: ModelContainer? = {
        do {
            return try VesperApp.makeModelContainer()
        } catch {
            // Do not delete the persistent store automatically. A migration bug
            // should not become silent data loss; keep the files in place and
            // launch with an in-memory store until a recovery path can be shown.
            appLogger.error("ModelContainer initialization failed; preserving persistent store and falling back: \(error.localizedDescription, privacy: .private)")
            if let memory = try? VesperApp.makeModelContainer(isStoredInMemoryOnly: true) {
                return memory
            }
            appLogger.fault("In-memory ModelContainer initialization also failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }()

    static func makeModelContainer(isStoredInMemoryOnly: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: VesperSchemaV10.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly)
        return try ModelContainer(for: schema, configurations: config)
    }

    private static func quarantineStoreFiles() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else { return }
        let fileManager = FileManager.default
        let quarantineDirectory = appSupport.appendingPathComponent("StoreRecovery-\(Int(Date().timeIntervalSince1970))")
        try? fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        let fallbackNames = ["default.store", "default.store-shm", "default.store-wal"]
        for name in fallbackNames {
            let source = appSupport.appendingPathComponent(name)
            let destination = quarantineDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }

        guard let urls = try? fileManager.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls where url.lastPathComponent.hasPrefix("default.store") {
            try? fileManager.moveItem(at: url, to: quarantineDirectory.appendingPathComponent(url.lastPathComponent))
        }
    }

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTestingSkipOnboarding")
        if isUITesting {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            UserDefaults.standard.set(true, forKey: "hasCompletedStyleQuiz")
        }

        // App Check: verifies requests come from the real Vesper app, not scripts.
        // Uses App Attest on real devices, falls back to Debug provider in simulators.
        #if targetEnvironment(simulator)
        let providerFactory = AppCheckDebugProviderFactory()
        #else
        let providerFactory = VesperAppCheckProviderFactory()
        #endif
        AppCheck.setAppCheckProviderFactory(providerFactory)

        let firebaseConfigured = VesperApp.configureFirebaseIfAvailable()
        if firebaseConfigured {
            Task { await RemoteConfigService.shared.fetch() }
        }

        // Detect iCloud-restored install: AppStorage flags roll forward via
        // NSUbiquitousKeyValueStore even after reinstall, but SwiftData doesn't.
        // If the user is "onboarded" but the store is empty, reset onboarding so
        // consent + style quiz run again instead of silently skipping them.
        if !isUITesting, let modelContainer {
            VesperApp.resetOnboardingIfRestoredEmpty(container: modelContainer)
        }
        VesperApp.protectStoreFiles()

        // Run data maintenance once on launch, off the main actor.
        if let modelContainer {
            Task.detached(priority: .background) {
                let ctx = ModelContext(modelContainer)
                DataMaintenance.prune(in: ctx)
            }
        }
    }

    @MainActor
    private static func resetOnboardingIfRestoredEmpty(container: ModelContainer) {
        let defaults = UserDefaults.standard
        let onboarded = defaults.bool(forKey: "hasCompletedOnboarding")
        guard onboarded else { return }

        // Cheap existence probe — fetchCount avoids loading any records.
        let ctx = ModelContext(container)
        let refCount  = (try? ctx.fetchCount(FetchDescriptor<ReferencePhoto>())) ?? 0
        let fbCount   = (try? ctx.fetchCount(FetchDescriptor<PhotoFeedback>()))  ?? 0
        let histCount = (try? ctx.fetchCount(FetchDescriptor<BatchHistory>()))   ?? 0
        if refCount == 0 && fbCount == 0 && histCount == 0 {
            appLogger.info("Detected onboarded-but-empty state; resetting onboarding.")
            defaults.set(false, forKey: "hasCompletedOnboarding")
            defaults.set(false, forKey: "hasCompletedStyleQuiz")
        }
    }

    @discardableResult
    private static func configureFirebaseIfAvailable() -> Bool {
        guard FirebaseApp.app() == nil else { return true }

        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: path) else {
            appLogger.warning("Firebase config file is missing; remote config and feedback uploads are disabled.")
            return false
        }

        FirebaseApp.configure(options: options)
        return true
    }

    private static func protectStoreFiles() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else { return }
        let fileManager = FileManager.default
        let names = ["default.store", "default.store-shm", "default.store-wal"]
        for name in names {
            let url = appSupport.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            } catch {
                appLogger.error("Failed to set store file protection: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                Group {
                    if !splashDone {
                        SplashView()
                            .transition(.opacity)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                    withAnimation(.easeInOut(duration: 0.35)) { splashDone = true }
                                }
                            }
                    } else if !hasCompletedOnboarding {
                        OnboardingView {
                            hasCompletedOnboarding = true
                        }
                    } else if !hasCompletedStyleQuiz {
                        StyleQuizView {
                            hasCompletedStyleQuiz = true
                        }
                    } else {
                        HomeView()
                    }
                }
                .modelContainer(modelContainer)
            } else {
                DataRecoveryView()
            }
        }
    }
}

// MARK: - App Check

class VesperAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> (any AppCheckProvider)? {
        AppAttestProvider(app: app) ?? DeviceCheckProvider(app: app)
    }
}
