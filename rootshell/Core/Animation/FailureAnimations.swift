import Foundation

// MARK: - Failure Category

/// Categories of errors for animation and quip selection
enum FailureCategory: Hashable, Sendable {
    case connectionTimeout
    case hostUnreachable
    case authenticationFailed
    case hostKeyRejected
    case channelFailed
    case handshakeFailed
    case networkError
    case general
}

// MARK: - Animation Data Structures

/// A single frame of an ASCII art animation
struct AnimationFrame: Sendable {
    let lines: [String]

    /// Maximum line width in this frame
    var maxWidth: Int {
        lines.map { $0.count }.max() ?? 0
    }
}

/// A complete failure animation sequence
struct FailureAnimation: Sendable {
    let id: String
    let frames: [AnimationFrame]
    let frameDelay: TimeInterval
    let finalHoldTime: TimeInterval
    let categories: Set<FailureCategory>

    /// Total animation duration (excluding final hold)
    var animationDuration: TimeInterval {
        Double(frames.count) * frameDelay
    }
}

// MARK: - Animation Registry

struct FailureAnimationRegistry {

    /// All available animations
    static let animations: [FailureAnimation] = [
        serverOnFire,
        fallingStickFigure,
        computerExploding,
        shipSinking,
        robotMalfunction,
        keyBreaking,
        doorSlammed,
        tumblingBits
    ]

    /// Get a random animation for any failure scenario
    static func animation(for category: FailureCategory) -> FailureAnimation {
        animations.randomElement()!
    }

    /// Map an Error to a FailureCategory
    static func categorize(_ error: Error) -> FailureCategory {
        // SSHError cases
        if let sshError = error as? SSHError {
            switch sshError {
            case .connectionTimeout:
                return .connectionTimeout
            case .authenticationFailed, .authenticationTimeout:
                return .authenticationFailed
            case .channelCreationFailed:
                return .channelFailed
            case .sshHandshakeFailed:
                return .handshakeFailed
            case .notConnected:
                return .networkError
            case .invalidConfiguration:
                return .general
            }
        }

        // SSHJumpError cases
        if let jumpError = error as? SSHJumpError {
            switch jumpError {
            case .jumpConnectionFailed:
                return .hostUnreachable
            case .targetConnectionFailed:
                return .networkError
            case .authenticationFailed:
                return .authenticationFailed
            case .hostKeyRejected:
                return .hostKeyRejected
            case .tunnelCreationFailed:
                return .channelFailed
            }
        }

        // Check error type name for NIO/network errors
        let errorTypeName = String(describing: type(of: error))
        if errorTypeName.contains("ChannelError") || errorTypeName.contains("NIO") {
            // NIO ChannelError typically indicates connection/network issues
            return .networkError
        }

        // Fallback: check error description for keywords
        let description = error.localizedDescription.lowercased()

        if description.contains("timeout") || description.contains("timed out") {
            return .connectionTimeout
        }
        if description.contains("connection refused") || description.contains("no route") {
            return .hostUnreachable
        }
        if description.contains("authentication") || description.contains("password") || description.contains("credential") {
            return .authenticationFailed
        }
        if description.contains("host key") {
            return .hostKeyRejected
        }
        if description.contains("channel") {
            return .channelFailed
        }
        if description.contains("handshake") {
            return .handshakeFailed
        }
        if description.contains("network") || description.contains("unreachable") {
            return .networkError
        }

        return .general
    }

    // MARK: - Animation Definitions

    /// Server with growing flames - for timeout/unreachable errors
    static let serverOnFire = FailureAnimation(
        id: "server_on_fire",
        frames: [
            AnimationFrame(lines: [
                "    _____    ",
                "   |     |   ",
                "   | === |   ",
                "   | === |   ",
                "   |_____|   ",
                "   ///////   "
            ]),
            AnimationFrame(lines: [
                "    _____    ",
                "   |     |   ",
                "   | === | ~ ",
                "   | === |   ",
                "   |_____|   ",
                "   ///////   "
            ]),
            AnimationFrame(lines: [
                "    _____  * ",
                "   |     | ~ ",
                "   | === |*~ ",
                "   | === | ~ ",
                "   |_____|   ",
                "   ///////   "
            ]),
            AnimationFrame(lines: [
                "   *_____*~* ",
                "  *|     |~* ",
                "  ~| === |*~ ",
                "  *| === |~  ",
                "   |_____|*  ",
                "   ///////   "
            ]),
            AnimationFrame(lines: [
                "  *~*~*~*~*  ",
                " *~|     |~* ",
                " ~*| === |*~ ",
                " *~| === |~* ",
                "  *|_____|*  ",
                "   ///////   ",
                "             ",
                "   IT BURNS  "
            ])
        ],
        frameDelay: 0.35,
        finalHoldTime: 0.6,
        categories: [.connectionTimeout, .hostUnreachable]
    )

