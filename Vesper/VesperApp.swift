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

@main
struct VesperApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasCompletedStyleQuiz")  private var hasCompletedStyleQuiz  = false
    @State private var splashDone = false

    let modelContainer: ModelContainer = {
        do {
            return try VesperApp.makeModelContainer()
        } catch {
            // Migration failed — attempt to delete the old store file and retry.
            // This should only happen in extreme edge cases (corrupted store).
            appLogger.error("ModelContainer migration failed; attempting recovery: \(error.localizedDescription, privacy: .private)")
            VesperApp.deleteStoreFiles()
            if let fresh = try? VesperApp.makeModelContainer() {
                return fresh
            }
            // Last resort: in-memory container so the app launches rather than crashes.
            // User sees an empty library but can still use the app and re-add data.
            appLogger.error("Falling back to in-memory store; previous data is inaccessible.")
            if let memory = try? VesperApp.makeModelContainer(isStoredInMemoryOnly: true) {
                return memory
            }
            // If even the in-memory container fails, we have no graceful option.
            fatalError("Unable to initialize any ModelContainer: \(error)")
        }
    }()

    static func makeModelContainer(isStoredInMemoryOnly: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: VesperSchemaV9.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly)
        return try ModelContainer(for: schema, configurations: config)
    }

    private static func deleteStoreFiles() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else { return }
        let fileManager = FileManager.default
        let fallbackNames = ["default.store", "default.store-shm", "default.store-wal"]
        for name in fallbackNames {
            try? fileManager.removeItem(at: appSupport.appendingPathComponent(name))
        }

        guard let urls = try? fileManager.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls where url.lastPathComponent.hasPrefix("default.store") {
            try? fileManager.removeItem(at: url)
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

        FirebaseApp.configure()
        Task { await RemoteConfigService.shared.fetch() }

        // Detect iCloud-restored install: AppStorage flags roll forward via
        // NSUbiquitousKeyValueStore even after reinstall, but SwiftData doesn't.
        // If the user is "onboarded" but the store is empty, reset onboarding so
        // consent + style quiz run again instead of silently skipping them.
        if !isUITesting {
            VesperApp.resetOnboardingIfRestoredEmpty(container: modelContainer)
        }

        // Run data maintenance once on launch, off the main actor.
        Task.detached(priority: .background) { [modelContainer] in
            let ctx = ModelContext(modelContainer)
            DataMaintenance.prune(in: ctx)
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

    var body: some Scene {
        WindowGroup {
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
    }
}

// MARK: - App Check

class VesperAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> (any AppCheckProvider)? {
        AppAttestProvider(app: app)
    }
}
