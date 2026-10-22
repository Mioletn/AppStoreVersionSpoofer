// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's game screen.
//
// Two very different screens hide behind one view controller, and the app
// decides which:
//
//   * An app the native runtime drives (Unity, cocos2d-x, Minecraft, SDL,
//     Unreal, Godot, GTA, GameMaker, the Java runtime, Flutter) gets a
//     TLUnityUIView: the runtime hands that view's CAMetalLayer to EGL and the
//     game draws into it on its own thread through ANGLE. CAMetalLayer is iOS 8
//     and ANGLE here is built for 12.2, so this runs on 12.2 like the rest.
//   * Anything else runs on the older prototype loader, whose frames come back
//     as pixels. TLScreenUIView (upstream's, plain UIKit) presents them and
//     turns touches back into the guest's coordinates; LegacyAttemptRunner
//     drives the run. That path is iOS-version-agnostic and is what makes
//     iOS 12.2 work at all.
import UIKit

final class LegacyGameViewController: UIViewController {
    private let app: TLApp
    private var gameView: TLScreenUIView?
    /// Set when the native runtime owns the screen: the game draws into this
    /// view's CAMetalLayer through ANGLE, and nothing comes back as pixels.
    private var nativeView: TLUnityUIView?
    private var nativeTimer: DispatchSourceTimer?
    private var statusLabel = UILabel()
    private var chromeHidden = false
    private var logVisible = false
    private var logTextView = UITextView()
    private var logTimer: DispatchSourceTimer?

    init(app: TLApp) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var prefersStatusBarHidden: Bool { true }

