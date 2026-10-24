import AppKit
import BezierCore
import Observation
import SwiftUI

/// Where a dragged tab would land on a row.
enum DropZone: Equatable {
    /// Reorder: just above or below the row.
    case above, below
    /// Today rows: split onto the left or right edge, group in the middle.
    case left, right, center
    /// Folders (inside) and the New Tab row (top of Today).
    case into

    /// The top and bottom quarter of a row reorder. In between: Today rows split on their outer
    /// ~28% and group in the middle; folders take the tab in; pinned rows split the difference.
    static func zone(at point: CGPoint, in frame: CGRect, kind: DropTarget.Kind) -> DropZone {
        if kind == .todayTop { return .into }
        let y = (point.y - frame.minY) / max(frame.height, 1)
        if y < 0.25 { return .above }
        if y > 0.75 { return .below }
        switch kind {
        case .today:
            let x = (point.x - frame.minX) / max(frame.width, 1)
            return x < 0.28 ? .left : (x > 0.72 ? .right : .center)
        case .folder, .todayTop: return .into
        case .pinned: return y < 0.5 ? .above : .below
        }
    }
}

/// A row that accepts drops: a Today tab or Split View row (left edge = first pane, right edge
/// = last pane), a pinned tab, a folder, or the New Tab row.
struct DropTarget: Equatable {
    enum Kind: Equatable { case today, pinned, folder, todayTop }
    var frame: CGRect
    var kind: Kind
    var leftTabID: UUID
    var rightTabID: UUID
    /// The row view that registered it. A tab that moves (out of a group, say) gets a new row
    /// whose registration the old row's teardown must not remove.
    var owner: UUID
}

/// What a released drag does: land on a row's edge or middle, or leave the dragged tab's group.
enum SidebarDrop {
    case onto(DropTarget, DropZone)
    case outOfGroup(below: Bool)
}

/// A grouped tab pulled past its group's top or bottom edge.
struct GroupExit: Equatable {
    var groupID: UUID
    var below: Bool
}

/// Live sidebar drag, shared by every row (spring-driven, not system drag-and-drop, so the
/// lifted row and the targets can react smoothly).
@MainActor
@Observable
final class SidebarDragState {
    var draggingID: UUID?
    var translation: CGSize = .zero
    var hoverTarget: UUID?
    var hoverZone: DropZone?
    var groupExit: GroupExit?
    @ObservationIgnored var targets: [UUID: DropTarget] = [:]
    /// Each tab group's frame and members, so a tab dragged out of one can leave it.
    @ObservationIgnored var groups: [UUID: (frame: CGRect, members: Set<UUID>, owner: UUID)] = [:]

    func update(dragging id: UUID, translation: CGSize, location: CGPoint) {
        if draggingID != id { draggingID = id }
        self.translation = translation
        var hit = targets.first { key, target in
            target.frame.insetBy(dx: 0, dy: -1).contains(location) && target.leftTabID != id && target.rightTabID != id && key != id
        }
        let exit = groupExit(for: id, at: location, overRow: hit != nil)
        if exit != nil { hit = nil }
        let zone = hit.map { DropZone.zone(at: location, in: $0.value.frame, kind: $0.value.kind) }
        if hit?.key != hoverTarget || zone != hoverZone || exit != groupExit {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.68)) {
                hoverTarget = hit?.key
                hoverZone = zone
                groupExit = exit
            }
        }
    }

    /// Out past the group's top or bottom edge: just beyond it (even over a row), or anywhere
    /// that isn't a row.
    private func groupExit(for id: UUID, at location: CGPoint, overRow: Bool) -> GroupExit? {
        guard let (groupID, group) = groups.first(where: { $0.value.members.contains(id) }) else { return nil }
        let frame = group.frame
        let distance = max(frame.minY - location.y, location.y - frame.maxY)
        guard distance > 0, !overRow || distance < 14 else { return nil }
        return GroupExit(groupID: groupID, below: location.y > frame.midY)
    }

    /// Returns the drop (if any) and springs everything back to rest.
    func end() -> (dragged: UUID, drop: SidebarDrop)? {
        defer {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                draggingID = nil
                translation = .zero
                hoverTarget = nil
                hoverZone = nil
                groupExit = nil
            }
        }
        guard let draggingID else { return nil }
        if let groupExit { return (draggingID, .outOfGroup(below: groupExit.below)) }
        guard let hoverTarget, let hoverZone, let target = targets[hoverTarget] else { return nil }
        return (draggingID, .onto(target, hoverZone))
    }
}

/// Makes a sidebar row pressable (spring squish), clickable, draggable (lifts and follows the
/// pointer) and, for Today rows, a drop target with edge/centre feedback. Clicks and drags come
/// from one gesture: moving less than 6pt is a click, so a click can never turn into a drag.
struct SidebarDraggable: ViewModifier {
    let id: UUID
    let drag: SidebarDragState
    /// nil: can be dragged but not dropped onto (Split View panes).
    let dropTarget: (left: UUID, right: UUID)?
    var dropKind: DropTarget.Kind = .today
    let palette: ThemePalette
    var canDrag = true
    /// Called with the click count when the press ends without becoming a drag.
    var onClick: ((Int) -> Void)?
    let onDrop: (UUID, SidebarDrop) -> Void

