//
//  ContentView.swift
//  sift
//
//  Created by Apex_Ventura on 2026/02/25.
//

import SwiftUI
import Foundation
import Combine
import UIKit
import UIKit

// =====================
// Models
// =====================

struct Card: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    // normalized position (0...1)
    var px: Double
    var py: Double
}

struct Box: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var cards: [Card] = []
    var children: [Box] = []
}

// =====================
// App State
// =====================

@MainActor
final class AppState: ObservableObject {
    @Published var root: Box
    // v2: because Card gained px/py and old JSON won't decode
    private let storageKey = "sift_root_v2"
    private var saveWorkItem: DispatchWorkItem?
    
    init() {
        if let loaded = Self.load(key: storageKey) {
            self.root = loaded
            return
        }
        self.root = Self.defaultRoot()
        scheduleSave()
    }
    
    // 連続操作でも重くならないようにちょい遅延保存
    func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [root] in
            Self.save(root, key: self.storageKey)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    
    // MARK: - Persistence (UserDefaults + JSON)
    
    private static func save(_ box: Box, key: String) {
        do {
            let data = try JSONEncoder().encode(box)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            print("Save failed:", error)
        }
    }
    
    private static func load(key: String) -> Box? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(Box.self, from: data)
        } catch {
            print("Load failed:", error)
            return nil
        }
    }
    
    // MARK: - Defaults / Reset
    
    static func defaultRoot() -> Box {
        // Root has two child boxes A/B (like your current app)
        let boxA = Box(name: "A")
        let boxB = Box(name: "B")
        
        return Box(
            name: "Workspace",
            cards: [
                Card(text: "Drag cards around", px: 0.52, py: 0.22),
                Card(text: "Drop into A / B (bottom circles)", px: 0.48, py: 0.36),
                Card(text: "Use the input bar to create new cards", px: 0.55, py: 0.50)
            ],
            children: [boxA, boxB]
        )
    }
    
    func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        root = Self.defaultRoot()
        scheduleSave()
    }
}

// =====================
// ContentView
// =====================

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        NavigationStack {
            WorkspaceView(path: [], state: state)
        }
    }
}

// =====================
// WorkspaceView (reused recursively)
// =====================

struct WorkspaceView: View {
    let path: [Int]                 // [] = root, [0] = A, [1] = B, [1,0] = nested...
    @ObservedObject var state: AppState
    // input (always at bottom)
    @State private var draftText: String = ""
    
    // dragging
    @State private var draggingID: UUID? = nil
    @State private var dragOffset: CGSize = .zero
    
