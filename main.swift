import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement

extension Notification.Name {
    static let clipHistoryChanged = Notification.Name("clipHistoryChanged")
    static let laqtaSettingsChanged = Notification.Name("laqtaSettingsChanged")
}

// MARK: - Settings

/// Wraps SMAppService so "launch at login" is a real login item visible in
/// System Settings ▸ General ▸ Login Items — same approach as Naqla.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[Laqta] LoginItem toggle failed: \(error)")
            fflush(stdout)
        }
    }
}

final class SettingsStore {
    static let shared = SettingsStore()

    private enum Key {
        static let maxItems = "maxItems"
        static let retentionHours = "retentionHours"
        static let opacity = "panelOpacity"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyDisplay = "hotKeyDisplay"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.maxItems: 30,
            Key.retentionHours: 24,
            Key.opacity: 1.0,
            Key.hotKeyCode: 9, // 'V'
            Key.hotKeyModifiers: Int(controlKey | cmdKey),
            Key.hotKeyDisplay: "⌃⌘V",
        ])
    }

    var maxItems: Int {
        get { defaults.integer(forKey: Key.maxItems) }
        set { defaults.set(newValue, forKey: Key.maxItems); changed() }
    }

    var retentionHours: Int {
        get { defaults.integer(forKey: Key.retentionHours) }
        set { defaults.set(newValue, forKey: Key.retentionHours); changed() }
    }

    var opacity: Double {
        get { defaults.double(forKey: Key.opacity) }
        set { defaults.set(newValue, forKey: Key.opacity); changed() }
    }

    /// Not stored here — SMAppService is the source of truth.
    var launchAtLogin: Bool {
        get { LoginItem.isEnabled }
        set { LoginItem.setEnabled(newValue); changed() }
    }

    /// A clipboard manager that isn't running misses everything you copy, so
    /// this switches itself on once; turning it off afterwards sticks.
    func enableLoginItemOnFirstRun() {
        let key = "didSetInitialLoginItem"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        LoginItem.setEnabled(true)
    }

    var hotKeyCode: UInt32 { UInt32(defaults.integer(forKey: Key.hotKeyCode)) }
    var hotKeyModifiers: UInt32 { UInt32(defaults.integer(forKey: Key.hotKeyModifiers)) }
    var hotKeyDisplay: String { defaults.string(forKey: Key.hotKeyDisplay) ?? "⌃⌘V" }

    func setHotKey(code: UInt32, modifiers: UInt32, display: String) {
        defaults.set(Int(code), forKey: Key.hotKeyCode)
        defaults.set(Int(modifiers), forKey: Key.hotKeyModifiers)
        defaults.set(display, forKey: Key.hotKeyDisplay)
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: .laqtaSettingsChanged, object: nil)
    }
}

// MARK: - Model

/// One entry in the clipboard history. Text and images are the only kinds
/// v1 understands — enough to match the everyday Windows+V use case.
struct ClipItem: Codable {
    enum Kind: String, Codable { case text, image }

    let id: UUID
    let kind: Kind
    var text: String?
    var imageData: Data? // always PNG once stored, regardless of source format
    var pinned: Bool
    var timestamp: Date

    init(id: UUID = UUID(), kind: Kind, text: String? = nil, imageData: Data? = nil, pinned: Bool = false, timestamp: Date = Date()) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageData = imageData
        self.pinned = pinned
        self.timestamp = timestamp
    }

    func sameContent(as other: ClipItem) -> Bool {
        kind == other.kind && text == other.text && imageData == other.imageData
    }
}

// MARK: - Store

/// Holds the history. Everything is written to disk so the retention window
/// (which outlives a single run of the app) means something; unpinned items
/// are swept once they age past it, pinned ones never expire.
final class ClipboardStore {
    static let shared = ClipboardStore()

    private(set) var items: [ClipItem] = []
    private var sweepTimer: Timer?
    private let ioQueue = DispatchQueue(label: "com.omar.laqta.store-io")

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Laqta", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }()

    private init() {
        load()
        // Sweep even if the panel is never opened, so nothing lingers on
        // disk past its retention window.
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.expire()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        // Expire without notifying: this runs inside the singleton's own
        // initialiser, and an observer reacting to it would re-enter
        // ClipboardStore.shared before it finishes initialising.
        let kept = unexpired(saved.sorted { $0.timestamp > $1.timestamp })
        items = kept
        if kept.count != saved.count { save() }
    }

