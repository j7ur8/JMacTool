import AppKit

@MainActor
final class CleaningViewController: NSViewController {
    private let showsExitButton: Bool
    private let onExit: () -> Void

    init(showsExitButton: Bool, onExit: @escaping () -> Void) {
        self.showsExitButton = showsExitButton
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.black.cgColor
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard showsExitButton else {
            return
        }

        let button = NSButton(title: AppConstants.exitButtonTitle, target: self, action: #selector(exitPressed))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.cgColor
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        button.layer?.borderWidth = 1
        button.layer?.cornerRadius = 18
        button.layer?.masksToBounds = true
        button.focusRingType = .none
        button.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        button.contentTintColor = .black

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 260),
            button.heightAnchor.constraint(equalToConstant: 74)
        ])
    }

    override func makeTouchBar() -> NSTouchBar? {
        let touchBar = NSTouchBar()
        touchBar.defaultItemIdentifiers = []
        touchBar.customizationAllowedItemIdentifiers = []
        return touchBar
    }

    @objc private func exitPressed() {
        onExit()
    }
}