    /// Person tumbling down - for auth failures
    static let fallingStickFigure = FailureAnimation(
        id: "falling_stick_figure",
        frames: [
            AnimationFrame(lines: [
                "      o      ",
                "     /|\\     ",
                "     / \\     ",
                "  _________  "
            ]),
            AnimationFrame(lines: [
                "             ",
                "     \\o      ",
                "      |\\     ",
                "     / >     ",
                "  _________  "
            ]),
            AnimationFrame(lines: [
                "             ",
                "             ",
                "     \\o/     ",
                "      |      ",
                "     / \\     ",
                "  _________  "
            ]),
            AnimationFrame(lines: [
                "             ",
                "             ",
                "      _o_    ",
                "       |     ",
                "      / \\    ",
                "  _________  "
            ]),
            AnimationFrame(lines: [
                "             ",
                "             ",
                "             ",
                "      .o.    ",
                "     /|\\|    ",
                "  ___===___  ",
                "    SPLAT    "
            ])
        ],
        frameDelay: 0.3,
        finalHoldTime: 0.7,
        categories: [.authenticationFailed]
    )

    /// Computer going boom - for channel/general errors
    static let computerExploding = FailureAnimation(
        id: "computer_exploding",
        frames: [
            AnimationFrame(lines: [
                "   _______   ",
                "  |       |  ",
                "  |  >_<  |  ",
                "  |_______|  ",
                "     | |     "
            ]),
            AnimationFrame(lines: [
                "   _______   ",
                "  |   *   |  ",
                "  |  >_<  |  ",
                "  |_______|  ",
                "     | |     "
            ]),
            AnimationFrame(lines: [
                "   _______   ",
                "  | * * * |  ",
                "  |   #   |  ",
                "  |*_____*|  ",
                "    *| |*    "
            ]),
            AnimationFrame(lines: [
                "    * * *    ",
                "   *     *   ",
                "  *  BOOM *  ",
                "   *     *   ",
                "    * * *    "
            ]),
            AnimationFrame(lines: [
                "  *       *  ",
                "      *      ",
                "   *     *   ",
                "             ",
                "      *      ",
                "  *       *  ",
                "   KABOOM!   "
            ])
        ],
        frameDelay: 0.3,
        finalHoldTime: 0.6,
        categories: [.channelFailed, .general]
    )

    /// Ship going underwater - for handshake failures
    static let shipSinking = FailureAnimation(
        id: "ship_sinking",
        frames: [
            AnimationFrame(lines: [
                "      |      ",
                "     _|_     ",
                "  ~~|___|~~  ",
                "  ~~~~~~~~~~  "
            ]),
            AnimationFrame(lines: [
                "      |      ",
                "     _|_     ",
                " ~~\\|___|/~~ ",
                "  ~~~~~~~~~~  "
            ]),
            AnimationFrame(lines: [
                "             ",
                "     _|_     ",
                "~\\~~|___|/~~~",
                "  ~~~~~~~~~~  ",
                "    glub     "
            ]),
            AnimationFrame(lines: [
                "             ",
                "             ",
                "~~\\~_|_~/~~~~",
                "  ~~~~~~~~~~  ",
                "  glub glub  "
            ]),
            AnimationFrame(lines: [
                "             ",
                "             ",
                "~~~~~~~~~~~~~",
                "  ~~~~~~~~~~  ",
                "   *blub*    ",
                "             ",
                " SHIP SUNK!  "
            ])
        ],
        frameDelay: 0.4,
        finalHoldTime: 0.6,
        categories: [.handshakeFailed]
    )

