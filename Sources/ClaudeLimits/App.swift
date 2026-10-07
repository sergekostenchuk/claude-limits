import AppKit
import ServiceManagement
import ClaudeLimitsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let monitor = UsageMonitor(client: UsageClient(debug: CommandLine.arguments.contains("--debug")))
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var labels: [String: NSMenuItem] = [:]
    private var updateItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var accessItem: NSMenuItem!
    private var authorizing = false
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil); return
        }
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        if let url = Bundle.main.url(forResource: "ClaudeIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 24, height: 24)
            icon.isTemplate = true
            item.button?.image = icon
            item.button?.imagePosition = .imageLeft
        }
        item.button?.setAccessibilityLabel("Оставшиеся лимиты Claude: Fable, Opus, 5 часов")
        configureMenu()
        monitor.onChange = { [weak self] in self?.render() }
        if CommandLine.arguments.contains("--enable-login") { enableLogin() }
        render(); refresh()
        // A short UI tick expires old numbers; network requests have their own backoff.
        let tick = Timer(timeInterval: 15, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(tick, forMode: .common); timer = tick
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }

    private func configureMenu() {
        menu.autoenablesItems = false; menu.delegate = self
        for key in ["heading", "stale", "fable", "fableReset", "opus", "opusReset", "five", "fiveReset",
                    "weekly", "weeklyReset", "updated", "empty", "error"] {
            let entry = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            entry.isEnabled = false; labels[key] = entry; menu.addItem(entry)
        }
        menu.addItem(.separator())
        func action(_ title: String, _ selector: Selector) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self; menu.addItem(entry); return entry
        }
        updateItem = action("Обновить сейчас", #selector(refresh))
        accessItem = action("Разрешить чтение авторизации…", #selector(allowKeychain))
        _ = action("Открыть лимиты Claude", #selector(openUsage))
        _ = action("Войти в Claude Code…", #selector(loginClaude))
        loginItem = action("Запускать при входе", #selector(toggleLogin))
        menu.addItem(.separator())
        _ = action("Завершить Claude Limits", #selector(quit))
        item.menu = menu
    }

    private func render() {
        item.button?.title = monitor.title
        item.button?.toolTip = "Claude · оставшиеся лимиты\n" + (monitor.error?.localizedDescription ?? monitor.title)
        for entry in labels.values { entry.isHidden = true }
        func text(_ key: String, _ title: String) {
            labels[key]?.title = title; labels[key]?.isHidden = false
        }
        text("heading", "Claude · осталось")
        if let snapshot = monitor.snapshot {
            let stale = monitor.error != nil || Date().timeIntervalSince(snapshot.fetchedAt) > 300
            if stale { text("stale", "Последние данные устарели") }
            func row(_ key: String, _ label: String, _ window: UsageWindow?) {
                guard let window else { text(key, "\(label): нет отдельного показателя"); return }
                let expired = window.isExpired(at: Date())
                text(key, "\(label): \(expired ? "ожидаю новый период" : window.percent + (stale ? " (старые данные)" : ""))")
                if let reset = window.resetsAt {
                    text(key + "Reset", "   Сброс: \(reset.formatted(date: .abbreviated, time: .shortened))")
                } else { text(key + "Reset", "   Время сброса не передано") }
            }
            row("fable", "F · Fable, неделя", snapshot.fable)
            row("opus", snapshot.opusUsesSharedWeek ? "O · общая неделя, включая Opus" : "O · Opus, неделя", snapshot.opus)
            row("five", "5 · общий лимит на 5 часов", snapshot.fiveHour)
            if !snapshot.opusUsesSharedWeek { row("weekly", "Общая неделя, все модели", snapshot.weekly) }
            text("updated", "Обновлено: \(snapshot.fetchedAt.formatted(date: .omitted, time: .standard))")
        } else { text("empty", monitor.refreshing ? "Читаю лимиты…" : "Лимиты пока недоступны") }
        if let error = monitor.error { text("error", error.localizedDescription) }
        updateItem.title = monitor.refreshing ? "Обновление…" : "Обновить сейчас"
        updateItem.isEnabled = !monitor.refreshing && !authorizing
        if case .rateLimited = monitor.error, Date() < monitor.nextAttempt { updateItem.isEnabled = false }
        accessItem.isHidden = monitor.error != .keychainAccess
        accessItem.isEnabled = !authorizing
        loginItem.title = SMAppService.mainApp.status == .requiresApproval ? "Разрешить автозапуск в macOS…" : "Запускать при входе"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) { Task { await monitor.refresh() } }
    @objc private func tick() { render(); Task { await monitor.refresh() } }
    @objc private func refresh() { Task { await monitor.refresh(manual: true) } }
    @objc private func openUsage() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
    @objc private func loginClaude() {
        guard let script = Bundle.main.url(forResource: "Login", withExtension: "command") else { return }
        NSWorkspace.shared.open(script)
    }
    @objc private func allowKeychain() {
        guard !authorizing else { return }
        authorizing = true; render()
        Task {
            _ = try? await Task.detached { try ClaudeCredential.read(interactive: true) }.value
            authorizing = false
            await monitor.refresh(manual: true)
        }
    }
    private func enableLogin() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do { try SMAppService.mainApp.register() }
        catch { showError("Не удалось включить автозапуск", error.localizedDescription) }
    }
    @objc private func toggleLogin() {
        switch SMAppService.mainApp.status {
        case .enabled:
            do { try SMAppService.mainApp.unregister() }
            catch { showError("Не удалось отключить автозапуск", error.localizedDescription) }
        case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
        default: enableLogin()
        }
        render()
    }
    private func showError(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Понятно"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
enum ClaudeLimitsApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            Task { @MainActor in
                var result: [String: Any] = ["bundlePath": Bundle.main.bundlePath,
                    "loginItemEnabled": SMAppService.mainApp.status == .enabled]
                if !CommandLine.arguments.contains("--local-only") { do {
                    let snapshot = try await UsageClient().fetch()
                    result["title"] = snapshot.title(at: Date())
                    result["opusUsesSharedWeek"] = snapshot.opusUsesSharedWeek
                    result["authenticated"] = true
                } catch {
                    result["error"] = (error as? UsageError ?? .network).localizedDescription
                    result["authenticated"] = false
                } }
                let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self)); exit(0)
            }
            RunLoop.main.run()
        } else {
            let app = NSApplication.shared, delegate = AppDelegate()
            app.delegate = delegate; app.run()
        }
    }
}
