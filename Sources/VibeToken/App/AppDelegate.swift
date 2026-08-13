import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let outsideClickMonitor = OutsideClickMonitor()
    private var visualTestWindow: NSWindow?
    private var state: AppState?
    private var updateController: AppUpdateController?
    private var menuBarSummaryAnimator: MenuBarSummaryAnimator?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        do {
            let configuration = AppConfiguration.live()
            let database = try VibeTokenDatabase.openDefault(
                supportDirectory: configuration.applicationSupportDirectory
            )
            let repository = UsageRepository(database: database)
            let codexAdapter = CodexUsageAdapter(
                configuration: configuration,
                repository: repository
            )
            var usageSources: [any UsageSourceAdapter] = [
                codexAdapter,
                ClaudeCodeUsageAdapter(
                    configuration: configuration,
                    repository: repository
                ),
                GeminiCLIUsageAdapter(
                    configuration: configuration,
                    repository: repository
                ),
                OpenCodeUsageAdapter(
                    configuration: configuration,
                    repository: repository
                ),
                GitHubCopilotCLIUsageAdapter(
                    configuration: configuration,
                    repository: repository
                ),
                CursorUsageAdapter(
                    configuration: configuration,
                    repository: repository
                ),
                VSCodeTaskUsageAdapter(
                    tool: .cline,
                    configuration: configuration,
                    repository: repository
                ),
                VSCodeTaskUsageAdapter(
                    tool: .rooCode,
                    configuration: configuration,
                    repository: repository
                ),
                KiroUsageAdapter(
                    configuration: configuration,
                    repository: repository
                )
            ]
            usageSources.append(contentsOf: FileUsageTool.allCases.map {
                FileUsageAdapter(
                    tool: $0,
                    configuration: configuration,
                    repository: repository
                ) as any UsageSourceAdapter
            })
            usageSources.append(contentsOf: SQLiteUsageTool.allCases.map {
                SQLiteUsageAdapter(
                    tool: $0,
                    configuration: configuration,
                    repository: repository
                ) as any UsageSourceAdapter
            })
            usageSources.append(AntigravityUsageAdapter(
                configuration: configuration,
                repository: repository
            ))
            let ingestionCoordinator = UsageIngestionCoordinator(
                sources: usageSources,
                repository: repository,
                maximumWatchFiles: configuration.maximumWatchedSessionFiles
            )
            let sub2APISessionStore = FileSub2APISessionStore(
                supportDirectory: configuration.applicationSupportDirectory
            )
            let sub2APIConnectionStore = FileSub2APIConnectionStore(
                supportDirectory: configuration.applicationSupportDirectory
            )
            let sub2APICapacityConfigurationStore = FileSub2APICapacityConfigurationStore(
                supportDirectory: configuration.applicationSupportDirectory
            )
            let sub2APIClient = Sub2APIClient(
                sessionStore: sub2APISessionStore,
                requestTimeout: configuration.sub2APIRequestTimeoutSeconds
            )
            let sub2APIPoolMonitor = Sub2APIPoolMonitor(
                client: sub2APIClient,
                sessionStore: sub2APISessionStore,
                connectionStore: sub2APIConnectionStore,
                capacityConfigurationStore: sub2APICapacityConfigurationStore,
                pageSize: configuration.sub2APIPageSize,
                maximumPages: configuration.sub2APIMaximumPages,
                staleAfter: configuration.sub2APISnapshotStaleSeconds,
                minimumRefreshInterval: configuration.sub2APIMinimumRefreshSeconds,
                usageRefreshInterval: configuration.sub2APIUsageRefreshIntervalSeconds
            )
            let state = AppState(
                ingestionCoordinator: ingestionCoordinator,
                sub2APIPoolMonitor: sub2APIPoolMonitor,
                refreshInterval: configuration.refreshInterval,
                sub2APIRefreshInterval: configuration.sub2APIPollingInterval,
                fileEventDebounceMilliseconds: configuration.fileEventDebounceMilliseconds,
                costEstimator: CostEstimator(catalog: .officialAPI)
            )
            if ProcessInfo.processInfo.environment["VIBETOKEN_UI_TEST_SUB2API"] == "1" {
                state.installSub2APIVisualTestFixture()
            }
            self.state = state
            let updateController = AppUpdateController()
            self.updateController = updateController
            configureStatusItem(state: state)
            configurePopover(state: state, updateController: updateController)
            state.startMonitoring()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak state] _ in
                Task { @MainActor in
                    _ = await state?.refresh(forceRemote: true)
                }
            }
            scheduleVisualTestSurfaceIfNeeded()
            PrivacyLog.lifecycle.info("VibeToken started")
        } catch {
            PrivacyLog.database.fault("Database startup failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
            presentStartupFailure()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.stopMonitoring()
        menuBarSummaryAnimator?.stop()
        outsideClickMonitor.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func configureStatusItem(state: AppState) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        let image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "VibeToken")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = "--｜--"
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.toolTip = "VibeToken"
        button.target = self
        button.action = #selector(togglePopover(_:))
        statusItem = item

        let animator = MenuBarSummaryAnimator(button: button)
        menuBarSummaryAnimator = animator
        state.onMenuBarSummaryChange = { [weak animator] tokens, cost, locale in
            animator?.update(tokens: tokens, estimatedCost: cost, locale: locale)
        }
    }

    private func configurePopover(state: AppState, updateController: AppUpdateController) {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 500, height: 720)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                state: state,
                updateController: updateController,
                onQuit: { NSApp.terminate(nil) }
            )
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover(sender)
            return
        }
        showPopover()
    }

    private func showPopover() {
        guard !popover.isShown else { return }
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard popover.isShown else { return }
        outsideClickMonitor.start { [weak self] in
            self?.closePopover(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePopover(_ sender: Any?) {
        outsideClickMonitor.stop()
        guard popover.isShown else { return }
        popover.performClose(sender)
    }

    func popoverDidClose(_ notification: Notification) {
        outsideClickMonitor.stop()
    }

    private func presentStartupFailure() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "VibeToken 无法启动"
        alert.informativeText = "本地数据库初始化失败。请检查磁盘空间与目录权限后重试。"
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func scheduleVisualTestSurfaceIfNeeded() {
        let mode = ProcessInfo.processInfo.environment["VIBETOKEN_UI_TEST_MODE"]
        guard mode == "popover" || mode == "status-popover" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if mode == "status-popover" {
                togglePopover(nil)
            } else {
                showPopoverVisualTestWindow()
            }
        }
    }

    private func showPopoverVisualTestWindow() {
        guard let state, let updateController else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeToken Popover Preview"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: MenuBarView(
                state: state,
                updateController: updateController,
                onQuit: { NSApp.terminate(nil) }
            )
        )
        window.center()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        visualTestWindow = window
    }
}
