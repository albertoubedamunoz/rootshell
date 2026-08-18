//
//  ArrowKeyRepeatManager.swift
//  rootshell
//
//  Timer-based key repeat helper for list navigation arrows.
//

import Foundation

final class ArrowKeyRepeatManager {
    private static let initialDelay: TimeInterval = 0.275
    private static let repeatInterval: TimeInterval = 0.045

    enum Direction {
        case up
        case down
    }

    private var delayTimer: Timer?
    private var repeatTimer: Timer?
    private(set) var activeDirection: Direction?

    func start(direction: Direction, action: @escaping () -> Void) {
        if activeDirection == direction, delayTimer != nil || repeatTimer != nil {
            return
        }

        stop()
        activeDirection = direction

        let delayTimer = Timer(timeInterval: Self.initialDelay, repeats: false) { [weak self] _ in
            guard let self else { return }

            let repeatTimer = Timer(timeInterval: Self.repeatInterval, repeats: true) { _ in
                action()
            }
            self.repeatTimer = repeatTimer
            RunLoop.main.add(repeatTimer, forMode: .common)
        }

        self.delayTimer = delayTimer
        RunLoop.main.add(delayTimer, forMode: .common)
    }

    func stop(direction: Direction? = nil) {
        if let direction, direction != activeDirection {
            return
        }

        delayTimer?.invalidate()
        delayTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        activeDirection = nil
    }

    deinit {
        delayTimer?.invalidate()
        repeatTimer?.invalidate()
    }
}