    /// Encoding and writing the whole history (images included) can be tens
    /// of megabytes, so it must not happen on the main thread while the user
    /// is copying. The serial queue keeps writes in order.
    private func save() {
        let snapshot = items
        let url = fileURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Waits for any in-flight write so quitting can't drop the last copy.
    func flush() {
        ioQueue.sync {}
    }

    /// Re-copying something already in the list bumps it to the top instead
    /// of creating a duplicate row. (Laqta's own paste-back write no longer
    /// reaches here at all — see ClipboardWatcher.noteOwnWrite — but a
    /// genuine re-copy of the same content from outside still should.)
    func add(_ item: ClipItem) {
        if let idx = items.firstIndex(where: { $0.sameContent(as: item) }) {
            var existing = items.remove(at: idx)
            existing.timestamp = Date()
            items.insert(existing, at: 0)
        } else {
            items.insert(item, at: 0)
        }
        trim()
        persistAndNotify()
    }

    func togglePin(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].pinned.toggle()
        persistAndNotify()
    }

    /// Removes one item outright, pinned or not.
    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        persistAndNotify()
    }

    /// Clears everything except pinned items.
    func clearUnpinned() {
        items.removeAll { !$0.pinned }
        persistAndNotify()
    }

    /// Drops unpinned items older than the retention window.
    func expire() {
        let kept = unexpired(items)
        guard kept.count != items.count else { return }
        items = kept
        persistAndNotify()
    }

    private func unexpired(_ list: [ClipItem]) -> [ClipItem] {
        let cutoff = Date().addingTimeInterval(-Double(SettingsStore.shared.retentionHours) * 3600)
        return list.filter { $0.pinned || $0.timestamp >= cutoff }
    }

    /// Re-applies limits after the user changes them in Settings.
    func settingsChanged() {
        let before = items.count
        trim()
        if items.count != before { persistAndNotify() }
        expire()
    }

    private func trim() {
        var unpinnedSeen = 0
        let limit = SettingsStore.shared.maxItems
        items = items.filter { item in
            if item.pinned { return true }
            unpinnedSeen += 1
            return unpinnedSeen <= limit
        }
    }

    private func persistAndNotify() {
        save()
        NotificationCenter.default.post(name: .clipHistoryChanged, object: nil)
    }
}

// MARK: - Watcher

/// AppKit has no clipboard-change notification, so polling changeCount on a
/// short timer is the standard technique every Mac clipboard manager uses.
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    /// Password managers and similar tools mark sensitive copies with these
    /// UTIs by convention (org.nspasteboard.*) so well-behaved clipboard
    /// tools skip them. Naqla has no equivalent concern; this one does.
    private let skipTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Called right after Laqta itself writes to the pasteboard — paste-back,
    /// copy-only, or a joined multi-select paste. Without this, the very
    /// write that lets an old item get pasted looks to the poller like a
    /// brand-new copy, and either bumps that item back to the top of the
    /// list or (for a join) adds a bogus new entry — moving it from wherever
    /// it actually was.
    func noteOwnWrite() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if let types = pb.types, skipTypes.contains(where: types.contains) { return }

        if let png = normalizedPNG(from: pb) {
            ClipboardStore.shared.add(ClipItem(kind: .image, imageData: png))
            return
        }
        if let str = pb.string(forType: .string), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ClipboardStore.shared.add(ClipItem(kind: .text, text: str))
        }
    }

    private func normalizedPNG(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }
}

// MARK: - Paste-back

enum Paster {
    /// Writes the item back onto the system pasteboard, then simulates a real
    /// ⌘V. The caller dismisses the panel and reactivates the app the user
    /// came from first; the delay below gives that activation time to land,
    /// since posting ⌘V too early sends it nowhere.
    static func paste(_ item: ClipItem) {
        copyOnly(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            simulateCommandV()
        }
    }

    /// Puts the item on the clipboard and stops there, for when you want it
    /// ready to paste yourself rather than dropped in wherever you happen to be.
    static func copyOnly(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let data = item.imageData { pb.setData(data, forType: .png) }
        }
        // Otherwise the watcher sees this write as a fresh copy and bumps
        // this same item back to the top of the list, moving it from
        // wherever it actually sits.
        ClipboardWatcher.shared.noteOwnWrite()
    }

    /// Multi-select paste: joins each selected item's text with a blank line
    /// and pastes the result as one block. Images can't be concatenated this
    /// way, so they're silently skipped when joining more than one item —
    /// only the earlier `paste(_:)` handles a single image.
    static func pasteJoined(_ items: [ClipItem]) {
        let joined = items.compactMap(\.text).joined(separator: "\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(joined, forType: .string)
        // Otherwise this joined text — which matches none of the selected
        // items — gets picked up as a brand-new copy and added as a bogus
        // extra entry in the history.
        ClipboardWatcher.shared.noteOwnWrite()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            simulateCommandV()
        }
    }

    private static func simulateCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9 // 'V' on ANSI layouts
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - Row view

