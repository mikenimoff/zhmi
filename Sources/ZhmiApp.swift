import AppKit
import SwiftUI
import UserNotifications

enum Resolution: String, CaseIterable, Identifiable {
    case original
    case qhd
    case fullHD
    case hd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Оригинал"
        case .qhd: return "2560 x 1440"
        case .fullHD: return "1920 x 1080"
        case .hd: return "1280 x 720"
        }
    }

    var scaleFilter: String {
        switch self {
        case .original:
            return "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        case .qhd:
            return "scale=-2:'min(1440,ih)'"
        case .fullHD:
            return "scale=-2:'min(1080,ih)'"
        case .hd:
            return "scale=-2:'min(720,ih)'"
        }
    }
}

enum Compression: String, CaseIterable, Identifiable {
    case light
    case balanced
    case strong
    case maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Легкое"
        case .balanced: return "Сбалансированное"
        case .strong: return "Сильное"
        case .maximum: return "Максимальное"
        }
    }

    var crf: String {
        switch self {
        case .light: return "23"
        case .balanced: return "28"
        case .strong: return "32"
        case .maximum: return "36"
        }
    }

    var preset: String {
        switch self {
        case .light: return "fast"
        case .balanced, .strong, .maximum: return "veryfast"
        }
    }

    var audioBitrate: String {
        switch self {
        case .light: return "160k"
        case .balanced: return "128k"
        case .strong: return "96k"
        case .maximum: return "64k"
        }
    }
}

enum InputMode: String, CaseIterable, Identifiable {
    case file
    case folder
    case folders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file: return "Один файл"
        case .folder: return "Папка"
        case .folders: return "Несколько папок"
        }
    }
}

private enum WorkKind: String, Codable, Equatable {
    case compress
    case copy
}

private struct WorkItem {
    let source: URL
    let destination: URL
    let kind: WorkKind
}

private struct BatchPlan {
    let directories: [URL]
    let items: [WorkItem]
}

private enum JournalItemState: String, Codable {
    case pending
    case running
    case succeeded
    case failed
}

private struct JournalItem: Codable {
    let sourcePath: String
    let destinationPath: String
    let kind: WorkKind
    var state: JournalItemState

    var workItem: WorkItem {
        WorkItem(
            source: URL(fileURLWithPath: sourcePath),
            destination: URL(fileURLWithPath: destinationPath),
            kind: kind
        )
    }
}

private struct TaskJournal: Codable {
    let version: Int
    let createdAt: Date
    let inputMode: String
    let inputPaths: [String]
    let outputFolderPath: String
    let directoryPaths: [String]
    let resolution: String
    let compression: String
    var items: [JournalItem]
}

private struct FileTreeEntry {
    let source: URL
    let relativeComponents: ArraySlice<String>
    let isDirectory: Bool
}

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
}

private final class ProgressWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var lastProgress = Date()

    func touch() {
        lock.lock()
        lastProgress = Date()
        lock.unlock()
    }

    func isStalled(timeout: TimeInterval) -> Bool {
        lock.lock()
        let stalled = Date().timeIntervalSince(lastProgress) > timeout
        lock.unlock()
        return stalled
    }
}

@MainActor
private final class DockStatusView: NSView {
    enum State {
        case idle
        case running(Double)
        case finished
        case failed
    }

    var state: State = .idle {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let iconRect = bounds.insetBy(dx: 3, dy: 3)
        NSApp.applicationIconImage.draw(in: iconRect)

        switch state {
        case .idle:
            return
        case .running(let value):
            drawProgress(max(0, min(1, value)), context: context)
        case .finished:
            drawSymbol("✓", color: .systemGreen)
        case .failed:
            drawSymbol("!", color: .systemRed)
        }
    }

    private func drawProgress(_ value: Double, context: CGContext) {
        let diameter = min(bounds.width, bounds.height) * 0.54
        let rect = CGRect(
            x: bounds.maxX - diameter - 3,
            y: 3,
            width: diameter,
            height: diameter
        )
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor)
        context.fillEllipse(in: rect)

        let ring = rect.insetBy(dx: 4, dy: 4)
        context.setLineWidth(4)
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.strokeEllipse(in: ring)
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineCap(.round)
        context.addArc(
            center: CGPoint(x: ring.midX, y: ring.midY),
            radius: ring.width / 2,
            startAngle: -.pi / 2,
            endAngle: -.pi / 2 + (.pi * 2 * value),
            clockwise: false
        )
        context.strokePath()

