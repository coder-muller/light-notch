import AppKit

final class TrackPeekView: NSView {
    static let height: CGFloat = 36

    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private var trackID: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        configure(titleLabel, font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
        configure(artistLabel, font: .systemFont(ofSize: 11, weight: .medium), color: NSColor(white: 1, alpha: 0.55))
        layoutLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLabels()
    }

    private func configure(_ label: NSTextField, font: NSFont, color: NSColor) {
        label.font = font
        label.textColor = color
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.isSelectable = false
        label.wantsLayer = true
        addSubview(label)
    }

    private func layoutLabels() {
        titleLabel.frame = NSRect(x: 0, y: 18, width: bounds.width, height: 17)
        artistLabel.frame = NSRect(x: 0, y: 2, width: bounds.width, height: 14)
    }

    func show(_ track: NowPlaying, animated: Bool, backwards: Bool) {
        let changed = track.trackID != trackID
        trackID = track.trackID
        if animated && changed {
            TrackTransition.roll(titleLabel, duration: 0.42, backwards: backwards)
            TrackTransition.roll(artistLabel, duration: 0.52, backwards: backwards)
        }
        titleLabel.stringValue = track.title
        artistLabel.stringValue = track.artist
    }
}
