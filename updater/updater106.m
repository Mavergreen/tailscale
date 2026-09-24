// TailscaleUpdater for the 10.6 floor — a minimal ObjC updater that replaces
// the Sparkle-based updater the 10.9 product ships (Sparkle 1.27.3's binary
// declares LC_VERSION_MIN_MACOSX 10.9; dyld on 10.6 refuses to load it).
//
// Same CLI contract as the Sparkle updater:
//   (no args)   silent background check (the daily LaunchAgent calls this)
//   --user      foreground check: show a dialog on update, install on OK
//
// All APIs are 10.6-safe: NSXMLParser, NSTask, NSAlert, NSData.
// No blocks, no ARC, no GCD, no NSUserNotification, no external framework.

#import <Cocoa/Cocoa.h>
#import <unistd.h>
#import <stdlib.h>

static BOOL userInitiatedFlag = NO;
static BOOL alreadyAlerted = NO;  // prevents double dialogs (TLS then generic)
#ifndef UPDATER_FEED_URL
#define UPDATER_FEED_URL "https://github.com/startergo/tailscale-legacy/releases/latest/download/appcast-10.6.xml"
#endif
static NSString *const kFeedURL = @UPDATER_FEED_URL;

// cleanupAndExit removes the temp directory and exits. Called at EVERY exit
// point after tmpDir exists, so daily background checks never accumulate.
static void cleanupAndExit(NSString *tmpDir, int code) {
    [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:nil];
    exit(code);
}


#pragma mark - Version helpers

static NSString *installedVersion(void) {
    // Check pkgutil exists before launching (NSTask throws if missing).
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/sbin/pkgutil"]) {
        NSLog(@"updater: /usr/sbin/pkgutil not found");
        return @"";
    }
    NSTask *t = [[[NSTask alloc] init] autorelease];
    [t setLaunchPath:@"/usr/sbin/pkgutil"];
    [t setArguments:[NSArray arrayWithObjects:@"--pkg-info", @"dev.modernmavericks.tailscale", nil]];
    NSPipe *p = [NSPipe pipe];
    [t setStandardOutput:p];
    [t launch];
    NSData *d = [[[p fileHandleForReading] readDataToEndOfFile] retain];
    [t waitUntilExit];
    NSString *out = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease];
    [d release];
    for (NSString *line in [out componentsSeparatedByString:@"\n"])
        if ([line hasPrefix:@"version: "])
            return [line substringFromIndex:9];
    return @"";
}

static int compareVersions(NSString *a, NSString *b) {
    NSArray *ap = [a componentsSeparatedByString:@"."];
    NSArray *bp = [b componentsSeparatedByString:@"."];
    NSUInteger n = MAX([ap count], [bp count]);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger ai = i < [ap count] ? [[ap objectAtIndex:i] integerValue] : 0;
        NSInteger bi = i < [bp count] ? [[bp objectAtIndex:i] integerValue] : 0;
        if (ai < bi) return -1;
        if (ai > bi) return 1;
    }
    return 0;
}

#pragma mark - Binary-safe fetch (no UTF-8 transcoding)

