import SwiftUI

/// 原生 macOS 27 目录树侧边栏
struct SidebarTreeView: View {
    let roots: [TreeNode]
    @Binding var currentURL: URL
    let onSelect: (URL) -> Void

    @State private var selection: TreeNode.ID?

    var body: some View {
        List(roots, children: \.children, selection: $selection) { node in
            Group {
                if node.isLoading {
                    HStack(spacing: 6) {
                        Label(node.name, systemImage: node.symbolName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        ProgressView()
                            .controlSize(.mini)
                    }
                } else {
                    Label(node.name, systemImage: node.symbolName)
                        .lineLimit(1)
                }
            }
            .task(id: node.id) {
                await node.loadChildren()
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            syncSelectionFromCurrentURL()
        }
        .onChange(of: currentURL) {
            syncSelectionFromCurrentURL()
        }
        .onChange(of: selection) { _, newID in
            guard let id = newID,
                  let node = findNode(id: id, in: roots),
                  node.url.standardizedFileURL.path != currentURL.standardizedFileURL.path else {
                return
            }
            onSelect(node.url)
        }
    }

    private func syncSelectionFromCurrentURL() {
        let targetPath = currentURL.standardizedFileURL.path
        if let currentID = selection,
           let currentNode = findNode(id: currentID, in: roots),
           currentNode.url.standardizedFileURL.path == targetPath {
            return
        }
        selection = findNode(matchingPath: targetPath, in: roots)?.id
    }

    private func findNode(id: TreeNode.ID, in nodes: [TreeNode]) -> TreeNode? {
        for node in nodes {
            if node.id == id {
                return node
            }
            if let children = node.children,
               let match = findNode(id: id, in: children) {
                return match
            }
        }
        return nil
    }

    private func findNode(matchingPath path: String, in nodes: [TreeNode]) -> TreeNode? {
        for node in nodes {
            if node.url.standardizedFileURL.path == path {
                return node
            }
            if let children = node.children,
               let match = findNode(matchingPath: path, in: children) {
                return match
            }
        }
        return nil
    }
}
