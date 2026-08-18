//
//  VTSequenceDispatcher.swift
//  rootshell
//

import Foundation

enum VTFunctionType {
    case escape
    case csi
    case control
}

struct VTFunction {
    let function: (VTFramebuffer, VTSequenceDispatcher) -> Void
    let clearsWrapState: Bool
}

final class VTFunctionRegistry {
    static let shared = VTFunctionRegistry()

    private(set) var escape: [String: VTFunction] = [:]
    private(set) var csi: [String: VTFunction] = [:]
    private(set) var control: [String: VTFunction] = [:]

    func register(_ type: VTFunctionType, dispatchChars: String, function: @escaping (VTFramebuffer, VTSequenceDispatcher) -> Void, clearsWrapState: Bool = true) {
        let entry = VTFunction(function: function, clearsWrapState: clearsWrapState)
        switch type {
        case .escape:
            escape[dispatchChars] = entry
        case .csi:
            csi[dispatchChars] = entry
        case .control:
            control[dispatchChars] = entry
        }
    }
}

final class VTSequenceDispatcher: Equatable {
    private var params: String = ""
    private var parsedParams: [Int] = []
    private var parsed: Bool = false

    private var dispatchChars: String = ""
    private var oscString: [UInt32] = []

    private static let paramMax = 65535
    private static let maximumClipboardSize = 16 * 1024

    var hostResponseBuffer = Data()

    init() {}

    func copy() -> VTSequenceDispatcher {
        let copy = VTSequenceDispatcher()
        copy.params = params
        copy.parsedParams = parsedParams
        copy.parsed = parsed
        copy.dispatchChars = dispatchChars
        copy.oscString = oscString
        copy.hostResponseBuffer = hostResponseBuffer
        return copy
    }

    func getParam(_ n: Int, default defaultVal: Int) -> Int {
        if !parsed { parseParams() }
        var ret = defaultVal
        if parsedParams.count > n {
            ret = parsedParams[n]
        }
        if ret < 1 { ret = defaultVal }
        return ret
    }

    func paramCount() -> Int {
        if !parsed { parseParams() }
        return parsedParams.count
    }

    func newParamChar(_ event: VTParserEvent) {
        guard event.hasCodepoint else { return }
        let ch = event.codepoint
        guard ch == 0x3B || (0x30...0x39).contains(ch) else { return }
        if params.count < 100 {
            params.append(Character(UnicodeScalar(ch)!))
        }
        parsed = false
    }

    func collect(_ event: VTParserEvent) {
        guard event.hasCodepoint else { return }
        if dispatchChars.count < 8, event.codepoint <= 255 {
            dispatchChars.append(Character(UnicodeScalar(event.codepoint)!))
        }
    }

    func clear() {
        params.removeAll(keepingCapacity: true)
        dispatchChars.removeAll(keepingCapacity: true)
        parsed = false
    }

    func str() -> String {
        return "[dispatch=\"\(dispatchChars)\" params=\"\(params)\"]"
    }

    func dispatch(_ type: VTFunctionType, _ event: VTParserEvent, framebuffer: VTFramebuffer) {
        if type == .escape || type == .csi {
            guard event.hasCodepoint else { return }
            let ch = event.codepoint
            if let scalar = UnicodeScalar(ch) {
                dispatchChars.append(Character(scalar))
            }
        }

        let map: [String: VTFunction]
        switch type {
        case .escape:
            map = VTFunctionRegistry.shared.escape
        case .csi:
            map = VTFunctionRegistry.shared.csi
        case .control:
            map = VTFunctionRegistry.shared.control
        }

        var key = dispatchChars
        if type == .control {
            let byte = UInt32(event.codepoint & 0xFF)
            if let scalar = UnicodeScalar(byte) {
                key = String(scalar)
            } else {
                key = ""
            }
        }

        guard let entry = map[key] else {
            framebuffer.cursorState.nextPrintWillWrap = false
            return
        }
        if entry.clearsWrapState {
            framebuffer.cursorState.nextPrintWillWrap = false
        }
        entry.function(framebuffer, self)
    }

    func getDispatchChars() -> String { dispatchChars }
    func getOSCString() -> [UInt32] { oscString }

    func oscPut(_ event: VTParserEvent) {
        guard event.hasCodepoint else { return }
        if oscString.count < VTSequenceDispatcher.maximumClipboardSize {
            oscString.append(event.codepoint)
        }
    }

    func oscStart() {
        oscString.removeAll(keepingCapacity: true)
    }

    func oscDispatch(framebuffer: VTFramebuffer) {
        if oscString.count >= 5,
           oscString[0] == 0x35,
           oscString[1] == 0x32,
           oscString[2] == 0x3B,
           oscString[3] == 0x63,
           oscString[4] == 0x3B {
            let slice = oscString[5..<oscString.count]
            let clipboard = slice.compactMap { UnicodeScalar($0) }
            framebuffer.setClipboard(clipboard)
            return
        }

        if oscString.isEmpty { return }

        var cmdNum: Int = -1
        var offset = 0
        if oscString[0] == 0x3B {
            cmdNum = 0
            offset = 1
        } else if oscString.count >= 2, oscString[1] == 0x3B {
            cmdNum = Int(oscString[0] - 0x30)
            offset = 2
        }

        let setIcon = cmdNum == 0 || cmdNum == 1
        let setTitle = cmdNum == 0 || cmdNum == 2
        if setIcon || setTitle {
            framebuffer.setTitleInitialized()
            let limit = min(oscString.count, 256)
            let scalars = oscString[offset..<limit].compactMap { UnicodeScalar($0) }
            if setIcon { framebuffer.setIconName(scalars) }
            if setTitle { framebuffer.setWindowTitle(scalars) }
        }
    }

    private func parseParams() {
        if parsed { return }
        parsedParams.removeAll(keepingCapacity: true)
        let segments = params.split(separator: ";", omittingEmptySubsequences: false)
        for segment in segments {
            if segment.isEmpty {
                parsedParams.append(-1)
                continue
            }
            if let val = Int(segment), val <= VTSequenceDispatcher.paramMax {
                parsedParams.append(val)
            } else {
                parsedParams.append(-1)
            }
        }
        parsed = true
    }

    static func == (lhs: VTSequenceDispatcher, rhs: VTSequenceDispatcher) -> Bool {
        lhs.params == rhs.params
            && lhs.parsedParams == rhs.parsedParams
            && lhs.parsed == rhs.parsed
            && lhs.dispatchChars == rhs.dispatchChars
            && lhs.oscString == rhs.oscString
            && lhs.hostResponseBuffer == rhs.hostResponseBuffer
    }
}
