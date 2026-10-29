import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// `gitter --repo <path>` or GITTER_REPO=<path> opens a repository at launch.
    static func launchRepositoryPath() -> String? {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--repo"), index + 1 < args.count { return args[index + 1] }
        if let flag = args.first(where: { $0.hasPrefix("--repo=") }) { return String(flag.dropFirst(7)) }
        return ProcessInfo.processInfo.environment["GITTER_REPO"]
    }

    let initialURL: URL?
    @State private var model = WindowModel()
    @State private var didHandleLaunch = false

    var body: some View {
        Group {
            if let repo = model.repository {
                RepositoryView(repo: repo, model: model)
                    .id(repo.id)
            } else {
                WelcomeView(model: model)
            }
        }
        .focusedSceneValue(\.windowModel, model)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.open(url: url) }
            return true
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.showClone) { CloneSheet(model: model) }
        .sheet(isPresented: $model.showRepositoryList) { RepositoryListView(model: model) }
        .onOpenURL { url in
            Task { await model.open(url: url) }
        }
        .task {
            guard !didHandleLaunch else { return }
            didHandleLaunch = true
            if let initialURL {
                await model.open(url: initialURL)
            } else if let path = Self.launchRepositoryPath() {
                await model.open(url: URL(fileURLWithPath: path))
            }
        }
    }
}
