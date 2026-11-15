#import <Foundation/Foundation.h>
#import <rootless.h>
#import "../Utils/NSBundle+YTMU.h"
#import "ABCSwitch.h"

#define LOC(key) [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:nil table:nil]
#define LOCF(key, fallback) [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil]