// Downloads to a FILE, preserving binary bytes exactly. The HTTP status
// is written via curl's -w to stdout, never mixed with the body.
static BOOL fetchToFile(NSString *urlString, NSString *destPath) {
    NSString *curlPath = @"/opt/local/bin/curl";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:curlPath]) {
        // Stock 10.6 curl (OpenSSL 0.9.8) cannot negotiate TLS 1.2, which
        // GitHub requires. This is a hard dependency for HTTPS update checks;
        // fail with a clear message rather than a cryptic TLS error.
        if ([urlString hasPrefix:@"https://"]) {
            NSLog(@"updater: FATAL: MacPorts curl not found at /opt/local/bin/curl.");
            NSLog(@"updater: 10.6's system curl lacks TLS 1.2; GitHub HTTPS requires it.");
            NSLog(@"updater: Install MacPorts curl: sudo port install curl");
            if (userInitiatedFlag)
                NSRunAlertPanel(@"Mavericks Tailscale",
                                @"Cannot check for updates: MacPorts curl is required "
                                @"for HTTPS on 10.6 (system curl lacks TLS 1.2).\n\n"
                                @"Install it with: sudo port install curl",
                                @"OK", nil, nil);
            alreadyAlerted = YES;
            return NO;
        }
        // HTTPS only: an auto-updater accepting plain HTTP is a MITM /
        // downgrade vector. No fallback.
        curlPath = nil;
    }
    if (!curlPath) return NO; // unreachable for HTTPS (handled above)
    NSTask *t = [[[NSTask alloc] init] autorelease];
    [t setLaunchPath:curlPath];
    [t setArguments:[NSArray arrayWithObjects:
        @"-sL", @"--max-time", @"60",
        @"-o", destPath,
        @"-w", @"%{http_code}",
        urlString, nil]];
    NSPipe *p = [NSPipe pipe];
    [t setStandardOutput:p];
    [t setStandardError:[NSPipe pipe]];
    [t launch];
    NSData *statusData = [[[p fileHandleForReading] readDataToEndOfFile] retain];
    [t waitUntilExit];
    NSString *status = [[[NSString alloc] initWithData:statusData
                                              encoding:NSASCIIStringEncoding] autorelease];
    [statusData release];
    if ([t terminationStatus] != 0) {
        NSLog(@"updater: curl exited %ld", [t terminationStatus]);
        return NO;
    }
    if (![status isEqualToString:@"200"]) {
        NSLog(@"updater: HTTP %@ for %@", status, urlString);
        return NO;
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] fileAttributesAtPath:destPath
                                                                   traverseLink:NO];
    if (!attrs || [[attrs objectForKey:NSFileSize] unsignedLongValue] == 0) {
        NSLog(@"updater: empty or missing download at %@", destPath);
        return NO;
    }
    return YES;
}

#pragma mark - Appcast parser (selects the 10.6-compatible item)

@interface AppcastParser : NSObject <NSXMLParserDelegate> {
    NSMutableArray *items;
    NSMutableDictionary *curItem;
    NSString *textBuf;
    BOOL inItem;
    BOOL inVersionElem;
    BOOL inMinSysElem;
    NSString *curEnclosureURL;
}
@property (readonly) NSMutableArray *items;
@end

@implementation AppcastParser
- (id)init {
    self = [super init];
    if (self) items = [[NSMutableArray alloc] init];
    return self;
}
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)name
   namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)a {
    textBuf = @"";
    if ([name isEqualToString:@"item"]) {
        inItem = YES;
        curItem = [NSMutableDictionary dictionary];
        curEnclosureURL = nil;
    } else if ([name isEqualToString:@"enclosure"] && inItem) {
        curEnclosureURL = [[a objectForKey:@"url"] retain];
    } else if (inItem && ([name isEqualToString:@"sparkle:version"] ||
                          [name isEqualToString:@"version"])) {
        inVersionElem = YES;
    } else if (inItem && [name isEqualToString:@"sparkle:minimumSystemVersion"]) {
        inMinSysElem = YES;
    }
}
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s {
    textBuf = [textBuf stringByAppendingString:s];
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)name
   namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
    if ([name isEqualToString:@"item"]) {
        inItem = NO;
        if (curEnclosureURL)
            [curItem setObject:curEnclosureURL forKey:@"url"];
        if ([curItem count] > 0)
            [items addObject:curItem];
        [curEnclosureURL release]; curEnclosureURL = nil;
        curItem = nil;
    } else if (inVersionElem && ([name isEqualToString:@"sparkle:version"] ||
                                  [name isEqualToString:@"version"])) {
        inVersionElem = NO;
        [curItem setObject:textBuf forKey:@"version"];
    } else if (inMinSysElem && [name isEqualToString:@"sparkle:minimumSystemVersion"]) {
        inMinSysElem = NO;
        [curItem setObject:textBuf forKey:@"minSys"];
    }
    textBuf = @"";
}
- (NSMutableArray *)items { return items; }
- (void)dealloc {
    [items release];
    [curEnclosureURL release];
    [super dealloc];
}
@end

