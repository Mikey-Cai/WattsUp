#include "CSensors.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

typedef CFDictionaryRef (*CopyChannelsFn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef CFTypeRef (*CreateSubscriptionFn)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*CreateSamplesFn)(CFTypeRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*CreateDeltaFn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*ChannelStringFn)(CFDictionaryRef);
typedef int64_t (*SimpleValueFn)(CFDictionaryRef, int);

struct WUIOReport {
    void *library;
    CFTypeRef subscription;
    CFMutableDictionaryRef subscribedChannels;
    CFDictionaryRef previous;
    double previousTime;
    CreateSamplesFn createSamples;
    CreateDeltaFn createDelta;
    ChannelStringFn getName, getGroup, getSubgroup, getUnit;
    SimpleValueFn getValue;
};

static void set_error(char *error, size_t size, const char *message) {
    if (error && size) snprintf(error, size, "%s", message ? message : "Unknown IOReport failure");
}
static double monotonic_seconds(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (double) time.tv_sec + (double) time.tv_nsec / 1e9;
}
static void copy_string(CFStringRef string, char *output, size_t size) {
    output[0] = 0;
    if (string && CFGetTypeID(string) == CFStringGetTypeID())
        CFStringGetCString(string, output, size, kCFStringEncodingUTF8);
}

int wu_ioreport_describe(WUEnergyChannel *channels, size_t capacity, size_t *count,
                         char *error, size_t errorSize) {
    if (count) *count = 0;
    if (!channels || !count) return -1;
    void *library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!library) library = dlopen("/System/Library/PrivateFrameworks/IOReport.framework/IOReport", RTLD_LAZY | RTLD_LOCAL);
    if (!library) { set_error(error, errorSize, dlerror()); return -1; }
    CopyChannelsFn copyChannels = (CopyChannelsFn) dlsym(library, "IOReportCopyChannelsInGroup");
    ChannelStringFn name = (ChannelStringFn) dlsym(library, "IOReportChannelGetChannelName");
    ChannelStringFn group = (ChannelStringFn) dlsym(library, "IOReportChannelGetGroup");
    ChannelStringFn subgroup = (ChannelStringFn) dlsym(library, "IOReportChannelGetSubGroup");
    ChannelStringFn unit = (ChannelStringFn) dlsym(library, "IOReportChannelGetUnitLabel");
    if (!copyChannels || !name || !group || !subgroup || !unit) {
        set_error(error, errorSize, "IOReport descriptor symbols unavailable"); dlclose(library); return -1;
    }
    CFDictionaryRef descriptors = copyChannels(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!descriptors) { set_error(error, errorSize, "No Energy Model descriptors"); dlclose(library); return -1; }
    CFArrayRef entries = CFDictionaryGetValue(descriptors, CFSTR("IOReportChannels"));
    if (!entries || CFGetTypeID(entries) != CFArrayGetTypeID() || (size_t) CFArrayGetCount(entries) > capacity) {
        set_error(error, errorSize, "Invalid/too many IOReport descriptors"); CFRelease(descriptors); dlclose(library); return -1;
    }
    for (CFIndex i = 0; i < CFArrayGetCount(entries); ++i) {
        CFDictionaryRef channel = CFArrayGetValueAtIndex(entries, i);
        if (!channel || CFGetTypeID(channel) != CFDictionaryGetTypeID()) continue;
        WUEnergyChannel *output = &channels[*count];
        memset(output, 0, sizeof(*output));
        copy_string(name(channel), output->name, sizeof(output->name));
        copy_string(group(channel), output->group, sizeof(output->group));
        copy_string(subgroup(channel), output->subgroup, sizeof(output->subgroup));
        copy_string(unit(channel), output->unit, sizeof(output->unit));
        ++*count;
    }
    CFRelease(descriptors);
    dlclose(library);
    return 0;
}