final class ClipRowView: NSTableCellView {
    private let preview = NSTextField(labelWithString: "")
    private let imagePreview = NSImageView()
    private let pinButton = NSButton()
    private let deleteButton = NSButton()
    private let copyButton = NSButton()
    var onTogglePin: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        preview.font = .systemFont(ofSize: 12)
        preview.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 2
        preview.textColor = .labelColor
        addSubview(preview)

        imagePreview.imageScaling = .scaleProportionallyUpOrDown
        imagePreview.wantsLayer = true
        imagePreview.layer?.cornerRadius = 4
        imagePreview.layer?.masksToBounds = true
        addSubview(imagePreview)

        pinButton.bezelStyle = .inline
        pinButton.isBordered = false
        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        addSubview(pinButton)

        deleteButton.bezelStyle = .inline
        deleteButton.isBordered = false
        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "حذف")
        deleteButton.contentTintColor = .tertiaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.toolTip = "حذف"
        addSubview(deleteButton)

        copyButton.bezelStyle = .inline
        copyButton.isBordered = false
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "نسخ")
        copyButton.contentTintColor = .tertiaryLabelColor
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.toolTip = "نسخ فقط، دون لصق"
        addSubview(copyButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pinSize: CGFloat = 22
        let deleteSize: CGFloat = 18
        let copySize: CGFloat = 17
        pinButton.frame = NSRect(x: bounds.width - pinSize - 8, y: (bounds.height - pinSize) / 2, width: pinSize, height: pinSize)
        deleteButton.frame = NSRect(x: pinButton.frame.minX - deleteSize - 2, y: (bounds.height - deleteSize) / 2, width: deleteSize, height: deleteSize)
        copyButton.frame = NSRect(x: deleteButton.frame.minX - copySize - 4, y: (bounds.height - copySize) / 2, width: copySize, height: copySize)

        let leading: CGFloat = 10
        let contentWidth = copyButton.frame.minX - leading - 6

        if imagePreview.image != nil {
            let thumbSize: CGFloat = bounds.height - 8
            imagePreview.frame = NSRect(x: leading, y: 4, width: thumbSize, height: thumbSize)
            imagePreview.isHidden = false
            preview.isHidden = true
        } else {
            imagePreview.isHidden = true
            preview.isHidden = false
            preview.frame = NSRect(x: leading, y: 0, width: contentWidth, height: bounds.height)
        }
    }

    func configure(with item: ClipItem, togglePin: @escaping () -> Void, delete: @escaping () -> Void, copy: @escaping () -> Void) {
        onTogglePin = togglePin
        onDelete = delete
        onCopy = copy
        // Rows are recycled, so clear both slots first — otherwise an item
        // whose image fails to decode would show the previous row's picture.
        imagePreview.image = nil
        preview.stringValue = ""
        toolTip = nil
        switch item.kind {
        case .text:
            let full = item.text ?? ""
            preview.stringValue = full.replacingOccurrences(of: "\n", with: " ⏎ ")
            // Two lines is all a row can show; hovering reveals the rest with
            // its real line breaks, capped so a huge paste can't fill the
            // screen — or blow up row recycling on a multi-megabyte copy.
            // Comparing endIndex after prefix(600) avoids full.count, which
            // would walk the entire string just to size-check it.
            let head = full.prefix(600)
            toolTip = head.endIndex == full.endIndex ? full : String(head) + "…"
        case .image:
            if let data = item.imageData, let image = NSImage(data: data) {
                imagePreview.image = image
                toolTip = "صورة · \(Int(image.size.width))×\(Int(image.size.height))"
            }
        }
        let symbol = item.pinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "تثبيت")
        pinButton.contentTintColor = item.pinned ? .controlAccentColor : .tertiaryLabelColor
        needsLayout = true
    }

    @objc private func pinTapped() {
        onTogglePin?()
    }

    @objc private func deleteTapped() {
        onDelete?()
    }

    @objc private func copyTapped() {
        onCopy?()
    }
}