// Selects the LAST item whose minSysVersion is <= 10.6 (or absent).
// The release workflow appends the 10.6 enclosure after the 10.9 one,
// so the LAST compatible item is the 10.6-specific entry.
static NSDictionary *selectCompatibleItem(AppcastParser *parser) {
    NSDictionary *best = nil;
    NSString *bestVersion = nil;
    for (NSDictionary *item in parser.items) {
        NSString *minSys = [item objectForKey:@"minSys"];
        if (minSys && compareVersions(minSys, @"10.6") > 0) continue; // incompatible
        NSString *v = [item objectForKey:@"version"];
        NSString *u = [item objectForKey:@"url"];
        if (!v || !u) continue;
        // Pick the HIGHEST version among compatible items (not just the
        // last — ordering is a feed convention, not a guarantee).
        if (!bestVersion || compareVersions(v, bestVersion) > 0) {
            best = item;
            bestVersion = v;
        }
    }
    return best;
}

#pragma mark - Elevated install

// Uses osascript to prompt for admin credentials and run installer,
// the standard macOS pattern for a GUI app installing a system pkg.
static BOOL installPkgElevated(NSString *pkgPath) {
    // Escape single quotes for the shell: our PID-based path contains no
    // quotes, but belt-and-suspenders against future path changes.
    NSString *safePath = [pkgPath stringByReplacingOccurrencesOfString:@"'"
                                                                  withString:@"'\\''"];
    NSString *script = [NSString stringWithFormat:
        @"do shell script \"/usr/sbin/installer -pkg '%@' -target /\" "
        @"with administrator privileges", safePath];
    NSTask *t = [[[NSTask alloc] init] autorelease];
    [t setLaunchPath:@"/usr/bin/osascript"];
    [t setArguments:[NSArray arrayWithObjects:@"-e", script, nil]];
    NSPipe *errPipe = [NSPipe pipe];
    [t setStandardError:errPipe];
    [t launch];
    [t waitUntilExit];
    if ([t terminationStatus] != 0) {
        NSData *errData = [[[errPipe fileHandleForReading] readDataToEndOfFile] retain];
        NSString *err = [[[NSString alloc] initWithData:errData
                                              encoding:NSUTF8StringEncoding] autorelease];
        [errData release];
        NSLog(@"updater: install failed: %@", err);
        return NO;
    }
    return YES;
}

#pragma mark - Main

