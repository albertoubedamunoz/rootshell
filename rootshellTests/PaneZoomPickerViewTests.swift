#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest

@MainActor
final class PaneZoomPickerViewTests: XCTestCase {
    private final class HardwareKey: UIKey {
        let usage: UIKeyboardHIDUsage
        let text: String
        let modifiers: UIKeyModifierFlags
        init(_ usage: UIKeyboardHIDUsage, text: String, modifiers: UIKeyModifierFlags = []) {
            self.usage = usage
            self.text = text
            self.modifiers = modifiers
            super.init()
        }
        required init?(coder: NSCoder) { fatalError("Not used by tests") }
        override var keyCode: UIKeyboardHIDUsage { usage }
        override var characters: String { text }
        override var charactersIgnoringModifiers: String { text }
        override var modifierFlags: UIKeyModifierFlags { modifiers }
    }

    private final class HardwarePress: UIPress {
        let hardwareKey: UIKey
        init(_ key: UIKey) {
            hardwareKey = key
            super.init()
        }
        override var key: UIKey? { hardwareKey }
    }

    private func picker(action: PaneZoomPickerView.Action = .zoom) throws -> (PaneZoomPickerView, UUID) {
        let selected = UUID()
        let ids = action == .swap ? [UUID(), selected] : [selected, UUID()]
        let model = try XCTUnwrap(PaneZoomSelection(paneIDs: ids, excludingPaneID: action == .swap ? ids[0] : nil))
        return (PaneZoomPickerView(selection: model, titles: model.labels, preview: false,
                                  shortcuts: [KeyTrigger(key: .w, modifiers: .command)],
                                  action: action, sourceTitle: action == .swap ? "Source" : nil), selected)
    }

    func testMountedPickerCanAcquireKeyboardAndFinishSelection() async throws {
        for action in [PaneZoomPickerView.Action.zoom, .swap] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let previous = UITextField(frame: window.bounds)
            window.rootViewController?.view.addSubview(previous)
            XCTAssertTrue(previous.becomeFirstResponder(), "The test window must support keyboard focus")
            let (picker, selected) = try picker(action: action)
            window.rootViewController?.view.addSubview(picker)
            picker.frame = window.bounds
            let left = CGRect(x: 0, y: 0, width: 400, height: 600)
            let right = CGRect(x: 400, y: 0, width: 400, height: 600)
            picker.arrange(in: action == .swap ? [right] : [left, right],
                           sourceFrame: action == .swap ? left : nil)
            XCTAssertTrue(picker.becomeFirstResponder(), "A menu must be able to hand the keyboard to the picker")
            XCTAssertTrue(picker.isFirstResponder)
            let finished = expectation(description: "Selected the first pane")
            picker.onFinish = { paneID in
                XCTAssertEqual(paneID, selected)
                finished.fulfill()
            }
            picker.insertText("1")
            await fulfillment(of: [finished], timeout: 1)
            picker.removeFromSuperview()
        }
    }

    func testShortcutCancelsWithoutDispatchingItsAppAction() async throws {
        for action in [PaneZoomPickerView.Action.zoom, .swap] {
            let (picker, _) = try picker(action: action)
            let command = try XCTUnwrap(picker.keyCommands?.first { $0.input == "w" && $0.modifierFlags == .command })
            let action = try XCTUnwrap(command.action)
            let finished = expectation(description: "Cancelled by Command-W")
            picker.onFinish = { paneID in
                XCTAssertNil(paneID)
                finished.fulfill()
            }
            XCTAssertTrue(picker.canPerformAction(action, withSender: command))
            picker.perform(action, with: command)
            await fulfillment(of: [finished], timeout: 1)
        }
    }

    func testOpeningModifiersAndUnownedCancellationDoNotDismissPicker() async throws {
        for action in [PaneZoomPickerView.Action.zoom, .swap] {
            let (picker, selected) = try picker(action: action)
            let finished = expectation(description: "A digit still selects after opening-chord handoff")
            picker.onFinish = { paneID in
                XCTAssertEqual(paneID, selected)
                finished.fulfill()
            }
            let command = HardwarePress(HardwareKey(.keyboardLeftGUI, text: "", modifiers: .command))
            let option = HardwarePress(HardwareKey(.keyboardLeftAlt, text: "", modifiers: [.command, .alternate]))
            picker.pressesBegan([command, option], with: nil)
            let opener = HardwarePress(HardwareKey(action == .swap ? .keyboardS : .keyboardP,
                                                   text: action == .swap ? "s" : "p",
                                                   modifiers: [.command, .alternate]))
            picker.pressesCancelled([opener], with: nil)
            picker.pressesEnded([command, option], with: nil)
            picker.insertText("1")
            await fulfillment(of: [finished], timeout: 1)
        }
    }

    func testCancelKeyIsHeldUntilReleaseInBothModes() async throws {
        for action in [PaneZoomPickerView.Action.zoom, .swap] {
            for key in [HardwareKey(.keyboardEscape, text: "\u{1b}"), HardwareKey(.keyboardX, text: "x")] {
                let (picker, _) = try picker(action: action)
                let finished = expectation(description: "Cancelled after key release")
                var cancellations = 0
                picker.onFinish = { paneID in
                    XCTAssertNil(paneID)
                    cancellations += 1
                    finished.fulfill()
                }
                let press = HardwarePress(key)
                picker.pressesBegan([press], with: nil)
                picker.pressesBegan([press], with: nil)
                await Task.yield()
                XCTAssertEqual(cancellations, 0)
                picker.pressesEnded([press], with: nil)
                await fulfillment(of: [finished], timeout: 1)
                XCTAssertEqual(cancellations, 1)
            }
        }
    }

    func testResigningCancelsExactlyOnce() throws {
        for action in [PaneZoomPickerView.Action.zoom, .swap] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let (picker, _) = try picker(action: action)
            window.rootViewController?.view.addSubview(picker)
            XCTAssertTrue(picker.becomeFirstResponder())
            var cancellations = 0
            picker.onFinish = { paneID in
                XCTAssertNil(paneID)
                cancellations += 1
            }
            XCTAssertTrue(picker.resignFirstResponder())
            picker.removeFromSuperview()
            XCTAssertEqual(cancellations, 1)
        }
    }
}
#endif
