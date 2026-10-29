import Foundation
import Observation

/// An undoable git action. Both closures run on the main actor and may throw.
struct UndoableAction: Sendable {
    let title: String
    let undo: @MainActor @Sendable () async throws -> Void
    let redo: @MainActor @Sendable () async throws -> Void
}

@MainActor
@Observable
final class UndoStack {
    private(set) var undoActions: [UndoableAction] = []
    private(set) var redoActions: [UndoableAction] = []

    var canUndo: Bool { !undoActions.isEmpty }
    var canRedo: Bool { !redoActions.isEmpty }
    var undoTitle: String? { undoActions.last?.title }
    var redoTitle: String? { redoActions.last?.title }

    func push(_ action: UndoableAction) {
        undoActions.append(action)
        if undoActions.count > 50 { undoActions.removeFirst() }
        redoActions.removeAll()
    }

    func popUndo() -> UndoableAction? {
        guard let action = undoActions.popLast() else { return nil }
        redoActions.append(action)
        return action
    }

    func popRedo() -> UndoableAction? {
        guard let action = redoActions.popLast() else { return nil }
        undoActions.append(action)
        return action
    }

    func clear() {
        undoActions.removeAll()
        redoActions.removeAll()
    }
}
