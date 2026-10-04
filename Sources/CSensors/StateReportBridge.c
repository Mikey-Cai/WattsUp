#include "CSensors.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef CFDictionaryRef (*CopyChannelsFn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef CFTypeRef (*CreateSubscriptionFn)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*CreateSamplesFn)(CFTypeRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*CreateDeltaFn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*ChannelStringFn)(CFDictionaryRef);
typedef int (*StateCountFn)(CFDictionaryRef);
typedef CFStringRef (*StateNameFn)(CFDictionaryRef, int);
typedef int64_t (*StateResidencyFn)(CFDictionaryRef, int);

struct WUStateReport {
    void *library;
    CFTypeRef subscription;
    CFMutableDictionaryRef subscribedChannels;
    CFDictionaryRef previous;
    CFStringRef channelName;
    CreateSamplesFn createSamples;
    CreateDeltaFn createDelta;
    ChannelStringFn getName;
    StateCountFn stateCount;
    StateNameFn stateName;
    StateResidencyFn stateResidency;
};

static void set_error(char *error, size_t size, const char *message) {
    if (error && size) snprintf(error, size, "%s", message ? message : "Unknown IOReport failure");
}

static int name_matches(ChannelStringFn getName, CFDictionaryRef channel, CFStringRef wanted) {
    CFStringRef name = getName(channel);
    return name && CFGetTypeID(name) == CFStringGetTypeID() && CFStringCompare(name, wanted, 0) == kCFCompareEqualTo;
}

WUStateReport *wu_state_open(const char *group, const char *subgroup, const char *channel,
                             char *error, size_t errorSize) {
    if (!group || !channel) { set_error(error, errorSize, "Invalid state channel arguments"); return NULL; }
    WUStateReport *report = calloc(1, sizeof(*report));
    if (!report) { set_error(error, errorSize, "IOReport allocation failed"); return NULL; }
    report->library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!report->library) {
        report->library = dlopen("/System/Library/PrivateFrameworks/IOReport.framework/IOReport", RTLD_LAZY | RTLD_LOCAL);
    }
    if (!report->library) { set_error(error, errorSize, dlerror()); wu_state_close(report); return NULL; }
    CopyChannelsFn copyChannels = (CopyChannelsFn) dlsym(report->library, "IOReportCopyChannelsInGroup");
    CreateSubscriptionFn createSubscription = (CreateSubscriptionFn) dlsym(report->library, "IOReportCreateSubscription");
    report->createSamples = (CreateSamplesFn) dlsym(report->library, "IOReportCreateSamples");
    report->createDelta = (CreateDeltaFn) dlsym(report->library, "IOReportCreateSamplesDelta");
    report->getName = (ChannelStringFn) dlsym(report->library, "IOReportChannelGetChannelName");
    report->stateCount = (StateCountFn) dlsym(report->library, "IOReportStateGetCount");
    report->stateName = (StateNameFn) dlsym(report->library, "IOReportStateGetNameForIndex");
    report->stateResidency = (StateResidencyFn) dlsym(report->library, "IOReportStateGetResidency");
    if (!copyChannels || !createSubscription || !report->createSamples || !report->createDelta || !report->getName ||
        !report->stateCount || !report->stateName || !report->stateResidency) {
        set_error(error, errorSize, "Required IOReport state symbols are unavailable"); wu_state_close(report); return NULL;
    }
    report->channelName = CFStringCreateWithCString(kCFAllocatorDefault, channel, kCFStringEncodingUTF8);
    CFStringRef groupName = CFStringCreateWithCString(kCFAllocatorDefault, group, kCFStringEncodingUTF8);
    CFStringRef subgroupName = subgroup ? CFStringCreateWithCString(kCFAllocatorDefault, subgroup, kCFStringEncodingUTF8) : NULL;
    CFDictionaryRef all = copyChannels(groupName, subgroupName, 0, 0, 0);
    CFRelease(groupName);
    if (subgroupName) CFRelease(subgroupName);
    if (!all) { set_error(error, errorSize, "IOReport group not present on this Mac"); wu_state_close(report); return NULL; }
    // Subscribe to the one channel only: a whole PMP subgroup has ~90 histograms.
    CFArrayRef entries = CFDictionaryGetValue(all, CFSTR("IOReportChannels"));
    CFMutableArrayRef wanted = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (entries && CFGetTypeID(entries) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(entries); ++i) {
            CFDictionaryRef entry = CFArrayGetValueAtIndex(entries, i);
            if (entry && CFGetTypeID(entry) == CFDictionaryGetTypeID() && name_matches(report->getName, entry, report->channelName))
                CFArrayAppendValue(wanted, entry);
        }
    }
    if (CFArrayGetCount(wanted) != 1) {
        CFRelease(wanted); CFRelease(all);
        set_error(error, errorSize, "IOReport state channel not found (or not unique)"); wu_state_close(report); return NULL;
    }
    CFMutableDictionaryRef request = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, all);
    CFDictionarySetValue(request, CFSTR("IOReportChannels"), wanted);
    CFRelease(wanted);
    CFRelease(all);
    report->subscription = createSubscription(NULL, request, &report->subscribedChannels, 0, NULL);
    CFRelease(request);
    if (!report->subscription || !report->subscribedChannels) {
        set_error(error, errorSize, "IOReportCreateSubscription refused the state channel"); wu_state_close(report); return NULL;
    }
    return report;
}

void wu_state_close(WUStateReport *report) {
    if (!report) return;
    if (report->previous) CFRelease(report->previous);
    if (report->subscribedChannels) CFRelease(report->subscribedChannels);
    if (report->subscription) CFRelease(report->subscription);
    if (report->channelName) CFRelease(report->channelName);
    if (report->library) dlclose(report->library);
    free(report);
}

int wu_state_sample(WUStateReport *report, WUStateBucket *buckets, size_t capacity, size_t *count,
                    char *error, size_t errorSize) {
    if (count) *count = 0;
    if (!report || !buckets || !count) { set_error(error, errorSize, "Invalid state sample arguments"); return -1; }
    CFDictionaryRef current = report->createSamples(report->subscription, report->subscribedChannels, NULL);
    if (!current) { set_error(error, errorSize, "IOReportCreateSamples returned NULL"); return -1; }
    if (!report->previous) { report->previous = current; return 1; }
    CFDictionaryRef delta = report->createDelta(report->previous, current, NULL);
    CFRelease(report->previous);
    report->previous = current;
    if (!delta) { set_error(error, errorSize, "IOReportCreateSamplesDelta returned NULL"); return -1; }
    CFArrayRef entries = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    int result = -1;
    if (entries && CFGetTypeID(entries) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount(entries); ++i) {
            CFDictionaryRef entry = CFArrayGetValueAtIndex(entries, i);
            if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID() || !name_matches(report->getName, entry, report->channelName)) continue;
            int states = report->stateCount(entry);
            if (states < 0 || (size_t) states > capacity) break;
            for (int k = 0; k < states; ++k) {
                WUStateBucket *bucket = &buckets[k];
                memset(bucket, 0, sizeof(*bucket));
                CFStringRef name = report->stateName(entry, k);
                if (name && CFGetTypeID(name) == CFStringGetTypeID())
                    CFStringGetCString(name, bucket->name, sizeof(bucket->name), kCFStringEncodingUTF8);
                bucket->count = report->stateResidency(entry, k);
            }
            *count = (size_t) states;
            result = 0;
            break;
        }
    }
    CFRelease(delta);
    if (result != 0) set_error(error, errorSize, "State channel missing from delta or too many states");
    return result;
}
