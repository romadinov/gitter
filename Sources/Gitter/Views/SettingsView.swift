import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gear") }
            ProfilesSettings(settings: settings)
                .tabItem { Label("Profiles", systemImage: "person.2") }
            TemplatesSettings(settings: settings)
                .tabItem { Label("Commit Templates", systemImage: "text.badge.plus") }
            EnvironmentSettings(settings: settings)
                .tabItem { Label("Environment", systemImage: "terminal") }
        }
        .frame(width: 560, height: 420)
    }
}

struct GeneralSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Remotes") {
                Toggle("Fetch remotes automatically in the background", isOn: $settings.autoFetchEnabled)
                Stepper("Every \(settings.autoFetchMinutes) minute\(settings.autoFetchMinutes == 1 ? "" : "s")", value: $settings.autoFetchMinutes, in: 1...120)
                    .disabled(!settings.autoFetchEnabled)
            }
            Section("Diff Viewer") {
                Toggle("Syntax coloring", isOn: $settings.syntaxHighlighting)
                Toggle("Show whitespace-only changes", isOn: $settings.showWhitespaceChanges)
                Slider(value: $settings.diffFontSize, in: 9...20, step: 1) { Text("Font size: \(Int(settings.diffFontSize)) pt") }
                TextField("External diff tool (git difftool --tool)", text: $settings.externalDiffTool, prompt: Text("opendiff, kaleidoscope, bbdiff, araxis, vscode …"))
            }
            Section("Commits") {
                Toggle("Sign commits (git commit -S)", isOn: $settings.signCommits)
                Toggle("Gitmoji picker in commit box", isOn: $settings.gitmojiEnabled)
            }
            Section("Git") {
                LabeledContent("Binary", value: GitRunner.gitPath)
            }
        }
        .formStyle(.grouped)
    }
}

struct ProfilesSettings: View {
    @Bindable var settings: AppSettings
    @State private var selected: UserProfile.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(settings.profiles) { profile in
                        VStack(alignment: .leading) {
                            Text(profile.label).fontWeight(.medium)
                            Text("\(profile.name) <\(profile.email)>").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(profile.id)
                    }
                }
                HStack {
                    Button { settings.profiles.append(UserProfile(label: "New Profile", name: "", email: "")); selected = settings.profiles.last?.id } label: { Image(systemName: "plus") }
                    Button { settings.profiles.removeAll { $0.id == selected }; selected = nil } label: { Image(systemName: "minus") }.disabled(selected == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
            .frame(minWidth: 200)
            if let index = settings.profiles.firstIndex(where: { $0.id == selected }) {
                Form {
                    TextField("Label", text: $settings.profiles[index].label)
                    TextField("Name", text: $settings.profiles[index].name)
                    TextField("Email", text: $settings.profiles[index].email)
                    TextField("Signing key (optional)", text: $settings.profiles[index].signingKey)
                    Text("Select a profile from the commit box to apply it to the current repository (git config user.name / user.email).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                .frame(minWidth: 280)
            } else {
                ContentUnavailableView("User Profiles", systemImage: "person.2", description: Text("Create profiles to switch committer identities per repository."))
                    .frame(minWidth: 280)
            }
        }
    }
}

struct TemplatesSettings: View {
    @Bindable var settings: AppSettings
    @State private var selected: CommitTemplate.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(settings.commitTemplates) { t in
                        Text(t.name).tag(t.id)
                    }
                }
                HStack {
                    Button { settings.commitTemplates.append(CommitTemplate(name: "New Template", subject: "", body: "")); selected = settings.commitTemplates.last?.id } label: { Image(systemName: "plus") }
                    Button { settings.commitTemplates.removeAll { $0.id == selected }; selected = nil } label: { Image(systemName: "minus") }.disabled(selected == nil)
                    Button("Import…") { importTemplate() }
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
            .frame(minWidth: 180)
            if let index = settings.commitTemplates.firstIndex(where: { $0.id == selected }) {
                Form {
                    TextField("Name", text: $settings.commitTemplates[index].name)
                    TextField("Subject", text: $settings.commitTemplates[index].subject)
                    TextEditor(text: $settings.commitTemplates[index].body).frame(height: 140).font(.body.monospaced())
                }
                .formStyle(.grouped)
                .frame(minWidth: 300)
            } else {
                ContentUnavailableView("Commit Templates", systemImage: "text.badge.plus", description: Text("Templates pre-fill the commit message. Import a .gitmessage file or create one here."))
                    .frame(minWidth: 300)
            }
        }
    }

    private func importTemplate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            settings.commitTemplates.append(CommitTemplate(name: url.lastPathComponent, subject: lines.first.map(String.init) ?? "", body: lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .newlines) : ""))
        }
    }
}

struct EnvironmentSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading) {
            Text("Environment variables passed to every git invocation (for example GIT_SSH_COMMAND, SSH_AUTH_SOCK for 1Password, HTTPS_PROXY).")
                .font(.caption).foregroundStyle(.secondary)
            Table($settings.environmentVariables) {
                TableColumn("Variable") { $v in TextField("NAME", text: $v.key).font(.body.monospaced()) }
                TableColumn("Value") { $v in TextField("value", text: $v.value).font(.body.monospaced()) }
            }
            HStack {
                Button { settings.environmentVariables.append(EnvironmentVariable(key: "", value: "")) } label: { Image(systemName: "plus") }
                Button { if !settings.environmentVariables.isEmpty { settings.environmentVariables.removeLast() } } label: { Image(systemName: "minus") }
                Spacer()
                Button("Use 1Password SSH Agent") {
                    settings.environmentVariables.removeAll { $0.key == "SSH_AUTH_SOCK" }
                    settings.environmentVariables.append(EnvironmentVariable(key: "SSH_AUTH_SOCK", value: "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock".replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)))
                }
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }
}