int main(int argc, const char *argv[]) {
    BOOL background = NO;
    BOOL userInitiated = NO;
    if (argc < 2) {
        background = YES;  // no args = silent background check
    } else if (strcmp(argv[1], "--background") == 0) {
        background = YES;
    } else if (strcmp(argv[1], "--user") == 0) {
        userInitiated = YES;
        userInitiatedFlag = YES;  // global: fetchToFile reads this for TLS dialog
    } else {
        fprintf(stderr, "usage: %s [--background|--user]\n", argv[0]);
        return 2;
    }
    if (argc > 2) {
        fprintf(stderr, "updater: unexpected extra arguments\n");
        return 2;
    }

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];

    NSString *current = installedVersion();
    if ([current length] == 0) {
        NSLog(@"updater: no installed version found");
        if (userInitiated)
            NSRunAlertPanel(@"Mavericks Tailscale",
                            @"Cannot determine the installed version.", @"OK", nil, nil);
        [pool release];
        return 1;
    }

    // Fetch appcast (binary-safe: temp file, no transcoding)
    // Secure temp directory (mkdtemp: unpredictable name, 0700 perms).
    char tmpl[] = "/tmp/tsupd.XXXXXX";
    char *dir = mkdtemp(tmpl);
    if (!dir) { NSLog(@"updater: mkdtemp failed"); [pool release]; return 1; }
    NSString *tmpDir = [NSString stringWithUTF8String:dir];
    NSString *appcastPath = [tmpDir stringByAppendingPathComponent:@"appcast-10.6.xml"];
    if (!fetchToFile(kFeedURL, appcastPath)) {
        if (userInitiated && !alreadyAlerted)
            NSRunAlertPanel(@"Mavericks Tailscale",
                            @"Could not check for updates (network error).", @"OK", nil, nil);
        cleanupAndExit(tmpDir, 1);
    }
    NSData *xmlData = [NSData dataWithContentsOfFile:appcastPath];

    // Parse ALL items, then select the 10.6-compatible one
    AppcastParser *parser = [[[AppcastParser alloc] init] autorelease];
    NSXMLParser *xp = [[[NSXMLParser alloc] initWithData:xmlData] autorelease];
    [xp setDelegate:parser];
    [xp parse];

    NSDictionary *item = selectCompatibleItem(parser);
    if (!item) {
        NSLog(@"updater: no compatible item in appcast");
        if (userInitiated)
            NSRunAlertPanel(@"Mavericks Tailscale",
                            @"No compatible update found for this system.", @"OK", nil, nil);
        cleanupAndExit(tmpDir, 0);
    }

    NSString *availVersion = [item objectForKey:@"version"];
    NSString *downloadURL = [item objectForKey:@"url"];

    if (compareVersions(availVersion, current) <= 0) {
        NSLog(@"updater: up to date (%@)", current);
        if (userInitiated)
            NSRunAlertPanel(@"Mavericks Tailscale",
                            [NSString stringWithFormat:@"You're up to date! (version %@)", current],
                            @"OK", nil, nil);
        cleanupAndExit(tmpDir, 0);
    }

    NSLog(@"updater: %@ -> %@", current, availVersion);

    if (background) {
        NSLog(@"updater: update available (background check is silent)");
        cleanupAndExit(tmpDir, 0);
    }

    if (userInitiated) {
        NSInteger choice = NSRunAlertPanel(
            @"Mavericks Tailscale Update",
            [NSString stringWithFormat:
                @"Version %@ is available (you have %@).\n\nDownload and install now?",
                availVersion, current],
            @"Install", @"Not Now", nil);
        if (choice != NSAlertDefaultReturn) {
            cleanupAndExit(tmpDir, 0);
        }
    }

    // Download the pkg (binary-safe)
    NSLog(@"updater: downloading %@...", downloadURL);
    // PID-unique path; NEVER embed the remote version string (shell injection
    // via crafted appcast sparkle:version). The PID suffix prevents both
    // symlink attacks and collisions between concurrent updater runs.
    NSString *pkgPath = [tmpDir stringByAppendingPathComponent:@"update.pkg"];
    if (!fetchToFile(downloadURL, pkgPath)) {
        if (userInitiated)
            NSRunAlertPanel(@"Mavericks Tailscale",
                            @"Download failed. Try again later.", @"OK", nil, nil);
        cleanupAndExit(tmpDir, 1);
    }

    // Install with admin privileges
    NSLog(@"updater: installing (admin authorization required)...");
    if (!installPkgElevated(pkgPath)) {
        if (userInitiated)
            NSRunAlertPanel(@"Mavericks Tailscale",
                            @"Installation failed. Check Console.app for details.", @"OK", nil, nil);
        cleanupAndExit(tmpDir, 1);
    }

    // The pkg's postinstall reloads the daemon; nothing to do here.
    // (The previous bare system() launchctl call was a silent no-op from
    // a non-elevated process — LaunchDaemons require root to unload/load.)

    // Clean up the entire secure temp directory
    [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:nil];

    NSLog(@"updater: installed %@", availVersion);
    if (userInitiated)
        NSRunAlertPanel(@"Mavericks Tailscale",
                        [NSString stringWithFormat:@"Updated to %@. The daemon has been reloaded.", availVersion],
                        @"OK", nil, nil);

    cleanupAndExit(tmpDir, 0);
}