// MARK: - Table view with keyboard support

/// Arrow keys already move the selection via NSTableView's built-in key
/// bindings once it's first responder; only Return/Escape need intercepting.
/// The search field is first responder when the panel opens and forwards
/// these same keys itself (see `control(_:textView:doCommandBy:)`), but
/// Tab can still hand focus to this table directly, so this stays live
/// rather than becoming dead code.
final class ClipTableView: NSTableView {
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    var onDeleteSelected: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onEnter?() // Return / keypad Enter
        case 53: onEscape?()    // Escape
        case 51, 117: onDeleteSelected?() // Backspace / Forward Delete
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Floating panel

/// A borderless NSWindow/NSPanel returns false from canBecomeKey, so macOS
/// silently refuses every makeKey request and arrow keys/Escape leak to
/// whatever app had focus. Overriding it is the only thing that fixes that.
final class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The header doubles as the drag handle — dragging anywhere else would
/// fight with click-to-paste on the rows.
final class DragHandleView: NSView {
    var onMoved: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // performDrag runs its own event loop and returns once the drag ends.
        let before = window?.frame.origin
        window?.performDrag(with: event)
        // A plain click lands here too, so only report an actual move —
        // otherwise one stray click would pin the panel's position for good.
        if let before, let after = window?.frame.origin, before != after {
            onMoved?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

final class PanelWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSSearchFieldDelegate {
    private let tableView = ClipTableView()
    private let searchField = NSSearchField()
    private let emptyLabel = NSTextField(labelWithString: "لا نتائج")
    private let rowHeight: CGFloat = 46
    private let headerHeight: CGFloat = 34
    private var backgroundView: NSVisualEffectView?

    /// The rows actually on screen — the history filtered by the search box.
    /// Every index the table hands back refers to this, never to the store.
    private var visible: [ClipItem] = []

    /// Wired up by the app delegate — the panel itself doesn't own Settings.
    var onOpenSettings: (() -> Void)?

    /// Captured when the panel opens so a keyboard-driven paste (which makes
    /// the panel key, stealing key-window status) can hand focus back before
    /// simulating ⌘V — mouse-driven paste never loses this in the first
    /// place, but reactivating an already-frontmost app is a harmless no-op.
    private var previousApp: NSRunningApplication?

    convenience init() {
        let panel = ClipPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        self.init(window: panel)
        panel.delegate = self
        buildUI(in: panel)

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .clipHistoryChanged, object: nil
        )
    }

    private func buildUI(in panel: NSPanel) {
        // The blurred backdrop is a sibling behind the content rather than
        // its superview, so the opacity setting can fade the background
        // without dragging the text's readability down with it.
        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        panel.contentView = container

        let background = NSVisualEffectView(frame: container.bounds)
        background.autoresizingMask = [.width, .height]
        background.material = .popover
        background.state = .active
        container.addSubview(background)
        backgroundView = background

        let topInset: CGFloat = 6 // breathing room from the rounded top edge
        let header = DragHandleView(frame: NSRect(x: 0, y: background.bounds.height - headerHeight - topInset, width: background.bounds.width, height: headerHeight))
        header.autoresizingMask = [.width, .minYMargin]
        header.onMoved = { [weak self] in self?.savePanelOrigin() }

        let title = NSTextField(labelWithString: "لَقْطة")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let titleHeight: CGFloat = 16
        title.frame = NSRect(x: 12, y: (headerHeight - titleHeight) / 2, width: 140, height: titleHeight)
        header.addSubview(title)

        let gearSize: CGFloat = 18
        let settingsButton = NSButton()
        settingsButton.bezelStyle = .inline
        settingsButton.isBordered = false
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "الإعدادات")
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.toolTip = "الإعدادات"
        settingsButton.frame = NSRect(x: background.bounds.width - gearSize - 12, y: (headerHeight - gearSize) / 2, width: gearSize, height: gearSize)
        settingsButton.autoresizingMask = [.minXMargin]
        header.addSubview(settingsButton)

        let clearAllButton = NSButton(title: "مسح الكل", target: self, action: #selector(clearAllTapped))
        clearAllButton.bezelStyle = .inline
        clearAllButton.isBordered = false
        clearAllButton.font = .systemFont(ofSize: 11)
        clearAllButton.contentTintColor = .secondaryLabelColor
        clearAllButton.sizeToFit()
        clearAllButton.frame.origin = NSPoint(x: settingsButton.frame.minX - clearAllButton.frame.width - 10, y: (headerHeight - clearAllButton.frame.height) / 2)
        clearAllButton.autoresizingMask = [.minXMargin]
        header.addSubview(clearAllButton)

        container.addSubview(header)

        let separator = NSBox(frame: NSRect(x: 0, y: header.frame.minY, width: background.bounds.width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        container.addSubview(separator)

        let searchHeight: CGFloat = 24
        searchField.frame = NSRect(x: 10, y: separator.frame.minY - 6 - searchHeight, width: background.bounds.width - 20, height: searchHeight)
        searchField.autoresizingMask = [.width, .minYMargin]
        searchField.placeholderString = "ابحث في المنسوخات"
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        // Only Return, the search button, or the field's own (×) clear button
        // fire the action this way — the delegate's controlTextDidChange
        // below is what drives live filtering per keystroke. The (×) button
        // sets stringValue directly, which does not trigger textDidChange,
        // so without this the list would stay stuck on the old query.
        searchField.sendsWholeSearchString = true
        container.addSubview(searchField)

        let searchSeparator = NSBox(frame: NSRect(x: 0, y: searchField.frame.minY - 6, width: background.bounds.width, height: 1))
        searchSeparator.boxType = .separator
        searchSeparator.autoresizingMask = [.width, .minYMargin]
        container.addSubview(searchSeparator)

        let listTop = searchSeparator.frame.minY
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: background.bounds.width, height: listTop))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        // Shift+↑/↓ (extendSelection) already selects multiple rows via direct
        // API calls regardless of this flag, but leaving it false understates
        // the control's real capability to accessibility clients like
        // VoiceOver, which query it to describe what the list supports.
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.onEnter = { [weak self] in self?.pasteSelected() }
        tableView.onEscape = { [weak self] in self?.dismiss() }
        tableView.onDeleteSelected = { [weak self] in self?.deleteSelected() }

        let column = NSTableColumn(identifier: .init("clip"))
        column.width = 300
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        emptyLabel.frame = NSRect(x: 0, y: listTop / 2 - 10, width: background.bounds.width, height: 20)
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.autoresizingMask = [.width]
        emptyLabel.isHidden = true
        container.addSubview(emptyLabel)

        applySettings()
    }

    /// Called on launch and whenever Settings changes.
    func applySettings() {
        backgroundView?.alphaValue = SettingsStore.shared.opacity
    }

    @objc private func clearAllTapped() {
        ClipboardStore.shared.clearUnpinned()
    }

    /// Hides the panel without handing focus back to the previous app —
    /// the Settings window is about to take it instead.
    @objc private func settingsTapped() {
        window?.orderOut(nil)
        onOpenSettings?()
    }

    private static let originKey = "panelOrigin"

    private var savedOrigin: NSPoint? {
        guard let raw = UserDefaults.standard.string(forKey: Self.originKey) else { return nil }
        return NSPointFromString(raw)
    }

    private func savePanelOrigin() {
        guard let origin = window?.frame.origin else { return }
        UserDefaults.standard.set(NSStringFromPoint(origin), forKey: Self.originKey)
    }

    /// Opens where the user last dragged the panel to, or — until they move
    /// it once — anchored at the mouse the way Windows+V does.
    func toggle() {
        guard let window else { return }
        if window.isVisible {
            dismiss()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        ClipboardStore.shared.expire()
        searchField.stringValue = ""
        reload()

        let anchor = savedOrigin ?? {
            let mouse = NSEvent.mouseLocation
            return NSPoint(x: mouse.x, y: mouse.y - window.frame.height)
        }()
        let screenFrame = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = anchor
        origin.x = min(max(origin.x, screenFrame.minX), screenFrame.maxX - window.frame.width)
        origin.y = min(max(origin.y, screenFrame.minY), screenFrame.maxY - window.frame.height)

        window.setFrameOrigin(origin)
        // ClipPanel.canBecomeKey is what actually lets this take focus; the
        // activate call is what makes the OS route keystrokes to us rather
        // than to the app the user was in. Focus goes back in dismiss().
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // The search field is first responder so typing works immediately;
        // its delegate forwards arrow keys, Return and Escape to the list.
        window.makeFirstResponder(searchField)
    }

    /// Also fires directly off `.clipHistoryChanged` (a copy arriving, or a
    /// change made from outside this panel) — always resetting selection
    /// here, not just at the call sites that used to pair reload() with
    /// selectFirstRow() by hand, is what keeps a multi-selection from
    /// silently pointing at the wrong rows after the list shifts under it.
    @objc private func reload() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = ClipboardStore.shared.items
        // localizedStandardContains ignores case and diacritics, which matters
        // for Arabic — "لقطة" should find "لَقْطة".
        visible = query.isEmpty ? all : all.filter { ($0.text ?? "").localizedStandardContains(query) }
        tableView.reloadData()
        emptyLabel.isHidden = !visible.isEmpty
        emptyLabel.stringValue = query.isEmpty ? "لا يوجد شيء منسوخ بعد" : "لا نتائج"
        selectFirstRow()
    }

    @objc private func rowClicked() {
        pasteRow(tableView.clickedRow)
    }

    /// A plain paste is one row; Shift+↑/↓ can select several, which pastes
    /// them joined into a single block instead.
    private func pasteSelected() {
        let rows = tableView.selectedRowIndexes
        guard rows.count > 1 else {
            pasteRow(tableView.selectedRow)
            return
        }
        let items = rows.sorted().compactMap { visible.indices.contains($0) ? visible[$0] : nil }
        dismiss()
        Paster.pasteJoined(items)
    }

    private func pasteRow(_ row: Int) {
        guard visible.indices.contains(row) else { return }
        let item = visible[row]
        dismiss()
        Paster.paste(item)
    }

    /// Anchor/focus pair driving Shift+↑/↓: anchor is the fixed end of the
    /// range, focus is the end that moves. A plain (non-shift) move collapses
    /// both back onto the same row, same as clicking a single row would.
    private var anchorRow = 0
    private var focusRow = 0

    private func moveSelection(by delta: Int) {
        guard !visible.isEmpty else { return }
        let current = tableView.selectedRow < 0 ? 0 : tableView.selectedRow
        let next = min(max(current + delta, 0), visible.count - 1)
        anchorRow = next
        focusRow = next
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    /// Shift+↑/↓: extends the selection from wherever it currently sits.
    private func extendSelection(by delta: Int) {
        guard !visible.isEmpty else { return }
        if tableView.selectedRowIndexes.count <= 1 {
            let current = tableView.selectedRow < 0 ? 0 : tableView.selectedRow
            anchorRow = current
            focusRow = current
        }
        focusRow = min(max(focusRow + delta, 0), visible.count - 1)
        let range = min(anchorRow, focusRow)...max(anchorRow, focusRow)
        tableView.selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: false)
        tableView.scrollRowToVisible(focusRow)
    }

    /// Backspace/Delete — the keyboard equivalent of a row's ✕ button, for
    /// every selected row when Shift+↑/↓ picked out more than one. Doesn't
    /// dismiss the panel, so repeated presses can clear several items.
    private func deleteSelected() {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty, rows.allSatisfy({ visible.indices.contains($0) }) else { return }
        let topRow = rows.min()!
        // Collect ids up front and delete by id, not index — each delete
        // reloads `visible` synchronously (via .clipHistoryChanged), which
        // would shift later indices out from under a second lookup.
        let ids = rows.sorted().map { visible[$0].id }
        ids.forEach { ClipboardStore.shared.delete($0) }
        guard !visible.isEmpty else { return }
        let next = min(topRow, visible.count - 1)
        anchorRow = next
        focusRow = next
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func selectFirstRow() {
        anchorRow = 0
        focusRow = 0
        if visible.isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    /// Fires on Return or a click on the field's own (×) clear button —
    /// the latter doesn't post textDidChange, so this is the only signal
    /// that the query was reset that way.
    @objc private func searchFieldAction() {
        reload()
    }

    /// The search box holds focus so you can just type, so the keys that drive
    /// the list have to be forwarded from here.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            extendSelection(by: -1)
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            extendSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            pasteSelected()
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            // Only takes over once the search box is already empty — otherwise
            // this is just an ordinary Backspace while typing a query, and the
            // field needs to handle it itself.
            guard searchField.stringValue.isEmpty else { return false }
            deleteSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape clears the search first, and only closes an empty box —
            // so a mistyped query doesn't cost you the whole panel.
            if searchField.stringValue.isEmpty {
                dismiss()
            } else {
                searchField.stringValue = ""
                reload()
            }
        default:
            return false
        }
        return true
    }

    /// Hides the panel and hands keyboard focus back to whatever app had it
    /// before the panel opened.
    private func dismiss() {
        window?.orderOut(nil)
        previousApp?.activate(options: [])
    }

    func windowDidResignKey(_ notification: Notification) {
        // Fires when the user clicks into a different app/window directly;
        // that app is already becoming key on its own, so just hide.
        window?.orderOut(nil)
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        visible.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("clipRow")
        let rowView = (tableView.makeView(withIdentifier: identifier, owner: self) as? ClipRowView) ?? ClipRowView(frame: .zero)
        rowView.identifier = identifier
        let item = visible[row]
        rowView.configure(with: item, togglePin: {
            ClipboardStore.shared.togglePin(item.id)
        }, delete: {
            ClipboardStore.shared.delete(item.id)
        }, copy: { [weak self] in
            self?.dismiss()
            Paster.copyOnly(item)
        })
        return rowView
    }
}

// MARK: - Global hotkey (Carbon — no Accessibility/Input Monitoring needed)

private var hotKeyToggleHandler: (() -> Void)?

private func hotKeyEventHandler(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    hotKeyToggleHandler?()
    return noErr
}

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    func register(keyCode: UInt32, modifiers: UInt32, toggle: @escaping () -> Void) {
        hotKeyToggleHandler = toggle

        if !handlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, nil)
            handlerInstalled = true
        }

        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x43444B48), id: 1) // 'CDKH'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let maxItemsField = NSTextField()
    private let maxItemsStepper = NSStepper()
    private let retentionPopup = NSPopUpButton()
    private let opacitySlider = NSSlider()
    private let opacityValue = NSTextField(labelWithString: "")
    private let hotKeyButton = NSButton()
    private let loginItemCheckbox = NSButton()

    private var recordMonitor: Any?

    private let retentionOptions: [(label: String, hours: Int)] = [
        ("ساعة واحدة", 1),
        ("٤ ساعات", 4),
        ("٨ ساعات", 8),
        ("١٢ ساعة", 12),
        ("٢٤ ساعة", 24),
        ("٣ أيام", 72),
        ("أسبوع", 168),
    ]

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "إعدادات لَقْطة"
        window.center()
        // The delegate keeps this controller alive and reopens the same
        // window, so closing must not deallocate it.
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildUI(in: window)
        refresh()
    }

    private func buildUI(in window: NSWindow) {
        guard let content = window.contentView else { return }

        maxItemsField.formatter = {
            let f = NumberFormatter()
            f.minimum = 5
            f.maximum = 200
            f.allowsFloats = false
            return f
        }()
        maxItemsField.alignment = .center
        maxItemsField.target = self
        maxItemsField.action = #selector(maxItemsEdited)
        maxItemsField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        maxItemsStepper.minValue = 5
        maxItemsStepper.maxValue = 200
        maxItemsStepper.increment = 5
        maxItemsStepper.valueWraps = false
        maxItemsStepper.target = self
        maxItemsStepper.action = #selector(maxItemsStepped)

        retentionPopup.addItems(withTitles: retentionOptions.map(\.label))
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged)

        opacitySlider.minValue = 0.5
        opacitySlider.maxValue = 1.0
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        opacityValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        opacityValue.textColor = .secondaryLabelColor

        hotKeyButton.bezelStyle = .rounded
        hotKeyButton.target = self
        hotKeyButton.action = #selector(hotKeyTapped)
        hotKeyButton.widthAnchor.constraint(equalToConstant: 120).isActive = true

        loginItemCheckbox.setButtonType(.switch)
        loginItemCheckbox.title = "تشغيل لَقْطة تلقائيًا عند بدء تشغيل الماك"
        loginItemCheckbox.font = .systemFont(ofSize: 13)
        loginItemCheckbox.target = self
        loginItemCheckbox.action = #selector(loginItemToggled)

        let note = NSTextField(labelWithString: "العناصر المثبتة (📌) لا تنتهي صلاحيتها ولا تتأثر بالمدة.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [
            row("عدد العناصر المحفوظة", [maxItemsField, maxItemsStepper]),
            row("مدة حفظ غير المثبت", [retentionPopup]),
            row("شفافية اللوحة", [opacitySlider, opacityValue]),
            row("اختصار الفتح", [hotKeyButton]),
            loginItemCheckbox,
            note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
        ])
    }

    private func row(_ title: String, _ controls: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let stack = NSStackView(views: [label] + controls)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func refresh() {
        let s = SettingsStore.shared
        maxItemsField.stringValue = "\(s.maxItems)"
        maxItemsStepper.integerValue = s.maxItems
        if let idx = retentionOptions.firstIndex(where: { $0.hours == s.retentionHours }) {
            retentionPopup.selectItem(at: idx)
        }
        opacitySlider.doubleValue = s.opacity
        opacityValue.stringValue = "\(Int(s.opacity * 100))٪"
        hotKeyButton.title = s.hotKeyDisplay
        loginItemCheckbox.state = s.launchAtLogin ? .on : .off
    }

    // MARK: Actions

    @objc private func maxItemsEdited() {
        let clamped = min(max(maxItemsField.integerValue, 5), 200)
        SettingsStore.shared.maxItems = clamped
        refresh()
    }

    @objc private func maxItemsStepped() {
        SettingsStore.shared.maxItems = maxItemsStepper.integerValue
        refresh()
    }

    @objc private func retentionChanged() {
        let idx = retentionPopup.indexOfSelectedItem
        guard retentionOptions.indices.contains(idx) else { return }
        SettingsStore.shared.retentionHours = retentionOptions[idx].hours
    }

    @objc private func opacityChanged() {
        SettingsStore.shared.opacity = opacitySlider.doubleValue
        opacityValue.stringValue = "\(Int(opacitySlider.doubleValue * 100))٪"
    }

    @objc private func loginItemToggled() {
        SettingsStore.shared.launchAtLogin = (loginItemCheckbox.state == .on)
        // macOS can refuse the registration, so show what actually stuck.
        refresh()
    }

    @objc private func hotKeyTapped() {
        guard recordMonitor == nil else { stopRecording(); return }
        hotKeyButton.title = "اضغط الاختصار…"
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.capture(event)
            return nil // swallow it so the combo doesn't reach anything else
        }
    }

    /// Ignores anything without a modifier — a bare key would fire globally
    /// while the user is typing anywhere on the system.
    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 { stopRecording(); return } // Escape cancels

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var display = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); display += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); display += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); display += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); display += "⌘" }

        guard carbon != 0,
              let typed = event.charactersIgnoringModifiers?.uppercased(),
              !typed.isEmpty else { return }

        SettingsStore.shared.setHotKey(code: UInt32(event.keyCode), modifiers: carbon, display: display + typed)
        stopRecording()
    }

    private func stopRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
    }

    /// Losing focus mid-recording (e.g. the still-registered old hotkey fired
    /// and opened the panel) would otherwise leave the monitor swallowing keys.
    func windowDidResignKey(_ notification: Notification) {
        stopRecording()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = GlobalHotKey()
    private let panel = PanelWindowController()
    private var settings: SettingsWindowController?
    private var registeredHotKey: (code: UInt32, modifiers: UInt32)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()

        SettingsStore.shared.enableLoginItemOnFirstRun()
        ClipboardWatcher.shared.start()
        registerHotKey()
        panel.onOpenSettings = { [weak self] in self?.showSettings() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "لَقْطة")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "الإعدادات…", action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "إنهاء لَقْطة", action: #selector(quit), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: .laqtaSettingsChanged, object: nil
        )
    }

    /// Double-clicking the app on the Desktop while it's already running
    /// lands here — that's the user's other way into Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    @objc private func showSettings() {
        if settings == nil { settings = SettingsWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func settingsChanged() {
        registerHotKey()
        ClipboardStore.shared.settingsChanged()
        panel.applySettings()
    }

    private func registerHotKey() {
        let store = SettingsStore.shared
        let wanted = (code: store.hotKeyCode, modifiers: store.hotKeyModifiers)
        guard registeredHotKey == nil || registeredHotKey! != wanted else { return }
        registeredHotKey = wanted

        hotKey.register(keyCode: wanted.code, modifiers: wanted.modifiers) { [weak self] in
            // Showing/activating a panel synchronously inside the Carbon
            // callback races with the OS returning key focus after the
            // hotkey's own keyup — deferring a tick avoids that race.
            DispatchQueue.main.async {
                self?.panel.toggle()
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardStore.shared.flush()
    }

    /// Posting a synthetic ⌘V (see Paster) needs Accessibility access on
    /// modern macOS, unlike Naqla's Carbon hotkey which needs none. This
    /// triggers the system's own permission dialog on first launch; if
    /// already denied, it silently stays denied until granted by hand in
    /// System Settings ▸ Privacy & Security ▸ Accessibility.
    private func requestAccessibilityIfNeeded() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
