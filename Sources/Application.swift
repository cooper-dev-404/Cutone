import AppKit
import SwiftUI
import Combine

@main
struct JianYiDaoApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppController()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let editor = Editor()
    var window: NSWindow!
    var observation: AnyCancellable?
    var shortcuts: Any?
    var queued: [URL] = []
    var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenus()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1090, height: 690),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.window = window
        window.title = "剪一刀"
        window.minSize = NSSize(width: 880, height: 630)
        window.contentView = NSHostingView(rootView: WorkspaceView(editor: editor))
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("QingJianWorkspace")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        observation = editor.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window.isDocumentEdited = self.editor.hasUnsavedChanges
                self.window.title = self.editor.projectURL?.deletingPathExtension().lastPathComponent ?? "剪一刀"
            }
        }
        shortcuts = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isKeyWindow, self.window.attachedSheet == nil,
                  !(self.window.firstResponder is NSTextView), !self.editor.busy,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            switch event.keyCode {
            case 49: self.editor.togglePlayback()
            case 123: self.editor.stepFrame(-1)
            case 124: self.editor.stepFrame(1)
            case 34: self.editor.setIn()
            case 31: self.editor.setOut()
            default: return event
            }
            return nil
        }
        if !queued.isEmpty { handle(queued); queued.removeAll() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if window == nil { queued.append(contentsOf: urls) } else { handle(urls) }
    }
    private func handle(_ urls: [URL]) {
        window.makeKeyAndOrderFront(nil)
        if let project = urls.first(where: { $0.pathExtension.lowercased() == "qingjian" }) {
            editor.loadProject(from: project)
        } else { editor.importFiles(urls) }
    }

    private func mayClose() -> Bool {
        if editor.busy {
            let alert = NSAlert()
            alert.messageText = "正在处理视频"
            alert.informativeText = editor.isExporting ? "请等待导出完成，或先在窗口中取消导出。" : "请先完成或取消当前操作。"
            alert.runModal()
            return false
        }
        guard editor.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "退出前存储剪辑项目？"
        alert.informativeText = "项目记录剪切位置、片段顺序和导出设置。"
        alert.addButton(withTitle: "存储…")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "放弃修改")
        switch alert.runModal() {
        case .alertFirstButtonReturn: editor.saveProject(); return !editor.hasUnsavedChanges
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard mayClose() else { return false }
        quitting = true
        NSApp.terminate(nil)
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (quitting || mayClose()) ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let shortcuts { NSEvent.removeMonitor(shortcuts) }
        MediaCompatibility.cleanSession()
    }

    private func buildMenus() {
        let main = NSMenu()
        func submenu(_ name: String) -> NSMenu {
            let item = NSMenuItem(); main.addItem(item)
            let menu = NSMenu(title: name); item.submenu = menu
            return menu
        }
        func add(_ title: String, _ action: Selector, _ key: String, in menu: NSMenu,
                 modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        let app = submenu("剪一刀")
        add("关于剪一刀", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", in: app, target: NSApp)
        app.addItem(.separator())
        add("隐藏剪一刀", #selector(NSApplication.hide(_:)), "h", in: app, target: NSApp)
        add("退出剪一刀", #selector(NSApplication.terminate(_:)), "q", in: app, target: NSApp)
        let file = submenu("文件")
        add("导入视频…", #selector(importFiles), "i", in: file, target: self)
        add("打开项目…", #selector(openProject), "o", in: file, target: self)
        add("存储项目", #selector(saveProject), "s", in: file, target: self)
        add("项目另存为…", #selector(saveAs), "s", in: file, modifiers: [.command,.shift], target: self)
        file.addItem(.separator())
        add("导出成片…", #selector(exportVideo), "e", in: file, target: self)
        add("兼容缓存位置…", #selector(cacheLocation), "", in: file, target: self)
        add("关闭窗口", #selector(NSWindow.performClose(_:)), "w", in: file)
        let edit = submenu("编辑")
        add("撤销", #selector(undoEdit), "z", in: edit, target: self)
        add("重做", #selector(redoEdit), "z", in: edit, modifiers: [.command,.shift], target: self)
        edit.addItem(.separator())
        add("剪切", #selector(NSText.cut(_:)), "x", in: edit)
        add("复制", #selector(NSText.copy(_:)), "c", in: edit)
        add("粘贴", #selector(NSText.paste(_:)), "v", in: edit)
        add("全选", #selector(NSText.selectAll(_:)), "a", in: edit)
        edit.addItem(.separator())
        add("在播放头分割", #selector(split), "k", in: edit, target: self)
        add("删除入点至出点", #selector(removeRange), "\u{8}", in: edit, target: self)
        let windowMenu = submenu("窗口")
        add("最小化", #selector(NSWindow.performMiniaturize(_:)), "m", in: windowMenu)
        add("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", in: windowMenu, modifiers: [.control,.command])
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
    @objc func importFiles() { editor.chooseFiles() }
    @objc func openProject() { editor.openProject() }
    @objc func saveProject() { editor.saveProject() }
    @objc func saveAs() { editor.saveProjectAs() }
    @objc func exportVideo() { editor.exportMovie() }
    @objc func undoEdit() { editor.undo() }
    @objc func redoEdit() { editor.redo() }
    @objc func split() { editor.split() }
    @objc func removeRange() { editor.removeRange() }
    @objc func cacheLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "使用此文件夹"
        panel.message = "部分 MKV 等素材需建立兼容副本，可选择外接盘。正常退出时清理本次副本。"
        if panel.runModal() == .OK, let url = panel.url { UserDefaults.standard.set(url.path, forKey: MediaCompatibility.directoryKey) }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !editor.busy else { return false }
        switch menuItem.action {
        case #selector(undoEdit): return editor.canUndo
        case #selector(redoEdit): return editor.canRedo
        case #selector(split), #selector(exportVideo): return !editor.segments.isEmpty
        case #selector(removeRange): return editor.canRemoveRange
        default: return true
        }
    }
}
