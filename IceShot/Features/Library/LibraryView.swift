import SwiftData
import SwiftUI

/// 历史记录主界面：三栏布局（筛选 / 列表 / 详情）。
///
/// 数据来自 SwiftData `@Query`，文件读取交给 `LibraryStore`；
/// 清空操作只弹确认框，真正的删除在后台任务里执行。
/// 选中项会通过 `setProtectedRecord` 保护，自动清理不会删掉正在查看的截图。
struct LibraryView: View {
    let library: LibraryStore
    let editor: EditorOpening?
    let pins: PinBoard?

    @Query(sort: \ScreenshotRecord.createdAt, order: .reverse)
    private var records: [ScreenshotRecord]

    @State private var filter: LibraryFilter? = .all
    @State private var selectedRecordID: UUID?
    @State private var searchText = ""
    @State private var isConfirmingClearNonFavorites = false
    @State private var isConfirmingClearAll = false
    @State private var errorMessage: String?
    /// 等待确认删除的单条记录（`⌫` 与右键菜单都落到这里）。
    @State private var pendingDeletion: ScreenshotRecord?
    /// 列表动作的反馈文案（复制成功 / 已收藏…），几秒后自动消失。
    @State private var actionMessage: String?
    @State private var actionMessageTask: Task<Void, Never>?

    private var actions: LibraryRecordActions {
        LibraryRecordActions(library: library, pins: pins)
    }

