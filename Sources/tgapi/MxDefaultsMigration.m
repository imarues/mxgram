#import <Foundation/Foundation.h>

// Carries settings across the rename from Lead to Mx.
//
// Every preference this tweak owns used to be stored under a "Lead"-prefixed
// key in NSUserDefaults; they are now "Mx"-prefixed. Without this, an upgrade
// would look to the user like a factory reset: every toggle back off, the edit
// history gone, the ghost exception list empty, the chosen language back to
// English.
//
// The copy is by prefix rather than by a list of names, so a key added later
// migrates on its own — and so does the persisted data, which is where the real
// loss would be (MxEditHistory, MxEditHistoryPeers, MxDeletedMsgIds,
// MxGhostExceptions).
//
// Runs as a constructor, before any code reads a default. Constructor priority
// 101 is the lowest an application may use; anything else that reads
// NSUserDefaults from its own constructor therefore sees migrated values.
//
// Keys not owned by this tweak — disableOnlineStatus and its siblings — never
// carried the prefix and are read under their original names, so they need
// nothing here.

static NSString *const kMxMigrationDoneKey = @"MxDefaultsMigratedFromLead";
static NSString *const kOldPrefix = @"Lead";
static NSString *const kNewPrefix = @"Mx";

__attribute__((constructor(101))) static void MxMigrateDefaultsFromLead(void) {
  @autoreleasepool {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kMxMigrationDoneKey]) {
      return;
    }

    NSDictionary *all = [defaults dictionaryRepresentation];
    NSUInteger moved = 0;

    for (NSString *oldKey in all) {
      if (![oldKey hasPrefix:kOldPrefix]) {
        continue;
      }

      NSString *newKey = [kNewPrefix
          stringByAppendingString:[oldKey substringFromIndex:kOldPrefix.length]];

      // A value already written under the new name wins: it is either a fresh
      // install or a second run, and either way it is the more recent truth.
      if ([defaults objectForKey:newKey] != nil) {
        continue;
      }

      id value = all[oldKey];
      if (value == nil) {
        continue;
      }

      [defaults setObject:value forKey:newKey];
      moved++;
    }

    // The old keys are deliberately left in place. They cost a few kilobytes and
    // they are the only way back if this build has to be rolled back to Lead.
    [defaults setBool:YES forKey:kMxMigrationDoneKey];
    [defaults synchronize];

    if (moved > 0) {
      NSLog(@"[Kira] migrated %lu setting(s) from Lead", (unsigned long)moved);
    }
  }
}
