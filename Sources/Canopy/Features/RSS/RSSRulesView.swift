import SwiftUI

struct RSSRulesView: View {
    @EnvironmentObject var rss: RSSManager
    @EnvironmentObject var engine: EngineSession
    @Environment(\.dismiss) private var dismiss

    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(rss.rules) { rule in
                    HStack {
                        Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(rule.enabled ? .green : .secondary)
                        Text(rule.name.isEmpty ? "(unnamed rule)" : rule.name).lineLimit(1)
                    }
                    .tag(rule.id)
                }
            }
            .frame(minWidth: 200)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        let r = RSSRule(name: "New Rule")
                        rss.addRule(r)
                        selection = r.id
                    } label: { Label("Add", systemImage: "plus") }
                    Button(role: .destructive) {
                        if let id = selection { rss.removeRule(id); selection = nil }
                    } label: { Label("Delete", systemImage: "trash") }
                    .disabled(selection == nil)
                }
            }
        } detail: {
            if let id = selection, let rule = rss.rules.first(where: { $0.id == id }) {
                RuleEditor(rule: rule)
                    .environmentObject(rss)
                    .environmentObject(engine)
                    .id(id)
            } else {
                ContentUnavailableView2(title: "No Rule Selected", systemImage: "slider.horizontal.3",
                                        message: "Select or add a rule to edit it.")
            }
        }
        .frame(width: 720, height: 460)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

private struct RuleEditor: View {
    @EnvironmentObject var rss: RSSManager
    @EnvironmentObject var engine: EngineSession
    @State var rule: RSSRule

    var body: some View {
        Form {
            Section {
                TextField("Rule name", text: $rule.name)
                Toggle("Enabled", isOn: $rule.enabled)
            }
            Section("Matching") {
                TextField("Must contain", text: $rule.mustContain)
                TextField("Must not contain", text: $rule.mustNotContain)
                Toggle("Use regular expressions", isOn: $rule.useRegex)
                Text(rule.useRegex
                     ? "Patterns are matched as regular expressions."
                     : "Space-separated terms must all be present (AND).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apply To Feeds") {
                if rss.feeds.isEmpty {
                    Text("No feeds yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(rss.feeds) { feed in
                        Toggle(feed.displayTitle, isOn: feedBinding(feed.url))
                    }
                    Text("Select none to apply to all feeds.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Action") {
                Picker("Assign category:", selection: $rule.assignCategory) {
                    Text("None").tag("")
                    ForEach(engine.library.categories) { Text($0.name).tag($0.name) }
                }
                Toggle("Add downloaded torrents paused", isOn: $rule.addPaused)
            }
        }
        .formStyle(.grouped)
        .onChange(of: rule) { rss.updateRule(rule) }
    }

    private func feedBinding(_ url: String) -> Binding<Bool> {
        Binding(
            get: { rule.affectedFeedURLs.contains(url) },
            set: { on in
                if on { if !rule.affectedFeedURLs.contains(url) { rule.affectedFeedURLs.append(url) } }
                else { rule.affectedFeedURLs.removeAll { $0 == url } }
            }
        )
    }
}
