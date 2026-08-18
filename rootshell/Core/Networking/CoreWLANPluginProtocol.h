#ifndef CoreWLANPluginProtocol_h
#define CoreWLANPluginProtocol_h

#import <Foundation/Foundation.h>

/// Protocol shared between the Mac Catalyst app and the native macOS CoreWLAN plugin.
/// Both sides import this header in their bridging headers.
@protocol CoreWLANPluginProtocol <NSObject>
/// Returns current WiFi info with keys "ssid" and "bssid", or nil if unavailable.
- (nullable NSDictionary<NSString *, NSString *> *)currentWiFiInfo;
@end

#endif
