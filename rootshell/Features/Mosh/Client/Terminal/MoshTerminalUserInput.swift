//
//  VTUserInputProcessor.swift
//  rootshell
//

import Foundation

final class VTUserInputProcessor {
    enum UserInputState {
        case ground
        case esc
        case ss3
    }

    private var state: UserInputState = .ground

    init() {}

    private init(state: UserInputState) {
        self.state = state
    }

    func input(_ byte: UInt8, applicationModeCursorKeys: Bool) -> Data {
        switch state {
        case .ground:
            if byte == 0x1B { // ESC
                state = .esc
            }
            return Data([byte])
        case .esc:
            if byte == UInt8(ascii: "O") {
                state = .ss3
                return Data()
            }
            state = .ground
            return Data([byte])
        case .ss3:
            state = .ground
            if !applicationModeCursorKeys && byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "D") {
                return Data([UInt8(ascii: "["), byte])
            } else {
                return Data([UInt8(ascii: "O"), byte])
            }
        }
    }

    func copy() -> VTUserInputProcessor {
        VTUserInputProcessor(state: state)
    }
}
