#import <Foundation/Foundation.h>

// App-local WireGuard for YouTube Music.
//
// No system VPN, Network Extension, TUN interface or route change is used.
// wireguard-go + gVisor netstack run inside this process; an authenticated
// SOCKS5 server on 127.0.0.1 is applied to every NSURLSession configuration via
// nw_proxy_config (iOS 17+) with failover to direct connections disabled.

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YTMUWGState) {
    YTMUWGStateOff = 0,          // disabled in settings for this launch
    YTMUWGStateUnsupported,      // iOS < 17 or proxy API missing
    YTMUWGStateWaitingProfile,   // enabled; profile not readable yet (Keychain locked)
    YTMUWGStateStarting,
    YTMUWGStateRunning,
    YTMUWGStateFailed,           // engine failed; traffic is blocked, not sent direct
    YTMUWGStateExternalProxy,    // HTTP / HTTPS / SOCKS5 proxy server applied
    YTMUWGStateBlocked,          // enabled but the configuration is unusable: traffic blocked
};

// Connection kinds. WireGuard runs in-app; the others use an external proxy server.
FOUNDATION_EXPORT NSString *const YTMUWGKindWireGuard; // "wireguard"
FOUNDATION_EXPORT NSString *const YTMUWGKindHTTP;      // "http"   HTTP CONNECT
FOUNDATION_EXPORT NSString *const YTMUWGKindHTTPS;     // "https"  HTTP CONNECT over TLS to the proxy
FOUNDATION_EXPORT NSString *const YTMUWGKindSOCKS5;    // "socks5"

FOUNDATION_EXPORT NSString *const YTMUWGVersion;

// Settings (take effect on next launch).
BOOL YTMUWGSettingEnabled(void);
void YTMUWGSetSettingEnabled(BOOL enabled);
NSString *YTMUWGSettingKind(void);
NSDictionary *YTMUWGSettingExternalProxy(void); // host, port, username (no password)
BOOL YTMUWGHasStoredProxyPassword(void);
// Validates and saves the connection kind (and server fields for external
// kinds). password == nil keeps the stored password.
BOOL YTMUWGSaveConnection(NSString *kind, NSString *_Nullable host, NSString *_Nullable port,
                          NSString *_Nullable username, NSString *_Nullable password, NSString *_Nullable *_Nullable reason);
NSString *YTMUWGActiveKind(void); // kind applied in this launch, or @"" when inactive
BOOL YTMUWGSettingForceNativeStack(void);
void YTMUWGSetSettingForceNativeStack(BOOL enabled);

BOOL YTMUWGIsSupportedOS(void);
YTMUWGState YTMUWGCurrentState(void);
BOOL YTMUWGActiveThisLaunch(void);
NSString *YTMUWGStateDescription(YTMUWGState state);

// Profile (Keychain, this device only). Summaries never contain keys.
BOOL YTMUWGHasProfile(void);
NSDictionary *_Nullable YTMUWGInspectProfile(NSString *text, NSString *_Nullable *_Nullable reason);
BOOL YTMUWGImportProfile(NSString *text, NSString *_Nullable *_Nullable reason);
BOOL YTMUWGDeleteProfile(NSString *_Nullable *_Nullable reason);
NSDictionary *_Nullable YTMUWGStoredProfileSummary(void);

// Engine.
NSDictionary *YTMUWGEngineStatus(void);
void YTMUWGLookupInTunnel(NSString *host, void (^completion)(NSDictionary *result));
void YTMUWGRequestRebind(NSString *reason);

// A session that goes through the tunnel (used by diagnostics). Returns nil
// when the tunnel is not active in this launch.
NSURLSession *_Nullable YTMUWGTunnelSession(id<NSURLSessionDelegate> _Nullable delegate);

// Counters of proxy application, for diagnostics.
NSDictionary *YTMUWGProxyCounters(void);

// Text helpers. Diagnostics are always passed through YTMUWGRedact.
NSString *YTMUWGRedactText(NSString *text);
NSString *YTMUWGDiagnosticsReport(NSDictionary<NSString *, NSString *> *_Nullable checks);

// Implemented in YTMUWGTransport.m.
void YTMUWGInstallTransportPatches(void);
NSArray<NSString *> *YTMUWGTransportReportLines(void);
NSArray<NSString *> *YTMUWGScanTransportClasses(void);

// Implemented in YTMUWGCore.m; used by YTMUWGTransport.m.
NSString *YTMUWGAppVersion(void);
NSString *YTMUWGHostCategory(NSString *_Nullable host);

NS_ASSUME_NONNULL_END
