import SwiftUI
import UIKit

/// Écran du Mac, zoomable, qui traduit les gestes en clics.
///
/// - toucher : clic gauche à cet endroit
/// - double toucher : double clic
/// - appui long : clic droit
/// - glisser à deux doigts : défilement
/// - pincer : zoom local (rien n'est envoyé au Mac) ; un doigt déplace la vue zoomée
final class RemoteScreenView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// Point normalisé (0…1) sur l'image, clic droit, nombre de clics.
    var onClick: (@MainActor (CGPoint, Bool, Int) -> Void)?
    /// Défilement en points du Mac.
    var onScroll: (@MainActor (Double, Double) -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var imageSize: CGSize = .zero
    private var laidOutFor: (bounds: CGSize, image: CGSize) = (.zero, .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        addSubview(scrollView)

        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: doubleTap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        let twoFingers = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPan(_:)))
        twoFingers.minimumNumberOfTouches = 2
        twoFingers.maximumNumberOfTouches = 2
        twoFingers.delegate = self

        for recognizer in [doubleTap, tap, longPress, twoFingers] {
            imageView.addGestureRecognizer(recognizer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) non utilisé")
    }

    func show(_ image: UIImage) {
        imageView.image = image
        if image.size != imageSize {
            imageSize = image.size
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        guard laidOutFor.bounds != bounds.size || laidOutFor.image != imageSize else { return }
        laidOutFor = (bounds.size, imageSize)

        // À l'échelle 1, l'image tient entière dans la vue, proportions gardées.
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        scrollView.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        center()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
    }

    private func center() {
        let free = CGSize(width: scrollView.bounds.width - scrollView.contentSize.width,
                          height: scrollView.bounds.height - scrollView.contentSize.height)
        scrollView.contentInset = UIEdgeInsets(top: max(0, free.height / 2), left: max(0, free.width / 2),
                                               bottom: 0, right: 0)
    }

    /// Position du geste en fraction de l'image : indépendante du zoom.
    private func normalized(_ recognizer: UIGestureRecognizer) -> CGPoint? {
        let point = recognizer.location(in: imageView)
        let size = imageView.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        return CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let point = normalized(recognizer) else { return }
        onClick?(point, false, 1)
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard let point = normalized(recognizer) else { return }
        onClick?(point, false, 2)
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let point = normalized(recognizer) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onClick?(point, true, 1)
    }

    @objc private func twoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: imageView)
        recognizer.setTranslation(.zero, in: imageView)
        // Points de l'image affichée → pixels de l'image reçue, proches des points du Mac.
        let factor = imageView.bounds.width > 0 ? imageSize.width / imageView.bounds.width : 1
        onScroll?(Double(translation.x * factor), Double(translation.y * factor))
    }

    /// Le défilement à deux doigts cohabite avec le pincement du zoom.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

struct RemoteScreen: UIViewRepresentable {
    let link: MacLink

    func makeUIView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView(frame: .zero)
        view.onClick = { point, right, count in
            link.click(at: point, right: right, count: count)
        }
        view.onScroll = { dx, dy in
            link.scroll(dx: dx, dy: dy)
        }
        link.onFrame = { [weak view] image in
            view?.show(image)
        }
        return view
    }

    func updateUIView(_ view: RemoteScreenView, context: Context) {}

    static func dismantleUIView(_ view: RemoteScreenView, coordinator: ()) {}
}

/// Vue invisible qui reçoit la frappe du clavier de l'iPhone, touche par touche.
final class KeyCatcherView: UIView, UIKeyInput {
    var onText: (@MainActor (String) -> Void)?
    var onDelete: (@MainActor () -> Void)?
    /// Le clavier a été retiré, par nous ou par le système.
    var onResign: (@MainActor () -> Void)?

    // UITextInputTraits : aucune correction, rien ne doit être réécrit avant envoi.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onResign?()
        }
        return resigned
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onDelete?()
    }
}

struct KeyCatcher: UIViewRepresentable {
    @Binding var active: Bool
    let onText: @MainActor (String) -> Void
    let onDelete: @MainActor () -> Void

    func makeUIView(context: Context) -> KeyCatcherView {
        KeyCatcherView(frame: .zero)
    }

    func updateUIView(_ view: KeyCatcherView, context: Context) {
        view.onText = onText
        view.onDelete = onDelete
        let active = $active
        view.onResign = { active.wrappedValue = false }
        let wanted = self.active
        DispatchQueue.main.async {
            if wanted, !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if !wanted, view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }
}
