// NativeCheckbox.swift — tri-state NSButton wrapper for SwiftUI

import SwiftUI

// MARK: - NativeCheckbox

struct NativeCheckbox: NSViewRepresentable {
    let state: CheckState
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(checkboxWithTitle: "", target: context.coordinator,
                           action: #selector(Coordinator.tapped))
        btn.allowsMixedState = true
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentHuggingPriority(.required, for: .vertical)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        context.coordinator.action = action
        btn.state = state == .on ? .on : state == .off ? .off : .mixed
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}