WUIOReport *wu_ioreport_open(char *error, size_t errorSize) {
    WUIOReport *report = calloc(1, sizeof(*report));
    if (!report) { set_error(error, errorSize, "IOReport allocation failed"); return NULL; }
    report->library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!report->library) {
        report->library = dlopen("/System/Library/PrivateFrameworks/IOReport.framework/IOReport", RTLD_LAZY | RTLD_LOCAL);
    }
    if (!report->library) { set_error(error, errorSize, dlerror()); wu_ioreport_close(report); return NULL; }
    CopyChannelsFn copyChannels = (CopyChannelsFn) dlsym(report->library, "IOReportCopyChannelsInGroup");
    CreateSubscriptionFn createSubscription = (CreateSubscriptionFn) dlsym(report->library, "IOReportCreateSubscription");
    report->createSamples = (CreateSamplesFn) dlsym(report->library, "IOReportCreateSamples");
    report->createDelta = (CreateDeltaFn) dlsym(report->library, "IOReportCreateSamplesDelta");
    report->getName = (ChannelStringFn) dlsym(report->library, "IOReportChannelGetChannelName");
    report->getGroup = (ChannelStringFn) dlsym(report->library, "IOReportChannelGetGroup");
    report->getSubgroup = (ChannelStringFn) dlsym(report->library, "IOReportChannelGetSubGroup");
    report->getUnit = (ChannelStringFn) dlsym(report->library, "IOReportChannelGetUnitLabel");
    report->getValue = (SimpleValueFn) dlsym(report->library, "IOReportSimpleGetIntegerValue");
    if (!copyChannels || !createSubscription || !report->createSamples || !report->createDelta ||
        !report->getName || !report->getGroup || !report->getSubgroup || !report->getUnit || !report->getValue) {
        set_error(error, errorSize, "Required IOReport symbols are unavailable"); wu_ioreport_close(report); return NULL;
    }
    CFDictionaryRef channels = copyChannels(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!channels) { set_error(error, errorSize, "IOReportCopyChannelsInGroup(Energy Model) returned NULL"); wu_ioreport_close(report); return NULL; }
    CFMutableDictionaryRef mutableChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels);
    CFRelease(channels);
    report->subscription = createSubscription(NULL, mutableChannels, &report->subscribedChannels, 0, NULL);
    CFRelease(mutableChannels);
    if (!report->subscription || !report->subscribedChannels) {
        set_error(error, errorSize, "IOReportCreateSubscription returned no subscription/channels (possibly permission denial)");
        wu_ioreport_close(report); return NULL;
    }
    return report;
}

void wu_ioreport_close(WUIOReport *report) {
    if (!report) return;
    if (report->previous) CFRelease(report->previous);
    if (report->subscribedChannels) CFRelease(report->subscribedChannels);
    if (report->subscription) CFRelease(report->subscription);
    if (report->library) dlclose(report->library);
    free(report);
}

int wu_ioreport_sample(WUIOReport *report, WUEnergyChannel *channels,
                       size_t capacity, size_t *count, double *elapsedSeconds,
                       char *error, size_t errorSize) {
    if (count) *count = 0;
    if (elapsedSeconds) *elapsedSeconds = 0;
    if (!report || !channels || !count || !elapsedSeconds) { set_error(error, errorSize, "Invalid IOReport sample arguments"); return -1; }
    CFDictionaryRef current = report->createSamples(report->subscription, report->subscribedChannels, NULL);
    double now = monotonic_seconds();
    if (!current) { set_error(error, errorSize, "IOReportCreateSamples returned NULL"); return -1; }
    if (!report->previous) { report->previous = current; report->previousTime = now; return 1; }
    CFDictionaryRef delta = report->createDelta(report->previous, current, NULL);
    *elapsedSeconds = now - report->previousTime;
    CFRelease(report->previous);
    report->previous = current;
    report->previousTime = now;
    if (!delta) { set_error(error, errorSize, "IOReportCreateSamplesDelta returned NULL"); return -1; }
    CFArrayRef entries = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (!entries || CFGetTypeID(entries) != CFArrayGetTypeID()) {
        CFRelease(delta); set_error(error, errorSize, "IOReport delta has no IOReportChannels array"); return -1;
    }
    CFIndex number = CFArrayGetCount(entries);
    if ((size_t) number > capacity) { CFRelease(delta); set_error(error, errorSize, "IOReport channel capacity exceeded"); return -1; }
    for (CFIndex i = 0; i < number; ++i) {
        CFDictionaryRef channel = CFArrayGetValueAtIndex(entries, i);
        if (!channel || CFGetTypeID(channel) != CFDictionaryGetTypeID()) continue;
        WUEnergyChannel *output = &channels[*count];
        memset(output, 0, sizeof(*output));
        copy_string(report->getName(channel), output->name, sizeof(output->name));
        copy_string(report->getGroup(channel), output->group, sizeof(output->group));
        copy_string(report->getSubgroup(channel), output->subgroup, sizeof(output->subgroup));
        copy_string(report->getUnit(channel), output->unit, sizeof(output->unit));
        output->value = report->getValue(channel, 0);
        ++*count;
    }
    CFRelease(delta);
    return 0;
}