    var body: some View {
        NavigationSplitView {
            List(LibraryFilter.allCases, selection: $filter) { item in
                Label(item.title, systemImage: item.symbolName)
                    .tag(item)
            }
            .navigationTitle("历史记录")
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } content: {
            List(filteredRecords, selection: $selectedRecordID) { record in
                LibraryRow(record: record, library: library)
                    .tag(record.id)
                    .contextMenu { rowMenu(for: record) }
                    .onDrag { dragProvider(for: record) }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { openEditor(record) }
                    )
            }
            .onDeleteCommand {
                if let selectedRecord {
                    pendingDeletion = selectedRecord
                }
            }
            .overlay {
                if filteredRecords.isEmpty {
                    emptyState
                }
            }
            .navigationTitle(activeFilter.title)
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
            .searchable(text: $searchText, placement: .toolbar, prompt: "搜索来源 / 识别文字")
            .safeAreaInset(edge: .bottom) {
                if let actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .transition(.opacity)
                }
            }
        } detail: {
            if let record = selectedRecord {
                LibraryDetailView(
                    record: record,
                    library: library,
                    editor: editor
                ) {
                    selectedRecordID = nil
                }
                .id(record.id)
            } else {
                ContentUnavailableView(
                    "选择一张截图",
                    systemImage: "photo",
                    description: Text("从列表中选择截图以查看原图与操作。")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("删除全部未收藏…", role: .destructive) {
                        isConfirmingClearNonFavorites = true
                    }
                    Button("删除全部（含收藏）…", role: .destructive) {
                        isConfirmingClearAll = true
                    }
                } label: {
                    Label("历史管理", systemImage: "ellipsis.circle")
                }
                .disabled(records.isEmpty)
                .help("管理本机历史记录")
            }
        }
        .confirmationDialog(
            "删除全部未收藏的截图？",
            isPresented: $isConfirmingClearNonFavorites,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                clear(includeFavorites: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("收藏的截图会保留；未收藏的原图与缩略图将被删除。")
        }
        .confirmationDialog(
            "删除全部截图（含收藏）？",
            isPresented: $isConfirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("全部删除", role: .destructive) {
                clear(includeFavorites: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有历史记录、原图与缩略图都会被删除，无法恢复。")
        }
        .confirmationDialog(
            "删除这张截图？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let record = pendingDeletion {
                    delete(record)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原图与缩略图会从历史库删除，无法恢复。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: selectedRecordID) { _, newValue in
            library.setProtectedRecord(newValue)
        }
        .onDisappear {
            library.setProtectedRecord(nil)
        }
        .onChange(of: filter) { _, _ in
            selectedRecordID = nil
        }
        .onChange(of: searchText) { _, _ in
            if let selectedRecord, !filteredRecords.contains(where: { $0.id == selectedRecord.id }) {
                selectedRecordID = nil
            }
        }
    }

    private var filteredRecords: [ScreenshotRecord] {
        records.filter { record in
            guard activeFilter.includes(record) else { return false }
            return HistorySearch.matches(record: record, query: searchText)
        }
    }

    private var activeFilter: LibraryFilter {
        filter ?? .all
    }

    private var selectedRecord: ScreenshotRecord? {
        guard let selectedRecordID else {
            return nil
        }
        return records.first { $0.id == selectedRecordID }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            emptyTitle,
            systemImage: emptySymbol,
            description: Text(emptyDescription)
        )
    }

    private var emptyTitle: String {
        if !searchText.isEmpty {
            return "没有匹配的截图"
        }
        return activeFilter == .favorites ? "还没有收藏" : "还没有截图"
    }

    private var emptySymbol: String {
        if !searchText.isEmpty {
            return "magnifyingglass"
        }
        return activeFilter == .favorites ? "heart" : "camera.viewfinder"
    }

    private var emptyDescription: String {
        if !searchText.isEmpty {
            return "尝试清除搜索条件或切换筛选。"
        }
        if activeFilter == .favorites {
            return "在截图详情中点击心形按钮收藏。"
        }
        return "按下区域截图快捷键或从菜单栏开始截图。\n会自动保存到历史。"
    }

    /// 清空历史；`includeFavorites` 决定是否连收藏一起删除。
    private func clear(includeFavorites: Bool) {
        Task {
            do {
                if includeFavorites {
                    try await library.deleteAll()
                } else {
                    try await library.deleteNonFavorites()
                }
                selectedRecordID = nil
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "清空历史失败（错误码 \((error as NSError).code)）。"
            }
        }
    }

    // MARK: - 列表行动作（右键 / 双击 / ⌫ / 拖出）

    @ViewBuilder
    private func rowMenu(for record: ScreenshotRecord) -> some View {
        Button("复制图片") {
            copyImage(record)
        }
        if pins != nil {
            Button("贴图") {
                pin(record)
            }
        }
        Button("在 Finder 中显示") {
            revealInFinder(record)
        }
        Divider()
        Button("另存为 PNG…") {
            saveAsPNG(record)
        }
        Button(record.isFavorite ? "取消收藏" : "收藏") {
            toggleFavorite(record)
        }
        Divider()
        Button("删除…", role: .destructive) {
            pendingDeletion = record
        }
    }

    private func dragProvider(for record: ScreenshotRecord) -> NSItemProvider {
        guard let url = actions.originalURL(for: record) else {
            return NSItemProvider()
        }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    private func openEditor(_ record: ScreenshotRecord) {
        guard let editor else { return }
        Task {
            guard let image = await library.image(for: record, thumbnail: false) else {
                errorMessage = LibraryActionError.originalMissing.errorDescription
                return
            }
            editor.open(
                image: image,
                title: "编辑截图",
                target: .history(recordID: record.id, isFavorite: record.isFavorite)
            )
        }
    }

    private func copyImage(_ record: ScreenshotRecord) {
        Task {
            do {
                try await actions.copyImage(record)
                showMessage("已复制到剪贴板")
            } catch {
                report(error)
            }
        }
    }

    private func saveAsPNG(_ record: ScreenshotRecord) {
        Task {
            do {
                if try await actions.saveAsPNG(record) {
                    showMessage("已保存")
                }
            } catch {
                report(error)
            }
        }
    }

    private func pin(_ record: ScreenshotRecord) {
        Task {
            do {
                if try await actions.pin(record) {
                    showMessage("已贴图")
                }
            } catch {
                report(error)
            }
        }
    }

    private func revealInFinder(_ record: ScreenshotRecord) {
        if !actions.revealInFinder(record) {
            report(LibraryActionError.originalMissing)
        }
    }

    private func toggleFavorite(_ record: ScreenshotRecord) {
        do {
            try library.toggleFavorite(record)
            showMessage(record.isFavorite ? "已收藏" : "已取消收藏")
        } catch {
            report(error)
        }
    }

    private func delete(_ record: ScreenshotRecord) {
        pendingDeletion = nil
        Task {
            do {
                try await library.delete(record)
                if selectedRecordID == record.id {
                    selectedRecordID = nil
                }
                showMessage("已删除")
            } catch {
                report(error)
            }
        }
    }

    /// 列表底部的短暂反馈；成功后不需要弹框，但也不能静默。
    private func showMessage(_ message: String) {
        actionMessageTask?.cancel()
        actionMessage = message
        actionMessageTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            actionMessage = nil
        }
    }

    private func report(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription
            ?? "操作失败（错误码 \((error as NSError).code)）。"
    }
}
