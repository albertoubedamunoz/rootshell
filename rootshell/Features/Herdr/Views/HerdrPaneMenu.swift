// Copyright (c) 2026 Kit Knox / Rootshell LLC
import UIKit

extension Ghostty.TerminalView {
    func buildHerdrPaneMenu(controller: HerdrController, paneID: String) -> UIMenu {
        func action(_ kind: HerdrManagementAction.Kind, image: String) -> UIAction {
            UIAction(title: kind.title, image: UIImage(systemName: image)) { [weak controller] _ in
                controller?.showWorkspaceOverview(action: .init(kind: kind, targetID: paneID))
            }
        }
        var items: [UIMenuElement] = [action(.renamePane, image: "pencil")]
        if controller.paneInfos[paneID]?.label != nil {
            items.append(UIAction(title: String(localized: "Clear Pane Name"), image: UIImage(systemName: "clear")) { [weak controller] _ in
                guard let controller else { return }
                controller.runManagement { try await controller.renamePane(paneID, label: nil) }
            })
        }
        items.append(action(.movePane, image: "arrow.turn.up.right"))
        if let tabID = controller.paneInfos[paneID]?.tab_id,
           controller.paneInfos.values.filter({ $0.tab_id == tabID }).count > 1 {
            items.append(action(.swapPane, image: "rectangle.2.swap"))
        }
        if let tabID = controller.paneInfos[paneID]?.tab_id, let tab = controller.tabs[tabID] {
            if controller.canChoosePaneToZoom(tabID: tabID) {
                items.append(UIAction(title: String(localized: "Choose Pane to Zoom"),
                                      image: UIImage(systemName: "number.square")) { [weak self] _ in
                    self?.enclosingSplitHost?.showPaneZoomPicker()
                })
            }
            if controller.tabIsControlledElsewhere(tab) {
                items.append(UIAction(title: String(localized: "Take Control"), image: UIImage(systemName: "person.2")) { [weak controller] _ in
                    controller?.requestTakeControl(tabId: tabID)
                })
            } else if controller.capabilities.supportsSharedViewing, controller.ownership(of: tabID) != .mine {
                items.append(UIAction(title: String(localized: "Fit to This Window"),
                                      image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak controller] _ in
                    controller?.requestFitToWindow(tab)
                })
            }
        }
        return UIMenu(title: "herdr", children: items)
    }
}
