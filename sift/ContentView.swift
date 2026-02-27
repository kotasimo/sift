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
        let boxC = Box(name: "C")
        let boxD = Box(name: "D")
        
        return Box(
            name: "Workspace",
            cards: [
                Card(text: "Drag cards around", px: 0.52, py: 0.22),
                Card(text: "Drop into A / B (bottom circles)", px: 0.48, py: 0.36),
                Card(text: "Use the input bar to create new cards", px: 0.55, py: 0.50)
            ],
            children: [boxA, boxB, boxC, boxD]
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
                
                cornerLabels(box: box, size: size)
                
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
            ForEach(box.wrappedValue.cards.indices, id: \.self) { i in
                let card = box.wrappedValue.cards[i]
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
    
    private func targetIndex(from t: CGSize, threshold: CGFloat = 120) -> Int? {
        let dx = t.width
        let dy = t.height
    
        // 斜めだけ確定（誤爆防止）
        let xOK = abs(dx) >= threshold
        let yOK = abs(dy) >= threshold
        guard xOK && yOK else { return nil }
        
        // iOS座標: 上はdyがマイナス
        if dx < 0 && dy < 0 { return 0 } // 左上 = children[0]
        if dx > 0 && dy < 0 { return 1 } // 右上 = children[1]
        if dx < 0 && dy > 0 { return 2 } // 左下 = children[2]
        return 3                          // 右下 = children[3]
    }
    
    // MARK: - Drop logic
    
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
    
    private func cornerLabels(box: Binding<Box>, size: CGSize) -> some View {
        ZStack {
            if box.wrappedValue.children.count >= 4 {
                Text(box.wrappedValue.children[0].name).position(x: 40, y: 30) // 左上
                Text(box.wrappedValue.children[1].name).position(x: size.width - 40, y: 30) // 右上
                Text(box.wrappedValue.children[2].name).position(x: 40, y: size.height - 30) // 左下
                Text(box.wrappedValue.children[3].name).position(x: size.width - 40, y: size.height - 30) // 右下
            }
        }
        .font(.caption).bold()
        .foregroundStyle(.white.opacity(0.8))
        .allowsHitTesting(false)
    }
}

// =====================
// Preview
// =====================

#Preview {
    ContentView()
}