    /// Robot short-circuiting - for general errors
    static let robotMalfunction = FailureAnimation(
        id: "robot_malfunction",
        frames: [
            AnimationFrame(lines: [
                "   [o_o]   ",
                "   /||\\   ",
                "    ||     ",
                "   /  \\   "
            ]),
            AnimationFrame(lines: [
                "   [o_O]   ",
                "   /||\\   ",
                "    ||     ",
                "   /  \\   "
            ]),
            AnimationFrame(lines: [
                "   [O_o]   ",
                "   /||\\   ",
                "   ~||~    ",
                "   /  \\   "
            ]),
            AnimationFrame(lines: [
                "   [x_x]   ",
                "   /||\\ ~ ",
                "   ~||~    ",
                "   /  \\   "
            ]),
            AnimationFrame(lines: [
                "   [X_X] ~ ",
                "   /||\\ ~~",
                "    \\\\    ",
                "    \\\\    ",
                "           ",
                "  ERROR!   "
            ])
        ],
        frameDelay: 0.3,
        finalHoldTime: 0.6,
        categories: [.general, .networkError]
    )

    /// Key snapping in half - for key/auth issues
    static let keyBreaking = FailureAnimation(
        id: "key_breaking",
        frames: [
            AnimationFrame(lines: [
                "           ",
                "   o--D    ",
                "           "
            ]),
            AnimationFrame(lines: [
                "           ",
                "   o---D   ",
                "           "
            ]),
            AnimationFrame(lines: [
                "           ",
                "   o-/-D   ",
                "           "
            ]),
            AnimationFrame(lines: [
                "           ",
                "   o  /D   ",
                "       \\   "
            ]),
            AnimationFrame(lines: [
                "           ",
                "   o   D   ",
                "      / \\  ",
                "   *crack* "
            ]),
            AnimationFrame(lines: [
                "           ",
                "   o    D  ",
                "       / \\ ",
                "           ",
                " KEY BROKE!"
            ])
        ],
        frameDelay: 0.25,
        finalHoldTime: 0.7,
        categories: [.authenticationFailed, .hostKeyRejected]
    )

    /// Door slamming shut - for permission denied
    static let doorSlammed = FailureAnimation(
        id: "door_slammed",
        frames: [
            AnimationFrame(lines: [
                "  _______  ",
                " |   |   | ",
                " |   |   | ",
                " |   o   | ",
                " |_______| "
            ]),
            AnimationFrame(lines: [
                "  _______  ",
                " |  o|   | ",
                " |   |   | ",
                " |   |   | ",
                " |_______| ",
                "  *knock*  "
            ]),
            AnimationFrame(lines: [
                "  _______  ",
                " |   |   | ",
                " |   | o | ",
                " |   |   | ",
                " |___|___| ",
                "  *creak*  "
            ]),
            AnimationFrame(lines: [
                "  _______  ",
                " |       | ",
                " |   X   | ",
                " |       | ",
                " |_NOPE__| ",
                "   SLAM!   "
            ])
        ],
        frameDelay: 0.35,
        finalHoldTime: 0.7,
        categories: [.hostKeyRejected, .hostUnreachable]
    )

    /// 1s and 0s scattering - for network errors
    static let tumblingBits = FailureAnimation(
        id: "tumbling_bits",
        frames: [
            AnimationFrame(lines: [
                " 1 0 1 1 0 ",
                " 0 1 0 1 1 ",
                " 1 1 0 0 1 "
            ]),
            AnimationFrame(lines: [
                " 1   1 1 0 ",
                " 0 1   1 1 ",
                " 1 1 0 0 1 "
            ]),
            AnimationFrame(lines: [
                "     1 1   ",
                " 0 1   1 1 ",
                " 1 1 0 0   ",
                "       0 1 "
            ]),
            AnimationFrame(lines: [
                "       1   ",
                "   1     1 ",
                " 1 1 0     ",
                "     0   1 ",
                " 0       0 "
            ]),
            AnimationFrame(lines: [
                "           ",
                "     1     ",
                " 1       0 ",
                "   0       ",
                "         1 ",
                " scattered!"
            ])
        ],
        frameDelay: 0.3,
        finalHoldTime: 0.6,
        categories: [.networkError, .connectionTimeout]
    )
}
