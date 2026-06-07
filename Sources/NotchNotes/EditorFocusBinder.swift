import SwiftUI
import AppKit

struct EditorFocusBinder: NSViewRepresentable {
    let state: EditorInteractionState

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        bind(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        bind(from: view)
    }

    private func bind(from view: NSView) {
        DispatchQueue.main.async {
            let container = view.superview
            let textView = container?.firstDescendant(ofType: NSTextView.self)
                ?? view.firstAncestorDescendant(ofType: NSTextView.self)
            state.bind(containerView: container, textView: textView)
        }
    }
}

extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }

        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }

    func firstAncestorDescendant<T: NSView>(ofType type: T.Type) -> T? {
        var current: NSView? = self

        while let view = current {
            if let match = view.firstDescendant(ofType: type) {
                return match
            }
            current = view.superview
        }

        return nil
    }
}