    /// True while the pointer is down on this row; resets itself if the gesture is cancelled.
    @GestureState private var pressing = false
    @State private var owner = UUID()

    private var lifted: Bool { drag.draggingID == id }
    private var zone: DropZone? { drag.hoverTarget == id ? drag.hoverZone : nil }

    func body(content: Content) -> some View {
        content
            // Make room on the side a split will land on; swell slightly for a group.
            .offset(x: zone == .left ? 7 : (zone == .right ? -7 : 0))
            .scaleEffect(lifted ? 1.035 : (zone == .center ? 1.025 : (pressing ? 0.97 : 1)))
            .overlay { hint }
            .shadow(color: .black.opacity(lifted ? 0.22 : 0), radius: lifted ? 10 : 0, y: lifted ? 5 : 0)
            .offset(lifted ? drag.translation : .zero)
            .zIndex(lifted ? 10 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.9), value: pressing)
            .background {
                if let dropTarget {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { register(geo.frame(in: .named(SidebarDragState.space)), dropTarget) }
                            .onChange(of: geo.frame(in: .named(SidebarDragState.space))) { _, frame in register(frame, dropTarget) }
                            .onDisappear { if drag.targets[id]?.owner == owner { drag.targets[id] = nil } }
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(SidebarDragState.space))
                    .updating($pressing) { _, pressing, _ in pressing = true }
                    .onChanged { value in
                        // Only this press, after moving past the threshold, lifts the row.
                        let distance = hypot(value.translation.width, value.translation.height)
                        guard canDrag, drag.draggingID == id || distance >= 6 else { return }
                        drag.update(dragging: id, translation: value.translation, location: value.location)
                    }
                    .onEnded { _ in
                        guard drag.draggingID == id else {
                            onClick?(NSApp.currentEvent?.clickCount ?? 1)
                            return
                        }
                        if let drop = drag.end() { onDrop(drop.dragged, drop.drop) }
                    },
                including: canDrag || onClick != nil ? .all : .subviews
            )
            .onChange(of: pressing) { _, isPressing in
                // A cancelled gesture never calls onEnded: put a row that's still lifted back down.
                guard !isPressing else { return }
                DispatchQueue.main.async { if drag.draggingID == id { _ = drag.end() } }
            }
    }

    @ViewBuilder private var hint: some View {
        if let zone {
            switch zone {
            case .left, .right:
                HStack {
                    if zone == .right { Spacer() }
                    Capsule().fill(palette.accent).frame(width: 3).padding(.vertical, 6)
                        .shadow(color: palette.accent.opacity(0.6), radius: 4)
                        .offset(x: zone == .left ? 2 : -2)
                    if zone == .left { Spacer() }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            case .center, .into:
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(palette.accent.opacity(0.14))
                    .transition(.opacity)
            case .above, .below:
                // An insertion line in the gap above or below the row.
                VStack {
                    if zone == .below { Spacer() }
                    Capsule().fill(palette.accent).frame(height: 3)
                        .shadow(color: palette.accent.opacity(0.6), radius: 4)
                        .padding(.horizontal, 6)
                        .offset(y: (zone == .below ? 1 : -1) * (Metrics.rowSpacing / 2 + 1.5))
                    if zone == .above { Spacer() }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
    }

    private func register(_ frame: CGRect, _ target: (left: UUID, right: UUID)) {
        drag.targets[id] = DropTarget(frame: frame, kind: dropKind, leftTabID: target.left, rightTabID: target.right, owner: owner)
    }
}

extension SidebarDragState {
    static let space = "sidebar-drag"
}

extension View {
    func sidebarDraggable(id: UUID, drag: SidebarDragState, dropTarget: (left: UUID, right: UUID)?,
                          dropKind: DropTarget.Kind = .today, palette: ThemePalette,
                          canDrag: Bool = true, onClick: ((Int) -> Void)? = nil,
                          onDrop: @escaping (UUID, SidebarDrop) -> Void) -> some View {
        modifier(SidebarDraggable(id: id, drag: drag, dropTarget: dropTarget, dropKind: dropKind, palette: palette,
                                  canDrag: canDrag, onClick: onClick, onDrop: onDrop))
    }

    /// Registers a tab group's frame and members with the drag (see `SidebarDragState.groups`).
    func sidebarGroupFrame(id: UUID, members: [UUID], drag: SidebarDragState) -> some View {
        modifier(SidebarGroupFrame(id: id, members: members, drag: drag))
    }
}

private struct SidebarGroupFrame: ViewModifier {
    let id: UUID
    let members: [UUID]
    let drag: SidebarDragState
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geo in
                let frame = geo.frame(in: .named(SidebarDragState.space))
                Color.clear
                    .onAppear { drag.groups[id] = (frame, Set(members), owner) }
                    .onChange(of: frame) { _, frame in drag.groups[id] = (frame, Set(members), owner) }
                    .onChange(of: members) { _, members in drag.groups[id] = (frame, Set(members), owner) }
                    .onDisappear { if drag.groups[id]?.owner == owner { drag.groups[id] = nil } }
            }
        }
    }
}