    @FocusState private var inputFocused: Bool
    
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    
    var body: some View {
        let box = bindingBox(at: path)
        
    ZStack {
        Color.blue.opacity(0.35).ignoresSafeArea()
        
        GeometryReader { geo in
            let size = geo.size
            
            ZStack {
                // 1) Desk: scattered cards
                cardBoard(box: box, size: size)
                
                // 2) Dock (A/B circles) only if this box has children
                if box.wrappedValue.children.count >= 2 {
                    boxDock(box: box, size: size)
                }
                
                // 3) Input bar (always)
                inputBar(box: box)
            }
            .padding(24)
            .navigationTitle(box.wrappedValue.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        state.resetToDefaults()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Reset")
                }
            }
        }
    }
    }
    
    // MARK: - Desk (cards)
    
    private func cardBoard(box: Binding<Box>, size: CGSize) -> some View {
        ZStack {
            ForEach(box.wrappedValue.cards) { card in
                let x = CGFloat(card.px) * size.width
                let y = CGFloat(card.py) * size.height
                
                cardView(text: card.text, isDragging: draggingID == card.id)
                    .zIndex(draggingID == card.id ? 10 : 0)
                    .position(x: x, y: y)
                    .offset(draggingID == card.id ? dragOffset : .zero)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                draggingID = card.id
                                dragOffset = value.translation
                            }
                            .onEnded { value in
                                onDrop(cardID: card.id, translation: value.translation, box: box, size: size)
                                draggingID = nil
                                dragOffset = .zero
                            }
                    )
            }
        }
    }
    
    private func cardView(text: String, isDragging: Bool) -> some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color.white)
            .overlay(
                Text(text)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
            )
            .frame(width: 260, height: 140)
            .shadow(radius: isDragging ? 5 : 6, y: isDragging ? 5 : 4)
            .scaleEffect(isDragging ? 1.03 : 1.0)
    }
    
    // MARK: - Drop logic
    
    private func onDrop(cardID: UUID, translation: CGSize, box: Binding<Box>, size: CGSize) {
        var b = box.wrappedValue
        guard let idx = b.cards.firstIndex(where: { $0.id == cardID }) else { return }
        
        // current normalized -> absolute
        let cur = b.cards[idx]
        let curX = CGFloat(cur.px) * size.width
        let curY = CGFloat(cur.py) * size.height
        
        // new absolute position
        let newX = curX + translation.width
        let newY = curY + translation.height
        let p = CGPoint(x: newX, y: newY)
        
        // dock centers
        let dockY = size.height - 110
        let leftCenter  = CGPoint(x: 110, y: dockY)
        let rightCenter = CGPoint(x: size.width - 110, y: dockY)
        let r: CGFloat = 70
        
        func inside(_ p: CGPoint, _ c: CGPoint) -> Bool {
            let dx = p.x - c.x
            let dy = p.y - c.y
            return (dx*dx + dy*dy) <= r*r
        }
        
        // if dropped into a child box: move card
        if b.children.count >= 2 {
            if inside(p, leftCenter) {
                let moved = b.cards.remove(at: idx)
                b.children[0].cards.append(moved)
                box.wrappedValue = b
                haptic.impactOccurred()
                return
            }
            if inside(p, rightCenter) {
                let moved = b.cards.remove(at: idx)
                b.children[1].cards.append(moved)
                box.wrappedValue = b
                haptic.impactOccurred()
                return
            }
        }
        
        // otherwise: update position (clamp to desk area)
        let clampedX = min(max(newX, 30), size.width - 30)
        let clampedY = min(max(newY, 30), size.height - 200) // keep above input bar zone
        
        b.cards[idx].px = Double(clampedX / size.width)
        b.cards[idx].py = Double(clampedY / size.height)
        box.wrappedValue = b
    }
    
    // MARK: - Dock (A/B)
    
    private func boxDock(box: Binding<Box>, size: CGSize) -> some View {
        let dockY: CGFloat = size.height - 110
        
        return ZStack {
            // Left (A)
            NavigationLink {
                WorkspaceView(path: path + [0], state: state)
            } label: {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 140, height: 140)
                    .overlay(
                        Text(box.wrappedValue.children[0].name)
                            .font(.title3).bold()
                            .foregroundStyle(.primary)
                    )
            }
            .buttonStyle(.plain)
            .position(x: 110, y: dockY)
            
            // Right (B)
            NavigationLink {
                WorkspaceView(path: path + [1], state: state)
            } label: {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 140, height: 140)
                    .overlay(
                        Text(box.wrappedValue.children[1].name)
                            .font(.title3).bold()
                            .foregroundStyle(.primary)
                    )
            }
            .buttonStyle(.plain)
            .position(x: size.width - 110, y: dockY)
        }
    }
    
    // MARK: - Input bar
    
    private func inputBar(box: Binding<Box>) -> some View {
        HStack(spacing: 12) {
            TextField("テキスト入力", text: $draftText, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            
                .toolbar{
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("done") {inputFocused = false}
                    }
                }
            
            Button {
                addCard(box: box)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add card")
        }
        .zIndex(1000)
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: 560)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
    
    private func addCard(box: Binding<Box>) {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        var b = box.wrappedValue
        
        // spawn around upper-middle
        let px = min(max(0.5 + Double.random(in: -0.14...0.14), 0.08), 0.92)
        let py = min(max(0.35 + Double.random(in: -0.10...0.10), 0.08), 0.80)
        
        b.cards.append(Card(text: trimmed, px: px, py: py))
        box.wrappedValue = b
        draftText = ""
        haptic.impactOccurred()
    }
    
    // MARK: - Binding Box by Path
    
    private func bindingBox(at path: [Int]) -> Binding<Box> {
        Binding(
            get: {
                var current = state.root
                for i in path { current = current.children[i] }
                return current
            },
            set: { newValue in
                if path.isEmpty {
                    state.root = newValue
                    state.scheduleSave()
                    return
                }
                var root = state.root
                setBox(&root, path: path, newValue: newValue)
                state.root = root
                state.scheduleSave()
            }
        )
    }
    
    private func setBox(_ box: inout Box, path: [Int], newValue: Box) {
        guard let first = path.first else { return }
        
        if path.count == 1 {
            box.children[first] = newValue
            return
        }
        
        var child = box.children[first]
        setBox(&child, path: Array(path.dropFirst()), newValue: newValue)
        box.children[first] = child
    }
}

// =====================
// Preview
// =====================

#Preview {
    ContentView()
}