    /// A landscape game in a portrait-first shell: the delegate's mask is the
    /// only place this app consults (nothing in the shell overrides it), so
    /// setting it here is what turns the screen -- the same call upstream's
    /// game screen makes when it appears.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard app.report?.nativeEngine != nil else { return }
        HuskOrientation.set(app.drawsPortraitByManifest() ? .portrait : .landscape)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard app.report?.nativeEngine != nil else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        HuskOrientation.set(HuskOrientation.standard)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        if !LegacyStore.shared.canRunOnThisiOS(app) {
            buildUnavailableScreen()
            return
        }
        // Which screen this is depends on the app, not on the iOS: a game the
        // native runtime can drive gets the runtime, everything else the pixel
        // path it always had.
        if app.report?.nativeEngine != nil, let apk = app.apks.first {
            buildNativeScreen(apk: apk)
        } else {
            buildPixelScreen()
        }
    }

    // MARK: the native runtime

    /// A game the runtime drives: Unity, cocos2d-x, Minecraft, SDL, Unreal,
    /// Godot, GTA, GameMaker, the Java runtime, Flutter. The runtime presents
    /// into this view's CAMetalLayer on its own thread; GL comes from the ANGLE
    /// dylib the app carries, which is built for 12.2 like everything else here.
    private func buildNativeScreen(apk: String) {
        let gv = TLUnityUIView(apk: apk,
                               extraApks: Array(app.apks.dropFirst()),
                               dataDir: app.nativeDataDir,
                               engine: app.screenEngine,
                               portrait: app.drawsPortraitByManifest())
        gv.onThreeFingerTap = { [weak self] in self?.toggleChrome() }
        gv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gv)
        NSLayoutConstraint.activate([
            gv.topAnchor.constraint(equalTo: view.topAnchor),
            gv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            gv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        nativeView = gv

        // No Stop: an engine cannot be unloaded once it has started (upstream
        // says the same). Back pauses the view and leaves it loaded.
        addChrome(includeStop: false)
        startNativePolling()
        HuskLog.log("tl", "ios12 shell: native runtime for \(app.label) (\(app.screenEngine))")
    }

    private func startNativePolling() {
        nativeTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.refreshStatus() }
        t.resume()
        nativeTimer = t
    }

    private func nativeStatusText() -> String {
        let state = husk_unity_state()
        let frames = husk_unity_frames()
        let phase: String
        if state == Int32(HUSK_UNITY_RUNNING) {
            phase = "Running"
        } else if state == Int32(HUSK_UNITY_ENDED) {
            phase = "Finished"
        } else if state == Int32(HUSK_UNITY_FAILED) {
            phase = "Failed"
        } else {
            phase = "Starting"
        }
        return "\(app.label) · \(phase) · \(frames) frames"
    }

    // MARK: the pixel path

    private func buildPixelScreen() {
        let gv = TLScreenUIView()
        gv.showsStats = true
        gv.onThreeFingerTap = { [weak self] in self?.toggleChrome() }
        gv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gv)
        NSLayoutConstraint.activate([
            gv.topAnchor.constraint(equalTo: view.topAnchor),
            gv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            gv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        gameView = gv

        addChrome(includeStop: true)

        LegacyAttemptRunner.shared.onChange = { [weak self] in self?.refreshStatus() }
        refreshStatus()
        LegacyAttemptRunner.shared.start(apks: app.apks)
    }

    /// The status line, the buttons and the log panel, over whichever view drew
    /// the game.
    private func addChrome(includeStop: Bool) {
        statusLabel.font = huskMonospacedFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.textAlignment = .center
        statusLabel.layer.cornerRadius = 8
        statusLabel.layer.masksToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        let back = LegacyUI.button("Back", filled: false)
        back.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        let log = LegacyUI.button("Log", filled: false)
        log.addTarget(self, action: #selector(logTapped), for: .touchUpInside)

        var buttons = [log, back]
        if includeStop {
            let stop = LegacyUI.button("Stop", filled: false)
            stop.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
            buttons.insert(stop, at: 0)
        }

        let pill = UIStackView(arrangedSubviews: buttons)
        pill.spacing = 8
        pill.distribution = .fillEqually
        pill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pill)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),

            pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            pill.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            pill.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])

        logTextView.backgroundColor = UIColor.black.withAlphaComponent(0.92)
        logTextView.textColor = UIColor(red: 0.8, green: 0.9, blue: 0.8, alpha: 1)
        logTextView.font = huskMonospacedFont(ofSize: 10, weight: .regular)
        logTextView.isEditable = false
        logTextView.isHidden = true
        logTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logTextView)
        NSLayoutConstraint.activate([
            logTextView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            logTextView.bottomAnchor.constraint(equalTo: pill.topAnchor, constant: -8),
        ])
    }

    private func buildUnavailableScreen() {
        let reason = LegacyStore.shared.unavailableReason(app) ?? "Not runnable on this iOS."
        let text = LegacyUI.body(
            "\(reason)\n\n"
            + "Games and ordinary Android apps do run here, on the native runtime or the older "
            + "loader path — the Library marks which one each app gets.", 15)
        text.textColor = .white
        text.translatesAutoresizingMaskIntoConstraints = false

        let close = LegacyUI.button("Back to Library")
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [text, close])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
        ])
    }

    // MARK: chrome

    private func refreshStatus() {
        if nativeView != nil {
            statusLabel.text = nativeStatusText()
            return
        }
        let runner = LegacyAttemptRunner.shared
        var text = "\(app.label) · \(runner.statusText)"
        if runner.isRunning { text += " · \(runner.frameCount) frames" }
        statusLabel.text = text
    }

    /// The runtime's own log, whichever path is on screen: the native runtime
    /// and the pixel loader write the same one.
    private var currentLog: String {
        guard let c = husk_tl_attempt_log() else { return "" }
        defer { free(c) }
        return String(cString: c)
    }

    @objc private func toggleChrome() {
        chromeHidden.toggle()
        view.subviews.compactMap { $0 as? UIStackView }.forEach { $0.isHidden = chromeHidden }
        statusLabel.isHidden = chromeHidden
    }

    @objc private func stopTapped() {
        LegacyAttemptRunner.shared.stop()
        refreshStatus()
    }

    @objc private func logTapped() {
        logVisible.toggle()
        logTextView.isHidden = !logVisible
        if logVisible {
            logTimer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: 0.5)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.logTextView.text = self.currentLog
            }
            t.resume()
            logTimer = t
        } else {
            logTimer?.cancel()
            logTimer = nil
        }
    }

    @objc private func closeTapped() {
        if nativeView != nil {
            // An engine cannot be unloaded once it has started: leaving the
            // screen pauses it, which didMoveToWindow also does when the view
            // comes off the window. It stays loaded for the next visit.
            nativeTimer?.cancel()
            nativeTimer = nil
            husk_unity_set_paused(true)
            nativeView?.removeFromSuperview()
            nativeView = nil
        } else {
            LegacyAttemptRunner.shared.stop()
            LegacyAttemptRunner.shared.onChange = nil
        }
        dismiss(animated: true)
    }

    deinit {
        logTimer?.cancel()
        nativeTimer?.cancel()
    }
}