        let text = "\(Int((value * 100).rounded()))%" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(12, diameter * 0.27), weight: .heavy),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawSymbol(_ symbol: String, color: NSColor) {
        let diameter = min(bounds.width, bounds.height) * 0.54
        let rect = CGRect(x: bounds.maxX - diameter - 3, y: 3, width: diameter, height: diameter)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let text = symbol as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: diameter * 0.58, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

@MainActor
final class AppNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifier()
    private let dockStatusView = DockStatusView()

    func prepare() {
        if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        dockStatusView.frame = NSRect(origin: .zero, size: NSApp.dockTile.size)
        NSApp.dockTile.contentView = dockStatusView
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func clearBadge() {
        dockStatusView.state = .idle
        NSApp.dockTile.display()
        UNUserNotificationCenter.current().setBadgeCount(0)
    }

    func compressionStarted() {
        dockStatusView.state = .running(0)
        NSApp.dockTile.display()
    }

    func compressionProgress(_ value: Double) {
        dockStatusView.state = .running(value)
        NSApp.dockTile.display()
    }

    func compressionFinished(done: Int, failed: Int) {
        dockStatusView.state = failed == 0 ? .finished : .failed
        NSApp.dockTile.display()
        send(
            title: "Сжатие завершено",
            body: "Готово файлов: \(done). Ошибок: \(failed).",
            badge: 1
        )
    }

    func compressionFailed(_ message: String) {
        dockStatusView.state = .failed
        NSApp.dockTile.display()
        send(
            title: "Ошибка сжатия",
            body: message,
            badge: 1
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    private func send(title: String, body: String, badge: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: badge)

        let request = UNNotificationRequest(
            identifier: "zhmi-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppNotifier.shared.prepare()
    }
}

@MainActor
final class CompressorModel: ObservableObject {
    @Published var inputMode: InputMode = .file
    @Published var inputFile: URL?
    @Published var inputFolder: URL?
    @Published var inputFolders: [URL] = []
    @Published var outputFolder: URL?
    @Published var resolution: Resolution = .fullHD
    @Published var compression: Compression = .balanced
    @Published var isRunning = false
    @Published var status = "Готово"
    @Published var currentFile = "Текущий файл"
    @Published var totalFiles = 0
    @Published var doneFiles = 0
    @Published var failedFiles = 0
    @Published var retryableFailures = 0
    @Published var resumeAvailable = false
    @Published var resumePendingCount = 0
    @Published var resumeTaskDescription = ""
    @Published var currentProgress = 0.0
    @Published var overallProgress = 0.0
    @Published var log: [LogLine] = [LogLine(text: "Выберите папки и нажмите «Начать сжатие».")]

    private let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    private let ffprobePath = "/opt/homebrew/bin/ffprobe"
    private let stallTimeout: TimeInterval = 120
    private var activeProcess: Process?
    private var stopRequested = false
    private var failedWorkItems: [String: WorkItem] = [:]
    private var retryRequests: [WorkItem] = []
    private var taskJournal: TaskJournal?

    init() {
        loadJournal()
    }

    func pickInputFile() {
        if let file = pickVideoFile() {
            inputFile = file
            totalFiles = 1
        }
    }

    func pickInputFolder() {
        if let folder = pickFolder(title: "Выберите папку с видео") {
            inputFolder = folder
            scanFiles()
        }
    }

    func pickInputFolders() {
        let panel = NSOpenPanel()
        panel.title = "Выберите папки для пакетной обработки"
        panel.prompt = "Выбрать папки"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK {
            inputFolders = panel.urls.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            scanFiles()
        }
    }

    func pickOutputFolder() {
        if let folder = pickFolder(title: "Выберите папку для готовых файлов") {
            outputFolder = folder
        }
    }

    func scanFiles() {
        switch inputMode {
        case .file:
            totalFiles = inputFile.map { isSupportedVideoFile($0) ? 1 : 0 } ?? 0
        case .folder:
            totalFiles = inputFolder.map { videoFiles(in: $0).count } ?? 0
        case .folders:
            totalFiles = inputFolders.reduce(0) { $0 + fileCountRecursively(in: $1) }
        }
    }

    func start() {
        guard !isRunning else { return }
        guard let outputFolder else {
            append("Выберите папку для готовых файлов.")
            return
        }

        let plan: BatchPlan
        do {
            switch inputMode {
            case .file:
                guard let inputFile, isSupportedVideoFile(inputFile) else {
                    append("Выберите поддерживаемый видеофайл.")
                    return
                }
                plan = BatchPlan(
                    directories: [outputFolder],
                    items: [WorkItem(
                        source: inputFile,
                        destination: try outputURL(for: inputFile, in: outputFolder),
                        kind: .compress
                    )]
                )
            case .folder:
                guard let inputFolder else {
                    append("Выберите папку с видео.")
                    return
                }
                let videos = videoFiles(in: inputFolder)
                guard !videos.isEmpty else {
                    append("В выбранной папке нет поддерживаемых видеофайлов.")
                    return
                }
                var reserved = Set<String>()
                var items: [WorkItem] = []
                for video in videos {
                    items.append(WorkItem(
                        source: video,
                        destination: try outputURL(for: video, in: outputFolder, reserved: &reserved),
                        kind: .compress
                    ))
                }
                plan = BatchPlan(directories: [outputFolder], items: items)
            case .folders:
                guard !inputFolders.isEmpty else {
                    append("Выберите одну или несколько папок.")
                    return
                }
                plan = try hierarchicalBatchPlan(from: inputFolders, outputFolder: outputFolder)
            }
        } catch {
            append(error.localizedDescription)
            return
        }

        if plan.items.contains(where: { $0.kind == .compress }),
           (!FileManager.default.fileExists(atPath: ffmpegPath) ||
            !FileManager.default.fileExists(atPath: ffprobePath)) {
            append("ffmpeg или ffprobe не найдены. Ожидаемый путь: /opt/homebrew/bin/")
            return
        }

        isRunning = true
        AppNotifier.shared.clearBadge()
        AppNotifier.shared.compressionStarted()
        stopRequested = false
        status = "Работает"
        currentFile = "Текущий файл"
        totalFiles = plan.items.count
        doneFiles = 0
        failedFiles = 0
        retryableFailures = 0
        failedWorkItems = [:]
        retryRequests = []
        currentProgress = 0
        overallProgress = 0
        log = []
        if inputMode == .folders {
            append("Выбрано папок: \(inputFolders.count). Файлов в задаче: \(plan.items.count).")
        } else {
            append(inputMode == .file ? "Выбран файл: \(plan.items[0].source.lastPathComponent)" : "Найдено видео: \(plan.items.count)")
        }

        createJournal(for: plan, outputFolder: outputFolder)

        let selectedResolution = resolution
        let selectedCompression = compression

        DispatchQueue.global(qos: .userInitiated).async {
            self.runQueue(
                plan: plan,
                resolution: selectedResolution,
                compression: selectedCompression
            )
        }
    }

    func stop() {
        stopRequested = true
        activeProcess?.terminate()
        append("Остановка...")
    }

    func retryFailedFiles() {
        let items = failedWorkItems.values.sorted {
            $0.source.path.localizedStandardCompare($1.source.path) == .orderedAscending
        }
        guard !items.isEmpty else { return }

        failedWorkItems = [:]
        failedFiles = 0
        retryableFailures = 0
        overallProgress = totalFiles > 0 ? Double(doneFiles) / Double(totalFiles) : 0
        status = "Повтор ошибок"
        append("Повторно добавлено в очередь: \(items.count).")
        for item in items {
            updateJournal(item, state: .pending)
        }

        if isRunning {
            retryRequests.append(contentsOf: items)
            return
        }

        isRunning = true
        stopRequested = false
        AppNotifier.shared.clearBadge()
        AppNotifier.shared.compressionStarted()
        AppNotifier.shared.compressionProgress(overallProgress)
        let retryPlan = BatchPlan(
            directories: Array(Set(items.map { $0.destination.deletingLastPathComponent() })),
            items: items
        )
        let selectedResolution = resolution
        let selectedCompression = compression
        DispatchQueue.global(qos: .userInitiated).async {
            self.runQueue(
                plan: retryPlan,
                resolution: selectedResolution,
                compression: selectedCompression
            )
        }
    }

    func resumeLastTask() {
        guard !isRunning, var journal = taskJournal else { return }

        let resumableItems = journal.items.compactMap { journalItem -> WorkItem? in
            if journalItem.state == .succeeded,
               FileManager.default.fileExists(atPath: journalItem.destinationPath) {
                return nil
            }
            return journalItem.workItem
        }
        guard !resumableItems.isEmpty else {
            clearJournal()
            append("Предыдущая задача уже полностью завершена.")
            return
        }

        for index in journal.items.indices {
            if journal.items[index].state != .succeeded ||
               !FileManager.default.fileExists(atPath: journal.items[index].destinationPath) {
                journal.items[index].state = .pending
            }
        }
        taskJournal = journal
        saveJournal()
        restoreSelections(from: journal)

        totalFiles = journal.items.count
        doneFiles = journal.items.filter {
            $0.state == .succeeded && FileManager.default.fileExists(atPath: $0.destinationPath)
        }.count
        failedFiles = 0
        retryableFailures = 0
        failedWorkItems = [:]
        retryRequests = []
        stopRequested = false
        currentProgress = 0
        updateOverallProgress()
        isRunning = true
        status = "Продолжение задачи"
        resumeAvailable = false
        resumePendingCount = 0
        append("Продолжаю предыдущую задачу. Осталось файлов: \(resumableItems.count).")
        AppNotifier.shared.clearBadge()
        AppNotifier.shared.compressionStarted()
        AppNotifier.shared.compressionProgress(overallProgress)

        let plan = BatchPlan(
            directories: journal.directoryPaths.map { URL(fileURLWithPath: $0) },
            items: resumableItems
        )
        let selectedResolution = resolution
        let selectedCompression = compression
        DispatchQueue.global(qos: .userInitiated).async {
            self.runQueue(
                plan: plan,
                resolution: selectedResolution,
                compression: selectedCompression
            )
        }
    }

    private func recordFailure(_ item: WorkItem, error: Error) {
        failedWorkItems[item.destination.standardizedFileURL.path] = item
        failedFiles = failedWorkItems.count
        retryableFailures = failedWorkItems.count
        currentProgress = 0
        updateOverallProgress()
        append("Ошибка \(item.source.lastPathComponent): \(error.localizedDescription)")
        updateJournal(item, state: .failed)
        AppNotifier.shared.compressionProgress(overallProgress)
    }

    private func takeRetryRequests() -> [WorkItem] {
        let items = retryRequests
        retryRequests = []
        return items
    }

    private func updateOverallProgress(currentItemProgress: Double = 0) {
        guard totalFiles > 0 else {
            overallProgress = 0
            return
        }
        overallProgress = min(
            1,
            (Double(doneFiles + failedFiles) + currentItemProgress) / Double(totalFiles)
        )
    }

    private var journalURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Жми", isDirectory: true)
            .appendingPathComponent("active-task.json")
    }

    private func createJournal(for plan: BatchPlan, outputFolder: URL) {
        let inputPaths: [String]
        switch inputMode {
        case .file:
            inputPaths = inputFile.map { [$0.path] } ?? []
        case .folder:
            inputPaths = inputFolder.map { [$0.path] } ?? []
        case .folders:
            inputPaths = inputFolders.map(\.path)
        }

        taskJournal = TaskJournal(
            version: 1,
            createdAt: Date(),
            inputMode: inputMode.rawValue,
            inputPaths: inputPaths,
            outputFolderPath: outputFolder.path,
            directoryPaths: plan.directories.map(\.path),
            resolution: resolution.rawValue,
            compression: compression.rawValue,
            items: plan.items.map {
                JournalItem(
                    sourcePath: $0.source.path,
                    destinationPath: $0.destination.path,
                    kind: $0.kind,
                    state: .pending
                )
            }
        )
        resumeAvailable = false
        resumePendingCount = 0
        saveJournal()
    }

    private func updateJournal(_ item: WorkItem, state: JournalItemState) {
        guard var journal = taskJournal,
              let index = journal.items.firstIndex(where: {
                  $0.destinationPath == item.destination.path
              }) else { return }
        journal.items[index].state = state
        taskJournal = journal
        saveJournal()
    }

    private func saveJournal() {
        guard let journal = taskJournal else { return }
        do {
            let url = journalURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(journal)
            try data.write(to: url, options: .atomic)
        } catch {
            append("Не удалось сохранить журнал задачи: \(error.localizedDescription)")
        }
    }

    private func loadJournal() {
        let url = journalURL
        guard let data = try? Data(contentsOf: url),
              var journal = try? JSONDecoder().decode(TaskJournal.self, from: data) else {
            return
        }

        var pending = 0
        var succeeded = 0
        for index in journal.items.indices {
            let item = journal.items[index]
            if item.state == .succeeded,
               FileManager.default.fileExists(atPath: item.destinationPath) {
                succeeded += 1
            } else {
                journal.items[index].state = .pending
                pending += 1
            }
        }

        guard pending > 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        taskJournal = journal
        restoreSelections(from: journal)
        totalFiles = journal.items.count
        doneFiles = succeeded
        failedFiles = 0
        overallProgress = journal.items.isEmpty ? 0 : Double(succeeded) / Double(journal.items.count)
        resumeAvailable = true
        resumePendingCount = pending
        resumeTaskDescription = "\(pending) из \(journal.items.count) файлов"
        status = "Можно продолжить"
        log = [LogLine(text: "Найдена незавершённая задача: \(resumeTaskDescription).")]
        saveJournal()
    }

    private func restoreSelections(from journal: TaskJournal) {
        if let mode = InputMode(rawValue: journal.inputMode) {
            inputMode = mode
        }
        outputFolder = URL(fileURLWithPath: journal.outputFolderPath)
        if let value = Resolution(rawValue: journal.resolution) {
            resolution = value
        }
        if let value = Compression(rawValue: journal.compression) {
            compression = value
        }

        switch inputMode {
        case .file:
            inputFile = journal.inputPaths.first.map { URL(fileURLWithPath: $0) }
        case .folder:
            inputFolder = journal.inputPaths.first.map { URL(fileURLWithPath: $0) }
        case .folders:
            inputFolders = journal.inputPaths.map { URL(fileURLWithPath: $0) }
        }
    }

    private func clearJournal() {
        taskJournal = nil
        resumeAvailable = false
        resumePendingCount = 0
        resumeTaskDescription = ""
        try? FileManager.default.removeItem(at: journalURL)
    }

    private func refreshResumeAvailability() {
        guard let journal = taskJournal else {
            resumeAvailable = false
            resumePendingCount = 0
            resumeTaskDescription = ""
            return
        }
        let pending = journal.items.filter {
            $0.state != .succeeded || !FileManager.default.fileExists(atPath: $0.destinationPath)
        }.count
        resumeAvailable = pending > 0
        resumePendingCount = pending
        resumeTaskDescription = pending > 0 ? "\(pending) из \(journal.items.count) файлов" : ""
    }

    private func pickFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func pickVideoFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Выберите видеофайл"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        if isSupportedVideoFile(url) {
            return url
        }

        append("Поддерживаются файлы mp4, mov, m4v, avi, mkv и webm.")
        return nil
    }

    nonisolated private func runQueue(plan: BatchPlan, resolution: Resolution, compression: Compression) {
        do {
            for directory in plan.directories {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            var queue = plan.items
            var queueIndex = 0
            while true {
                if queueIndex >= queue.count {
                    let additions = DispatchQueue.main.sync { () -> [WorkItem] in
                        let pending = self.takeRetryRequests()
                        if !pending.isEmpty { return pending }

                        self.isRunning = false
                        self.status = self.failedFiles == 0 ? "Готово" : "Есть ошибки"
                        self.currentFile = "Текущий файл"
                        self.currentProgress = 0
                        self.overallProgress = 1
                        self.append("Пакетная обработка завершена.")
                        AppNotifier.shared.compressionFinished(done: self.doneFiles, failed: self.failedFiles)
                        if self.failedFiles == 0 {
                            self.clearJournal()
                        } else {
                            self.resumeAvailable = true
                            self.resumePendingCount = self.failedFiles
                            self.resumeTaskDescription = "\(self.failedFiles) из \(self.totalFiles) файлов"
                        }
                        return []
                    }
                    guard !additions.isEmpty else { return }
                    queue.append(contentsOf: additions)
                    continue
                }

                let item = queue[queueIndex]
                queueIndex += 1
                if Task.isCancelled { throw CompressionError.stopped }
                let shouldStop = DispatchQueue.main.sync { self.stopRequested }
                if shouldStop { throw CompressionError.stopped }
                DispatchQueue.main.sync {
                    self.updateJournal(item, state: .running)
                }

                do {
                    try FileManager.default.createDirectory(
                        at: item.destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    switch item.kind {
                    case .compress:
                        try compress(
                            file: item.source,
                            output: item.destination,
                            resolution: resolution,
                            compression: compression
                        )
                    case .copy:
                        DispatchQueue.main.async {
                            self.currentFile = item.source.lastPathComponent
                            self.currentProgress = 0
                            self.append("Копирую: \(item.source.lastPathComponent)")
                        }
                        if FileManager.default.fileExists(atPath: item.destination.path) {
                            try FileManager.default.removeItem(at: item.destination)
                        }
                        try FileManager.default.copyItem(at: item.source, to: item.destination)
                    }

                    DispatchQueue.main.sync {
                        self.doneFiles += 1
                        self.currentProgress = 1
                        self.updateOverallProgress()
                        let action = item.kind == .compress ? "Сжато" : "Скопировано"
                        self.append("\(action): \(item.destination.lastPathComponent)")
                        self.updateJournal(item, state: .succeeded)
                        AppNotifier.shared.compressionProgress(self.overallProgress)
                    }
                } catch let error as CompressionError {
                    if case .stopped = error { throw error }
                    DispatchQueue.main.sync {
                        self.recordFailure(item, error: error)
                    }
                } catch {
                    DispatchQueue.main.sync {
                        self.recordFailure(item, error: error)
                    }
                }

                let additions = DispatchQueue.main.sync { self.takeRetryRequests() }
                if !additions.isEmpty {
                    queue.append(contentsOf: additions)
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.isRunning = false
                self.status = "Ошибка"
                self.failedFiles += self.failedFiles == 0 && self.doneFiles < self.totalFiles ? 1 : 0
                self.activeProcess = nil
                let message = error.localizedDescription
                self.append(message)
                self.refreshResumeAvailability()
                AppNotifier.shared.compressionFailed(message)
            }
        }
    }

    nonisolated private func compress(
        file: URL,
        output: URL,
        resolution: Resolution,
        compression: Compression
    ) throws {
        let duration = try durationSeconds(for: file)
        DispatchQueue.main.async {
            self.currentFile = file.lastPathComponent
            self.currentProgress = 0
            self.append("Сжимаю: \(file.lastPathComponent)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ffmpegArguments(
            input: file,
            output: output,
            resolution: resolution,
            compression: compression
        )

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let watch = ProgressWatch()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("out_time_ms="),
                    let value = Int64(line.dropFirst("out_time_ms=".count)) {
                    let seconds = Double(value) / 1_000_000
                    let percent = min(0.99, seconds / duration)
                    watch.touch()
                    DispatchQueue.main.async {
                        self.currentProgress = percent
                        self.updateOverallProgress(currentItemProgress: percent)
                        AppNotifier.shared.compressionProgress(self.overallProgress)
                    }
                } else if line == "progress=end" {
                    watch.touch()
                    DispatchQueue.main.async {
                        self.currentProgress = 1
                        self.updateOverallProgress(currentItemProgress: 1)
                        AppNotifier.shared.compressionProgress(self.overallProgress)
                    }
                }
            }
        }

        try process.run()
        DispatchQueue.main.sync {
            self.activeProcess = process
        }

        while process.isRunning {
            let shouldStop = DispatchQueue.main.sync { self.stopRequested }
            if shouldStop {
                process.terminate()
                throw CompressionError.stopped
            }

            if watch.isStalled(timeout: stallTimeout) {
                process.terminate()
                throw CompressionError.stalled
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        process.waitUntilExit()
        DispatchQueue.main.sync {
            self.activeProcess = nil
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .split(separator: "\n")
                .suffix(4)
                .joined(separator: "\n")
            throw CompressionError.ffmpeg(message ?? "ffmpeg завершился с кодом \(process.terminationStatus).")
        }
    }

    nonisolated private func durationSeconds(for file: URL) throws -> Double {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            file.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return max(Double(text) ?? 0.1, 0.1)
    }

    private func append(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.append(LogLine(text: "[\(formatter.string(from: Date()))] \(text)"))
        if log.count > 240 {
            log.removeFirst(log.count - 240)
        }
    }
}

private enum CompressionError: LocalizedError {
    case stopped
    case stalled
    case ffmpeg(String)

    var errorDescription: String? {
        switch self {
        case .stopped:
            return "Остановлено пользователем."
        case .stalled:
            return "ffmpeg не отдавал прогресс больше двух минут. Процесс остановлен."
        case .ffmpeg(let message):
            return message
        }
    }
}

private func videoFiles(in folder: URL) -> [URL] {
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    return urls
        .filter(isSupportedVideoFile)
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

private func fileCountRecursively(in folder: URL) -> Int {
    guard let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    ) else { return 0 }

    var count = 0
    for case let url as URL in enumerator {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            count += 1
        }
    }
    return count
}

private func hierarchicalBatchPlan(from sourceFolders: [URL], outputFolder: URL) throws -> BatchPlan {
    var directories: [URL] = [outputFolder]
    var items: [WorkItem] = []
    var reservedRoots = Set<String>()

    for sourceFolder in sourceFolders {
        let destinationRoot = uniqueBatchRootURL(
            named: sourceFolder.lastPathComponent,
            in: outputFolder,
            reserved: &reservedRoots
        )
        directories.append(destinationRoot)

        let entries = fileTreeEntries(in: sourceFolder, excluding: outputFolder)
        var reservedDestinations = Set<String>()

        for entry in entries where !entry.isDirectory && !isSupportedVideoFile(entry.source) {
            let destination = appending(entry.relativeComponents, to: destinationRoot)
            reservedDestinations.insert(destination.standardizedFileURL.path)
            items.append(WorkItem(source: entry.source, destination: destination, kind: .copy))
        }

        for entry in entries where entry.isDirectory {
            directories.append(appending(entry.relativeComponents, to: destinationRoot))
        }

        for entry in entries where !entry.isDirectory && isSupportedVideoFile(entry.source) {
            let relativeParent = entry.relativeComponents.dropLast()
            let destinationDirectory = appending(relativeParent, to: destinationRoot)
            let destination = try preservedNameOutputURL(
                for: entry.source,
                in: destinationDirectory,
                reserved: &reservedDestinations
            )
            items.append(WorkItem(source: entry.source, destination: destination, kind: .compress))
        }
    }

    items.sort {
        $0.source.path.localizedStandardCompare($1.source.path) == .orderedAscending
    }
    directories.sort {
        $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
    return BatchPlan(directories: directories, items: items)
}

private func fileTreeEntries(in sourceFolder: URL, excluding excludedFolder: URL) -> [FileTreeEntry] {
    let sourceComponents = sourceFolder.standardizedFileURL.pathComponents
    let excludedPath = excludedFolder.standardizedFileURL.path
    guard let enumerator = FileManager.default.enumerator(
        at: sourceFolder,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    ) else { return [] }

    var entries: [FileTreeEntry] = []
    for case let url as URL in enumerator {
        let standardized = url.standardizedFileURL
        if standardized.path == excludedPath || standardized.path.hasPrefix(excludedPath + "/") {
            if (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator.skipDescendants()
            }
            continue
        }

        let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey])
        let relative = standardized.pathComponents.dropFirst(sourceComponents.count)
        guard !relative.isEmpty else { continue }
        entries.append(FileTreeEntry(
            source: standardized,
            relativeComponents: relative,
            isDirectory: values?.isDirectory == true
        ))
    }
    return entries
}

private func appending(_ components: ArraySlice<String>, to root: URL) -> URL {
    components.reduce(root) { partial, component in
        partial.appendingPathComponent(component)
    }
}

private func isSupportedVideoFile(_ url: URL) -> Bool {
    let extensions = Set(["mp4", "mov", "m4v", "avi", "mkv", "webm"])
    return extensions.contains(url.pathExtension.lowercased())
}

private func ffmpegArguments(
    input: URL,
    output: URL,
    resolution: Resolution,
    compression: Compression
) -> [String] {
    var arguments = [
        "-hide_banner", "-nostdin", "-y",
        "-i", input.path,
        "-map", "0:v:0", "-map", "0:a?",
        "-dn", "-sn",
        "-vf", resolution.scaleFilter,
    ]

    switch output.pathExtension.lowercased() {
    case "webm":
        arguments += [
            "-c:v", "libvpx-vp9",
            "-deadline", "good",
            "-cpu-used", "4",
            "-crf", compression.crf,
            "-b:v", "0",
            "-pix_fmt", "yuv420p",
            "-c:a", "libopus",
            "-b:a", compression.audioBitrate,
        ]
    case "avi":
        arguments += [
            "-c:v", "libx264",
            "-preset", compression.preset,
            "-crf", compression.crf,
            "-pix_fmt", "yuv420p",
            "-c:a", "libmp3lame",
            "-b:a", compression.audioBitrate,
        ]
    case "mkv":
        arguments += [
            "-c:v", "libx264",
            "-preset", compression.preset,
            "-crf", compression.crf,
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", compression.audioBitrate,
        ]
    default:
        arguments += [
            "-c:v", "libx264",
            "-preset", compression.preset,
            "-crf", compression.crf,
            "-pix_fmt", "yuv420p",
            "-tag:v", "avc1",
            "-c:a", "aac",
            "-b:a", compression.audioBitrate,
            "-movflags", "+faststart",
        ]
    }

    arguments += ["-progress", "pipe:1", "-nostats", output.path]
    return arguments
}

private func uniqueOutputURL(for input: URL, in folder: URL) throws -> URL {
    var reserved = Set<String>()
    return try uniqueOutputURL(for: input, in: folder, reserved: &reserved)
}

private func outputURL(for input: URL, in folder: URL) throws -> URL {
    var reserved = Set<String>()
    return try outputURL(for: input, in: folder, reserved: &reserved)
}

private func outputURL(for input: URL, in folder: URL, reserved: inout Set<String>) throws -> URL {
    let sourceFolder = input.deletingLastPathComponent().standardizedFileURL
    if sourceFolder == folder.standardizedFileURL {
        return try uniqueOutputURL(for: input, in: folder, reserved: &reserved)
    }
    return try preservedNameOutputURL(for: input, in: folder, reserved: &reserved)
}

private func preservedNameOutputURL(
    for input: URL,
    in folder: URL,
    reserved: inout Set<String>
) throws -> URL {
    var candidate = folder.appendingPathComponent(input.lastPathComponent)
    var path = candidate.standardizedFileURL.path
    if !FileManager.default.fileExists(atPath: path), !reserved.contains(path) {
        reserved.insert(path)
        return candidate
    }

    let base = input.deletingPathExtension().lastPathComponent
    let ext = input.pathExtension
    for index in 2..<1000 {
        let filename = ext.isEmpty ? "\(base)_\(index)" : "\(base)_\(index).\(ext)"
        candidate = folder.appendingPathComponent(filename)
        path = candidate.standardizedFileURL.path
        if !FileManager.default.fileExists(atPath: path), !reserved.contains(path) {
            reserved.insert(path)
            return candidate
        }
    }
    throw CompressionError.ffmpeg("Не удалось подобрать имя выходного файла.")
}

private func uniqueOutputURL(for input: URL, in folder: URL, reserved: inout Set<String>) throws -> URL {
    let base = input.deletingPathExtension().lastPathComponent
    var candidate = folder.appendingPathComponent("\(base)_compressed.mp4")
    if !FileManager.default.fileExists(atPath: candidate.path),
       !reserved.contains(candidate.standardizedFileURL.path) {
        reserved.insert(candidate.standardizedFileURL.path)
        return candidate
    }
    for index in 2..<1000 {
        candidate = folder.appendingPathComponent("\(base)_compressed_\(index).mp4")
        if !FileManager.default.fileExists(atPath: candidate.path),
           !reserved.contains(candidate.standardizedFileURL.path) {
            reserved.insert(candidate.standardizedFileURL.path)
            return candidate
        }
    }
    throw CompressionError.ffmpeg("Не удалось подобрать имя выходного файла.")
}

private func uniqueBatchRootURL(named name: String, in outputFolder: URL, reserved: inout Set<String>) -> URL {
    var candidate = outputFolder.appendingPathComponent(name, isDirectory: true)
    var path = candidate.standardizedFileURL.path
    if !FileManager.default.fileExists(atPath: path), !reserved.contains(path) {
        reserved.insert(path)
        return candidate
    }

    for index in 2..<1000 {
        let suffix = index == 2 ? " — сжато" : " — сжато \(index)"
        candidate = outputFolder.appendingPathComponent(name + suffix, isDirectory: true)
        path = candidate.standardizedFileURL.path
        if !FileManager.default.fileExists(atPath: path), !reserved.contains(path) {
            reserved.insert(path)
            return candidate
        }
    }
    return outputFolder.appendingPathComponent(name + " — сжато \(UUID().uuidString)", isDirectory: true)
}

struct ContentView: View {
    @ObservedObject var model: CompressorModel

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 18) {
                    sourceBlock

                    folderBlock(
                        title: "Папка для готовых файлов",
                        path: model.outputFolder?.path ?? "Не выбрана",
                        action: model.pickOutputFolder
                    )

                    HStack(spacing: 14) {
                        pickerBlock(title: "Разрешение", selection: $model.resolution)
                        pickerBlock(title: "Сжатие", selection: $model.compression)
                    }

                    metrics
                    progressBlock
                    logView
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    if model.resumeAvailable {
                        Button(action: model.resumeLastTask) {
                            VStack(spacing: 2) {
                                Text("Продолжить задачу")
                                Text(model.resumeTaskDescription)
                                    .font(.caption)
                                    .opacity(0.85)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(model.isRunning)
                    }

                    Button(action: model.start) {
                        Text("Начать сжатие")
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning)

                    Button(action: model.stop) {
                        Text("Остановить")
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.isRunning)

                    Button(action: model.retryFailedFiles) {
                        Text(model.retryableFailures > 0
                            ? "Повторить ошибки (\(model.retryableFailures))"
                            : "Повторить ошибки")
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.retryableFailures == 0)

                    Text("Ошибочные файлы можно вернуть в конец текущей очереди, не останавливая остальные. Подключите диск и нажмите «Повторить ошибки». В режиме нескольких папок структура каталогов сохраняется.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("От разработчика")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Привет, это Майк. Это полностью бесплатное приложение для сжатия ваших видеофайлов. Никогда и никому не позволяйте убедить вас в обратном.")
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(destination: URL(string: "https://nimoff.app/")!) {
                            Label("nimoff.app", systemImage: "arrow.up.right.square")
                                .font(.footnote.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .frame(width: 270)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(24)
        }
        .frame(minWidth: 920, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sourceBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Что сжимаем")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Источник", selection: $model.inputMode) {
                ForEach(InputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
            .onChange(of: model.inputMode) {
                model.scanFiles()
            }

            folderBlock(title: sourceTitle, path: sourcePath, action: sourceAction)
        }
    }

    private var sourceTitle: String {
        switch model.inputMode {
        case .file: return "Видеофайл"
        case .folder: return "Папка с видео"
        case .folders: return "Папки для пакетной обработки"
        }
    }

    private var sourcePath: String {
        switch model.inputMode {
        case .file:
            return model.inputFile?.path ?? "Не выбран"
        case .folder:
            return model.inputFolder?.path ?? "Не выбрана"
        case .folders:
            if model.inputFolders.isEmpty { return "Не выбраны" }
            if model.inputFolders.count == 1 { return model.inputFolders[0].path }
            return "Выбрано папок: \(model.inputFolders.count)"
        }
    }

    private var sourceAction: () -> Void {
        switch model.inputMode {
        case .file: return model.pickInputFile
        case .folder: return model.pickInputFolder
        case .folders: return model.pickInputFolders
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            HStack(spacing: 15) {
                appLogo
                VStack(alignment: .leading, spacing: 7) {
                    Text("Пакетное сжатие видео без лишних окон.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.top, 104)
        .padding(.bottom, 22)
    }

    private var appLogo: some View {
        Group {
            if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(Text("Ж").font(.largeTitle.bold()))
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private var statusColor: Color {
        if model.isRunning { return .blue }
        if model.failedFiles > 0 || model.status == "Ошибка" { return .red }
        return .green
    }

    private func folderBlock(title: String, path: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button("Выбрать", action: action)
                    .disabled(model.isRunning)
            }
        }
    }

    private func pickerBlock<T: CaseIterable & Identifiable>(title: String, selection: Binding<T>) -> some View where T.AllCases: RandomAccessCollection, T: Hashable, T.ID == String {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(Array(T.allCases)) { item in
                    Text(displayTitle(item)).tag(item)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .disabled(model.isRunning)
        }
    }

    private func displayTitle<T>(_ value: T) -> String {
        if let value = value as? Resolution { return value.title }
        if let value = value as? Compression { return value.title }
        return String(describing: value)
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metric(value: "\(model.totalFiles)", title: "файлов найдено")
            metric(value: "\(model.doneFiles)", title: "готово")
            metric(value: "\(model.failedFiles)", title: "ошибок")
        }
    }

    private func metric(value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.weight(.bold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var progressBlock: some View {
        VStack(spacing: 14) {
            progressRow(title: "Общий прогресс", value: model.overallProgress)
            progressRow(title: model.currentFile, value: model.currentProgress)
        }
    }

    private func progressRow(title: String, value: Double) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ProgressView(value: value)
                .progressViewStyle(.linear)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(model.log) { line in
                        Text(line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .frame(minHeight: 190)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: model.log.count) {
                if let last = model.log.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

@main
struct ZhmiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = CompressorModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
