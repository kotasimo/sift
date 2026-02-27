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
    
    func moveCardToRootChild(from fromPath: [Int], cardID: UUID, toChildIndex t: Int) {
        guard root.children.indices.contains(t) else { return }

        // 1) 取り出す（fromPath の箱から remove）
        var picked: Card? = nil
        var newRoot = root
        removeCard(&newRoot, path: fromPath, cardID: cardID, picked: &picked)
        guard var card = picked else { return }
        
        // 2) root の子箱へ入れる
        card.px = 0.50
        card.py = 0.35
        newRoot.children[t].cards.append(card)
        
        root = newRoot
        scheduleSave()
    }
    
    private func removeCard(_ box: inout Box, path: [Int], cardID: UUID, picked: inout Card?) {
        if path.isEmpty {
            if let i = box.cards.firstIndex(where: { $0.id == cardID }) {
                picked = box.cards.remove(at: i)
            }
            return
        }
        let head = path[0]
        guard box.children.indices.contains(head) else { return }
        var child = box.children[head]
        removeCard(&child, path: Array(path.dropFirst()), cardID: cardID, picked: &picked)
        box.children[head] = child
    }
}

// =====================
// ContentView
// =====================

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        NavigationStack {
            WorkspaceView(currentIndex: nil, state: state)
        }
    }
}

// =====================
// WorkspaceView (reused recursively)
// =====================

struct WorkspaceView: View {
    let currentIndex: Int?                // [] = root, [0] = A, [1] = B, [1,0] = nested...
    @ObservedObject var state: AppState
    // input (always at bottom)
    @State private var draftText: String = ""
    
    // dragging
    @State private var draggingID: UUID? = nil
    @State private var hoverTarget: Int? = nil
    @State private var dragOffset: CGSize = .zero
    @State private var dragBase: (px: Double, py: Double)? = nil
    
