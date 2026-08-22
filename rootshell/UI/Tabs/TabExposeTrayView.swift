//
//  TabExposeTrayView.swift
//  rootshell
//
//  One scope's page of the tab exposé: the scope header plus a grid of live
//  tab previews, scrolling vertically when the grid doesn't fit. The exposé
//  view holds one for the active scope and, while a group swipe or ⌘⌥[ ] is
//  in flight, a second for the neighbor scope sliding in beside it.
//

import UIKit

@MainActor
final class TabExposeTrayView: UIScrollView {
    private(set) var tabIDs: [UUID] = []
    private(set) var cells: [TabExposeCellView] = []
    private(set) var layoutResult = TabExposeLayout.Result.empty

    private let header = UIView()
    private let headerIcon = UIImageView()
    private let headerLabel = UILabel()
    private var appearance = TabExposeView.Appearance()

    init() {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false
        // UIKit 26 applies an automatic glass "scroll edge effect" to scroll
        // views it considers under a bar; on Catalyst the window titlebar
        // qualifies and the effect blurs/tints the whole tray. The tray is a
        // live preview grid, never bar-adjacent content: opt out entirely.
        if #available(iOS 26.0, macCatalyst 26.0, visionOS 26.0, *) {
            topEdgeEffect.isHidden = true
            bottomEdgeEffect.isHidden = true
            leftEdgeEffect.isHidden = true
            rightEdgeEffect.isHidden = true
        }

        headerIcon.contentMode = .scaleAspectFit
        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headerLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(headerIcon)
        header.addSubview(headerLabel)
        header.isUserInteractionEnabled = false
        addSubview(header)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Cells

    /// Rebuild for `tabIDs`, reusing cells by tab id; stale cells are removed.
    /// Returns the cells created by this rebuild.
    @discardableResult
    func rebuildCells(
        tabIDs ids: [UUID],
        scopeTitle: String?,
        scoped: Bool,
        tabsModel: TabsModel,
        selectedID: UUID?,
        highlightedID: UUID?,
        appearance: TabExposeView.Appearance
    ) -> [TabExposeCellView] {
        self.appearance = appearance
        var byID = Dictionary(uniqueKeysWithValues: cells.map { ($0.tabID, $0) })
        var ordered: [TabExposeCellView] = []
        var entering: [TabExposeCellView] = []
        for (index, id) in ids.enumerated() {
            guard let tab = tabsModel.tab(withID: id) else { continue }
            let cell: TabExposeCellView
            if let existing = byID.removeValue(forKey: id) {
                cell = existing
            } else {
                cell = TabExposeCellView(tabID: id)
                addSubview(cell)
                entering.append(cell)
            }
            cell.mirror.tab = tab
            cell.isCurrent = id == selectedID
            cell.isHighlighted = id == highlightedID
            // Captions only re-host when the cell's position changes (hover
            // highlight churn must not rebuild SwiftUI per cell).
            if cell.captionIndex != index {
                cell.captionIndex = index
                cell.setCaption(appearance.showsCaptions ? appearance.captionProvider?(tab, index) : nil)
            }
            ordered.append(cell)
        }
        for (_, stale) in byID { stale.removeFromSuperview() }
        cells = ordered
        tabIDs = ids

        header.isHidden = !scoped
        if scoped {
            headerLabel.text = [scopeTitle, "\(ids.count)"]
                .compactMap { $0 }
                .joined(separator: " · ")
            let symbol = tabsModel.isProjectGroupingActive ? "folder" : "square.grid.2x2"
            headerIcon.image = UIImage(systemName: symbol)
        }
        applyAppearance(appearance)
        return entering
    }

    func removeAllCells() {
        for cell in cells { cell.removeFromSuperview() }
        cells.removeAll()
        tabIDs.removeAll()
    }

    func applyAppearance(_ appearance: TabExposeView.Appearance) {
        self.appearance = appearance
        headerLabel.textColor = appearance.textColor.withAlphaComponent(0.85)
        headerIcon.tintColor = appearance.textColor.withAlphaComponent(0.7)
        for cell in cells {
            cell.previewBackgroundColor = appearance.backgroundColor
            cell.accentColor = appearance.accentColor
            cell.currentRingColor = appearance.textColor.withAlphaComponent(0.3)
        }
    }

    // MARK: - Layout

    /// Lay the header and grid out for a tray of `size` (the hero area).
    func layoutGrid(size: CGSize, aspect: CGFloat, metrics: TabExposeLayout.Metrics, cornerRadius: CGFloat) {
        layoutResult = TabExposeLayout.grid(
            in: CGRect(origin: .zero, size: size),
            count: cells.count,
            aspect: aspect,
            metrics: metrics
        )
        contentSize = CGSize(width: size.width, height: max(layoutResult.contentHeight, size.height))
        isScrollEnabled = !layoutResult.fits

        header.frame = layoutResult.headerFrame
        let iconSide = max(0, min(16, header.bounds.height))
        headerIcon.frame = CGRect(x: 0, y: (header.bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
        headerLabel.frame = CGRect(x: iconSide + 6, y: 0, width: header.bounds.width - iconSide - 6, height: header.bounds.height)

        for (index, cell) in cells.enumerated() where index < layoutResult.frames.count {
            // bounds/center, not frame: highlighted cells carry a scale transform.
            let frame = layoutResult.frames[index]
            cell.bounds = CGRect(origin: .zero, size: frame.size)
            cell.center = CGPoint(x: frame.midX, y: frame.midY)
            cell.layoutContent(previewSize: layoutResult.cellSize, cornerRadius: cornerRadius)
        }
    }

    func setChrome(captionAlpha: CGFloat, ringAlpha: CGFloat) {
        header.alpha = captionAlpha
        for cell in cells {
            cell.captionAlpha = captionAlpha
            cell.ringAlpha = ringAlpha
        }
    }

    // MARK: - Per frame

    /// Refresh the mirrors of on-screen cells only.
    func syncVisibleMirrors() {
        let visible = bounds
        for cell in cells where cell.frame.intersects(visible) {
            cell.mirror.sync()
        }
    }

    // MARK: - Hit testing / scrolling

    func cell(at pointInTray: CGPoint) -> TabExposeCellView? {
        cells.first { $0.frame.contains(pointInTray) }
    }

    func scrollCellIntoView(id: UUID?, animated: Bool) {
        guard isScrollEnabled, let id,
              let cell = cells.first(where: { $0.tabID == id }) else { return }
        scrollRectToVisible(cell.frame.insetBy(dx: 0, dy: -12), animated: animated)
    }
}
