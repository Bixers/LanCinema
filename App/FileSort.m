#import "FileSort.h"

NSArray<NSDictionary *> *LCSortedItems(NSArray<NSDictionary *> *items, NSString *key, BOOL descending) {
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL folderA = [a[@"directory"] boolValue], folderB = [b[@"directory"] boolValue];
        // Descending changes the order within groups; folders always lead.
        if (folderA != folderB) return folderA ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult order = NSOrderedSame;
        if ([key isEqual:@"modified"]) {
            BOOL knownA = [a[@"modified"] isKindOfClass:NSNumber.class];
            BOOL knownB = [b[@"modified"] isKindOfClass:NSNumber.class];
            if (knownA != knownB) return knownA ? NSOrderedAscending : NSOrderedDescending;
            if (knownA) order = [a[@"modified"] compare:b[@"modified"]];
        } else if ([key isEqual:@"size"] && !folderA) {
            order = [a[@"size"] compare:b[@"size"]];
        } else if ([key isEqual:@"type"] && !folderA) {
            order = [[a[@"name"] pathExtension].lowercaseString localizedStandardCompare:[b[@"name"] pathExtension].lowercaseString];
        }
        if (order == NSOrderedSame) order = [a[@"name"] localizedStandardCompare:b[@"name"]];
        if (order == NSOrderedSame) order = [a[@"path"] compare:b[@"path"]];
        return descending ? -order : order;
    }];
}
