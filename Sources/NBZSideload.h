#import <Foundation/Foundation.h>

// Re-signed (sideloaded) builds lose Google's keychain access group and app
// group, so the account is forgotten on every launch. Redirects both to what
// the re-signed app actually owns. Does nothing on App Store builds.
void NBZInstallSideloadFixes(void);
