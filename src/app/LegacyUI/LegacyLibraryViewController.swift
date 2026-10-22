// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's Library: the games Husk can run here, how to add more,
// and what it cannot run. A plain UITableView over LegacyStore -- no diffable
// data sources (iOS 13+), no Combine.
import UIKit

final class LegacyLibraryViewController: UIViewController {
    private let table = UITableView(frame: .zero, style: .plain)
    private var store: LegacyStore { LegacyStore.shared }
    private var emptyLabel: UILabel?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = LegacyUI.background

        table.backgroundColor = .clear
        table.separatorColor = LegacyUI.surfaceHigh
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 76
        table.translatesAutoresizingMaskIntoConstraints = false
        table.register(LegacyAppCell.self, forCellReuseIdentifier: LegacyAppCell.reuseID)
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "JIT", style: .plain, target: self, action: #selector(jitTapped))

        let empty = LegacyUI.body("No games yet.\n\nTap + to add an APK, .xapk, .apkm or .apks, "
                                + "or drop one into Husk's folder in the Files app.\n\n"
                                + "JIT has to be on before a game can run — the JIT tab walks through it.",
                                 15)
        empty.textAlignment = .center
        empty.textColor = LegacyUI.textDim
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            empty.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -64),
        ])
        emptyLabel = empty

        store.reload()
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.reload()
        refresh()
    }

    private func refresh() {
        emptyLabel?.isHidden = !store.apps.isEmpty
        table.reloadData()
    }

    // MARK: actions

    @objc private func addTapped() {
        // The iOS 8+ document picker API: UTType (UniformTypeIdentifiers) is
        // iOS 14+, and these UTI strings work on every iOS from 8 up. The types
        // match the CFBundleDocumentTypes in Info.plist.
        let types = ["public.data", "public.archive", "public.content",
                     "com.android.package-archive",
                     "app.husk.xapk", "app.husk.apkm", "app.husk.apks"]
        let picker = UIDocumentPickerViewController(documentTypes: types, in: .import)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func jitTapped() {
        tabBarController?.selectedIndex = 1
    }

    private func run(_ app: TLApp) {
        guard store.canRunOnThisiOS(app) else {
            LegacyUI.Banner(store.unavailableReason(app) ?? "Not runnable on this iOS",
                            color: LegacyUI.warn).show(in: view)
            return
        }
        guard JITBootstrap.ready else {
            LegacyUI.Banner("JIT is not on yet — open the JIT tab first", color: LegacyUI.warn)
                .show(in: view)
            tabBarController?.selectedIndex = 1
            return
        }
        store.markPlayed(app)
        let vc = LegacyGameViewController(app: app)
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }
}

extension LegacyLibraryViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        store.apps.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LegacyAppCell.reuseID,
                                                 for: indexPath) as! LegacyAppCell
        cell.configure(with: store.apps[indexPath.row], store: store)
        return cell
    }

    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        store.remove(store.apps[indexPath.row])
        refresh()
    }
}

extension LegacyLibraryViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        run(store.apps[indexPath.row])
    }
}

extension LegacyLibraryViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        let banner = LegacyUI.Banner("Adding…", color: LegacyUI.surfaceHigh)
        banner.show(in: view, for: 30)
        store.importAPKs(urls) { [weak self] newID in
            banner.removeFromSuperview()
            guard let self else { return }
            self.refresh()
            if newID == nil {
                LegacyUI.Banner("That did not import — check the log in Settings",
                                color: LegacyUI.bad).show(in: self.view)
            }
        }
    }
}

/// One row: icon, name, what it is, and whether this iOS can run it.
final class LegacyAppCell: UITableViewCell {
    static let reuseID = "LegacyAppCell"

    private let icon = UIImageView()
    private let name = UILabel()
    private let detail = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .gray

        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 12
        icon.layer.masksToBounds = true
        icon.backgroundColor = LegacyUI.surfaceHigh
        icon.translatesAutoresizingMaskIntoConstraints = false

        name.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        name.textColor = LegacyUI.text

        detail.font = UIFont.systemFont(ofSize: 13)
        detail.textColor = LegacyUI.textDim
        detail.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [name, detail])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(icon)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),

            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(with app: TLApp, store: LegacyStore) {
        name.text = app.label
        var line = app.report?.nativeEngineName ?? "Android app"
        if let reason = store.unavailableReason(app) {
            line += " · \(reason)"
            name.textColor = LegacyUI.textDim
        } else {
            name.textColor = LegacyUI.text
        }
        detail.text = line
        icon.image = store.icon(for: app)
    }
}
