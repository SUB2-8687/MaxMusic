// C ABI of the Go engine in WireGuard/bridge.go (built into libytmuwg.a).
// Every returned string is malloc'ed by Go and must be freed with YTMUWGFree.
#ifndef YTMUWG_BRIDGE_H
#define YTMUWG_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

char *YTMUWGInspect(char *text);
int YTMUWGStart(char *text, char *user, char *pass, int listenerFD, int port);
char *YTMUWGStatus(void);
int YTMUWGRebind(void);
char *YTMUWGLookup(char *host);
char *YTMUWGRedact(char *text);
void YTMUWGFree(char *p);

#ifdef __cplusplus
}
#endif

#endif
