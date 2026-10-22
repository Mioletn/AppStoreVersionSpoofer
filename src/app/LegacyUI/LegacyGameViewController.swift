// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's game screen.
//
// Two very different screens hide behind one view controller:
//
//   * An app the native runtime would drive (Unity, cocos2d-x, Minecraft, SDL,
//     Unreal, Godot, GTA, GameMaker, the Java runtime, Flutter) is NOT runnable
//     here: that runtime presents into a CAMetalLayer, which is iOS 13+. The
//     controller says so plainly instead of starting something that would die.
//   * Anything else runs on the older prototype loader, whose frames come back
//     as pixels. TLScreenUIView (upstream's, plain UIKit) presents them and
//     turns touches back into the guest's coordinates; LegacyAttemptRunner
//     drives the run. That path is iOS-version-agnostic and is what makes
//     iOS 12.2 work at all.
import UIKit

final class LegacyGameViewController: UIViewController {
    private let app: TLApp
    private var gameView: TLScreenUIView?
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        if !LegacyStore.shared.canRunOnThisiOS(app) {
            buildUnavailableScreen()
            return
        }
        buildGameScreen()
    }

    // MARK: the runnable case

    private func buildGameScreen() {
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
        let stop = LegacyUI.button("Stop", filled: false)
        stop.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        let log = LegacyUI.button("Log", filled: false)
        log.addTarget(self, action: #selector(logTapped), for: .touchUpInside)

        let pill = UIStackView(arrangedSubviews: [stop, log, back])
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

        LegacyAttemptRunner.shared.onChange = { [weak self] in self?.refreshStatus() }
        refreshStatus()
        LegacyAttemptRunner.shared.start(apks: app.apks)
    }

    private func buildUnavailableScreen() {
        let reason = LegacyStore.shared.unavailableReason(app) ?? "Not runnable on this iOS."
        let text = LegacyUI.body(
            "\(reason)\n\n"
            + "What works here: apps on the older loader path, whose frames come back as pixels — "
            + "the Library marks which of your apps those are. Full Android emulation is likewise "
            + "iOS 13+ (its display goes through the same layer).", 15)
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
        let runner = LegacyAttemptRunner.shared
        var text = "\(app.label) · \(runner.statusText)"
        if runner.isRunning { text += " · \(runner.frameCount) frames" }
        statusLabel.text = text
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
                self.logTextView.text = LegacyAttemptRunner.shared.logText ?? ""
            }
            t.resume()
            logTimer = t
        } else {
            logTimer?.cancel()
            logTimer = nil
        }
    }

    @objc private func closeTapped() {
        LegacyAttemptRunner.shared.stop()
        LegacyAttemptRunner.shared.onChange = nil
        dismiss(animated: true)
    }

    deinit {
        logTimer?.cancel()
    }
}
