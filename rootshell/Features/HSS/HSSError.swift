//
//  HSSError.swift
//  rootshell
//
//  Error types for HSS (Host Shorthand System) parsing and resolution
//

import Foundation

/// Errors that can occur during HSS parsing and evaluation
enum HSSError: LocalizedError {
    // Configuration errors
    case configFileNotFound(path: String)
    case configParseError(underlying: Error)
    case yamlParseError(detail: String)
    case invalidConfigStructure(reason: String)

    // Pattern matching errors
    case invalidRegex(pattern: String, reason: String)
    case noPatternMatched(input: String)

    // Template evaluation errors
    case invalidExpression(expression: String, reason: String)
    case captureGroupNotFound(index: Int)
    case namedCaptureNotFound(name: String)
    case expansionNotFound(key: String)
    case shortcutNotFound(key: String)
    case externalFileNotFound(path: String)
    case externalKeyNotFound(path: String, key: String)
    case externalFileOutsideDocuments(path: String)
    case recursionLimitExceeded(depth: Int)

    // File access errors
    case bookmarkCreationFailed
    case bookmarkResolutionFailed
    case fileAccessDenied
    case staleBookmark

    var errorDescription: String? {
        switch self {
        case .configFileNotFound(let path):
            return "HSS config file not found: \(path)"
        case .configParseError(let underlying):
            return "Failed to parse HSS config: \(underlying.localizedDescription)"
        case .yamlParseError(let detail):
            return "YAML parse error: \(detail)"
        case .invalidConfigStructure(let reason):
            return "Invalid HSS config structure: \(reason)"
        case .invalidRegex(let pattern, let reason):
            return "Invalid regex '\(pattern)': \(reason)"
        case .noPatternMatched(let input):
            return "No HSS pattern matches '\(input)'"
        case .invalidExpression(let expr, let reason):
            return "Invalid expression '\(expr)': \(reason)"
        case .captureGroupNotFound(let index):
            return "Capture group $\(index) not found in match"
        case .namedCaptureNotFound(let name):
            return "Named capture group '\(name)' not found"
        case .expansionNotFound(let key):
            return "Expansion '\(key)' not found in config"
        case .shortcutNotFound(let key):
            return "Shortcut '\(key)' not found in config"
        case .externalFileNotFound(let path):
            return "External HSS file not found: \(path)"
        case .externalKeyNotFound(let path, let key):
            return "Key '\(key)' not found in external file: \(path)"
        case .externalFileOutsideDocuments(let path):
            return "External file '\(path)' must be in app Documents folder"
        case .recursionLimitExceeded(let depth):
            return "Template recursion limit exceeded (depth: \(depth))"
        case .bookmarkCreationFailed:
            return "Failed to create file bookmark"
        case .bookmarkResolutionFailed:
            return "Failed to resolve file bookmark"
        case .fileAccessDenied:
            return "Unable to access the selected file"
        case .staleBookmark:
            return "File bookmark is stale - please re-select the file"
        }
    }
}
