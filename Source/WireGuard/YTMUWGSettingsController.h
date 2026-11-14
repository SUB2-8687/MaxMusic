#import <UIKit/UIKit.h>

// Settings, profile import and diagnostics for the app-local WireGuard tunnel.
// Opened from YTMusicUltimate settings when the tweak is built with WIREGUARD=1.
@interface YTMUWGSettingsController : UITableViewController <UIDocumentPickerDelegate, NSURLSessionDelegate>
@end