    @FocusState private var inputFocused: Bool
    
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    
    var body: some View {
        let box = bindingBox()
        
        ZStack {
            Color.blue.opacity(0.35).ignoresSafeArea()
            
            GeometryReader { geo in
                let size = geo.size
                
                ZStack {
                    // 1) Desk: scattered cards
                    cardBoard(box: box, size: size)
                    
                    cornerLabels(box: box, size: size)
                    
                    // 2) Dock (A/B circles) only if this box has children
//                    if box.wrappedValue.children.count >= 2 {
//                        boxDock(box: box, size: size)
//                    }
                    
                    // 3) Input bar (always)
                    inputBar(box: box)
                }
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
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // どのカードを掴んでるか
                                if draggingID != card.id {
                                    draggingID = card.id
                                    dragBase = (px: card.px, py: card.py)
                                }
                                // target 判定は translation のままでOK
                                hoverTarget = targetIndex(from: value.translation)
                                
                                // ここが核心：px/py を直接更新（アニメ無し）
                                guard let base = dragBase else { return }
                                
                                let newX = CGFloat(base.px) * size.width + value.translation.width
                                let newY = CGFloat(base.py) * size.height + value.translation.height
                                
                                let clampedX = min(max(newX, 30), size.width - 30)
                                let clampedY = min(max(newY, 30), size.height - 200)
                                
                                var b = box.wrappedValue
                                guard let idx = b.cards.firstIndex(where: { $0.id == card.id }) else { return }
                                
                                var tx = Transaction()
                                tx.animation = nil
                                withTransaction(tx) {
                                    b.cards[idx].px = Double(clampedX / size.width)
                                    b.cards[idx].py = Double(clampedY / size.height)
                                    box.wrappedValue = b
                                }
                             }
                            .onEnded { value in
                                onDrop(cardID: card.id, translation: value.translation, predicted: value.predictedEndTranslation, box: box, size: size)
                                draggingID = nil
                                dragBase = nil
                                hoverTarget = nil
                            }
                    )
            }
        }
        .animation(nil, value: draggingID)
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
        let ax = abs(dx)
        let ay = abs(dy)
        // どっちも弱いなら確定しない
        guard ax >= threshold || ay >= threshold else { return nil }
        
        // 斜めは「強い軸」だけ採用（= どっちか）
        if ax >= ay {
            return dx < 0 ? 0 : 1   // 左 / 右
        } else {
            return dy < 0 ? 2 : 3   // 上 / 下（上はマイナス）
        }
    }
    
    // MARK: - Drop logic
    
    // MARK: - Dock (A/B)
    
    private func boxDock(box: Binding<Box>, size: CGSize) -> some View {
        let dockY: CGFloat = size.height - 110
        
        return ZStack {
            // Left (A)
            NavigationLink {
                WorkspaceView(path: [0], state: state)
                WorkspaceView(path: [1], state: state)
                WorkspaceView(path: [2], state: state)
                WorkspaceView(path: [3], state: state)
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
        .frame(maxWidth: .infinity, alignment: .center)
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
    
    private func bindingBox() -> Binding<Box> {
        Binding(
            get: {
                if let i = currentIndex, state.root.children.indices.contains(i) {
                    return state.root.children[i]
                } else {
                    return state.root
                }
            },
            set: { newValue in
                if let i = currentIndex, state.root.children.indices.contains(i) {
                    state.root.children[i] = newValue
                } else {
                    state.root = newValue
                }
                state.scheduleSave()
            }
        )
    }
    
    private func cornerLabels(box: Binding<Box>, size: CGSize) -> some View {
        ZStack {
            if box.wrappedValue.children.count >= 4 {
                // 上
                NavigationLink {
                    WorkspaceView(currentIndex: 2, state: state)
                } label: {
                    cornerLabel(text: state.root.children[2].name, active: hoverTarget == 2 )
                }
                .buttonStyle(.plain)
                .position(x: size.width / 2, y: 40)
                
                // 下
                NavigationLink {
                    WorkspaceView(currentIndex: 3, state: state)
                } label: {
                    cornerLabel(text: state.root.children[3].name, active: hoverTarget == 3 )
                }
                .buttonStyle(.plain)
                .position(x: size.width / 2, y: size.height - 150)
                
                // 左
                NavigationLink {
                    WorkspaceView(currentIndex: 0, state: state)
                } label: {
                    cornerLabel(text: state.root.children[0].name, active: hoverTarget == 0 )
                }
                .buttonStyle(.plain)
                .position(x: 50, y: size.height / 2)
                
                // 右
                NavigationLink {
                    WorkspaceView(currentIndex: 1, state: state)
                } label: {
                    cornerLabel(text: state.root.children[1].name, active: hoverTarget == 1 )
                }
                .buttonStyle(.plain)
                .position(x: size.width - 50, y: size.height / 2)
            }
        }
    }
    
    private func isFlick(actual: CGSize, predicted: CGSize, minBoost: CGFloat = 140) -> Bool {
        let dx = abs(predicted.width - actual.width)
        let dy = abs(predicted.height - actual.height)
        return max(dx, dy) > minBoost
    }
    
    private func onDrop(cardID: UUID, translation: CGSize, predicted: CGSize, box: Binding<Box>, size: CGSize) {
        let b = box.wrappedValue
        guard let idx = b.cards.firstIndex(where: { $0.id == cardID }) else { return }
       
        // フリック判定（勢いがある時だけ吸い込む）
        let boostX = abs(predicted.width - translation.width)
        let boostY = abs(predicted.height - translation.height)
        let isFlick = max(boostX, boostY) > 260  // ←吸われすぎるなら増やす（例: 320）
        
        guard b.children.count >= 4, isFlick, let tIndex = targetIndex(from: predicted) else {
            return
        }
            
            // 画面外へ飛ばす（吸い込み）
            let out = offscreenNormalizedPosition(from: b.cards[idx], target: tIndex)

            withAnimation(.easeIn(duration: 0.20)) {
                var b1 = box.wrappedValue
                guard let i1 = b1.cards.firstIndex(where: { $0.id == cardID }) else { return }
                b1.cards[i1].px = out.px
                b1.cards[i1].py = out.py
                box.wrappedValue = b1
            }

            haptic.impactOccurred()

            // アニメ後に本当に移動
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                state.moveCardToRootChild(from: path, cardID: cardID, toChildIndex: tIndex)
            }
    }
    
    private func offscreenNormalizedPosition(from card: Card, target: Int) -> (px: Double, py: Double) {
        // target: 0=左 1=右 2=上 3=下
        switch target {
        case 0: return (px: -0.25, py: card.py)   // left
        case 1: return (px:  1.25, py: card.py)   // right
        case 2: return (px: card.px, py: -0.25)   // up
        default: return (px: card.px, py:  1.25)  // down
        }
    }
    
    private func cornerLabel(text: String, active: Bool) -> some View {
        Text(text)
            .font(.headline)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? Color.white : Color.white.opacity(0.25))
            )
            .foregroundStyle(active ? .black : .white)
            .scaleEffect(active ? 1.2 : 1.0)
            .animation(.easeOut(duration: 0.12), value: active)
    }
    private func tiltDegrees(from t: CGSize) -> Double {
        let dx = Double(t.width)
        let normalized = max(-1, min(1, dx / 140.0))
        let base = normalized * 10.0
        let boost = (hoverTarget == 0 || hoverTarget == 1) ? 4.0 : 0.0
        
        // 左ならマイナス、右ならプラスに自然に足す
        return base + (normalized >= 0 ? boost : -boost)
    }
}

// =====================
// Preview
// =====================

#Preview {
    ContentView()
}
