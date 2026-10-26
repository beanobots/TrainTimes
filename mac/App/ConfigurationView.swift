import SwiftUI

/// The plist's EnvironmentVariables, edited as a draft and saved together.
struct ConfigurationView: View {
    @Environment(ServerModel.self) private var model
    /// Edits not yet saved: a value of "" leaves the key out, for the default.
    @State private var draft: [String: String] = [:]
    @State private var saving = false

    /// The plist's, or until it can be read, what launchd runs the server with (read-only).
    private var saved: [String: String] { model.plist?.environment ?? model.environment }

    private func current(_ setting: Setting) -> String {
        draft[setting.key] ?? saved[setting.key] ?? ""
    }

    private func isChanged(_ setting: Setting) -> Bool {
        guard let value = draft[setting.key] else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) != (saved[setting.key] ?? "")
    }

    private var changes: [String: String?] {
        var changes: [String: String?] = [:]
        for group in Setting.groups {
            for setting in group.settings where isChanged(setting) {
                changes[setting.key] = draft[setting.key]
            }
        }
        return changes
    }

    private var problems: [String] {
        Setting.groups.flatMap(\.settings).compactMap { setting in
            setting.problem(with: current(setting)).map { "\(setting.label): \($0)" }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.plist == nil {
                Banner(symbol: "lock.fill",
                       text: model.plistProblem ?? "Reading the plist…", color: .orange)
                    .padding([.horizontal, .top], 18)
            } else if !changes.isEmpty {
                saveBar.padding([.horizontal, .top], 18)
            }
            Form {
                ForEach(Setting.groups) { group in
                    Section {
                        ForEach(group.settings) { setting in
                            SettingRow(setting: setting, value: binding(for: setting),
                                       changed: isChanged(setting), problem: setting.problem(with: current(setting)))
                        }
                    } header: {
                        Text(group.title)
                    } footer: {
                        if let footer = group.footer {
                            Text(footer).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.plist == nil || saving)
        }
    }

    private var saveBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("^[\(changes.count) change](inflect: true) not saved. Saving rewrites the LaunchDaemon plist and restarts the server.")
                if let problem = problems.first {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button("Revert") { draft = [:] }
            Button(model.status?.isLoaded == true ? "Save & Restart" : "Save & Start") {
                Task {
                    saving = true
                    if await model.save(changes) { draft = [:] }
                    saving = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!problems.isEmpty || saving)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func binding(for setting: Setting) -> Binding<String> {
        Binding(get: { current(setting) }, set: { draft[setting.key] = $0 })
    }
}

private struct SettingRow: View {
    let setting: Setting
    @Binding var value: String
    let changed: Bool
    let problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            control
            HStack(spacing: 6) {
                Text(setting.key).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                if changed {
                    Text("Changed").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
                if let problem {
                    Text(problem).font(.caption2).foregroundStyle(.red)
                } else if let hint = setting.hint {
                    Text(hint).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch setting.kind {
        case .text:
            TextField(setting.label, text: $value)
        case .secret:
            SecureField(setting.label, text: $value)
        case .integer(_, let defaultValue):
            TextField(setting.label, text: $value, prompt: Text("\(defaultValue) (default)"))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        case .choice(let options, let defaultValue):
            Picker(setting.label, selection: Binding(get: { value.isEmpty ? defaultValue : value.lowercased() },
                                                     set: { value = $0 })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        case .toggle:
            Toggle(setting.label, isOn: Binding(get: { value == "1" }, set: { value = $0 ? "1" : "0" }))
        }
    }
}
