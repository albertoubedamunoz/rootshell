//
//  SessionActivityWidgetBundle.swift
//  SessionActivityWidget
//
//  Widget bundle entry point for the Live Activity widget extension.
//

import SwiftUI
import WidgetKit

@main
struct SessionActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionActivityWidget()
        #if !CHINA_BUILD
        VPNControlWidget()
        VPNControlCenterToggle()
        #endif
    }
}
