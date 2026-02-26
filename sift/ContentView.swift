//
//  ContentView.swift
//  sift
//
//  Created by Apex_Ventura on 2026/02/25.
//

import SwiftUI
import Foundation
import Combine

// =====================
// Models
// =====================

struct Card: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
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

    private let storageKey = "sift_root_v1"
    private var saveWorkItem: DispatchWorkItem?
    
    init() {
        if let loaded = Self.load(key: storageKey) {
            self.root = loaded
            return
        }
        
        let boxA = Box(name: "A")
        let boxB = Box(name: "B")
        
        self.root = Box(
            name: "Workspace",
            cards: [
                Card(text: "Sift: swipe to sort"),
                Card(text: "← A / → B / ↑ Keep")
            ],
            children: [boxA, boxB]
        )
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
    
    // （任意）初期化したいとき用
    func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        let boxA = Box(name: "A")
        let boxB = Box(name: "B")
        root = Box(
            name: "Workspace",
            cards: [
                Card(text: "Sift: swipe to sort"),
                Card(text: "← A / → B / ↑ Keep")
            ],
            children: [boxA, boxB]
        )
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
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        let box = bindingBox(at: path)
        
        VStack(spacing: 16) {
            header(box: box)
            
            Spacer(minLength: 0)
            
            cardStage(box: box)
            
            Spacer(minLength: 0)
            
            boxTargets(box: box)
            
            hint()
        }
        .padding(24)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - UI parts
    
    private func header(box: Binding<Box>) -> some View {
        HStack {
            Text(box.wrappedValue.name)
                .font(.title2).bold()
            
            Spacer()
            
            Button {
                // add into CURRENT box
                var b = box.wrappedValue
                b.cards.append(Card(text: "New card"))
                box.wrappedValue = b
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .accessibilityLabel("Add card")
        }
    }
    
    private func cardStage(box: Binding<Box>) -> some View {
        let current = box.wrappedValue.cards.first
        
        return ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(.thinMaterial)
                .frame(maxWidth: 820, minHeight: 240)
            
            if let current {
                Text(current.text)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .padding(28)
                    .frame(maxWidth: 760)
            } else {
                Text("No cards")
                    .foregroundStyle(.secondary)
            }
        }
        .offset(dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { value in
                    handleSwipe(translation: value.translation, box: box)
                    withAnimation(.spring()) { dragOffset = .zero }
                }
        )
    }
    
    private func boxTargets(box: Binding<Box>) -> some View {
        let children = box.wrappedValue.children
        
        return HStack(spacing: 16) {
            ForEach(children.indices, id: \.self) { idx in
                NavigationLink {
                    WorkspaceView(path: path + [idx], state: state)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(.ultraThinMaterial)
                            .frame(height: 140)
                        
                        VStack(spacing: 8) {
                            Text(children[idx].name)
                                .font(.title3).bold()
                            Text("Tap to open")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private func hint() -> some View {
        Text("→ A    ← B    ↑ Keep")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
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
    
    private func handleSwipe(translation: CGSize, box: Binding<Box>) {
        guard !box.wrappedValue.cards.isEmpty else { return }
        guard box.wrappedValue.children.count >= 2 else { return }
            
            let threshold: CGFloat = 120
            
            var b = box.wrappedValue
            let card = b.cards.removeFirst()
            
            if translation.width > threshold {
                // → B
                b.children[1].cards.append(card)
            } else if translation.width < -threshold {
                // ← B
                b.children[0].cards.append(card)
            } else if translation.height < -threshold {
                // ↑ keep
                b.cards.append(card)
            } else {
                //小さい動きはキャンセル
                b.cards.insert(card, at: 0)
            }
        
        box.wrappedValue = b
    }
}

// =====================
// Preview
// =====================

#Preview {
    ContentView()
}
