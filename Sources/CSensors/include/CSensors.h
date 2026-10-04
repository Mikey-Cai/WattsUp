#ifndef WATTSUP_CSENSORS_H
#define WATTSUP_CSENSORS_H

#include <stdint.h>
#include <stddef.h>

typedef struct WUSMCConnection WUSMCConnection;
typedef struct {
    uint32_t type;
    uint32_t size;
    uint8_t bytes[32];
    uint8_t result;
    uint8_t status;
} WUSMCValue;

WUSMCConnection *wu_smc_open(int32_t *error);
void wu_smc_close(WUSMCConnection *connection);
int32_t wu_smc_read(WUSMCConnection *connection, uint32_t key, WUSMCValue *value);
int32_t wu_smc_key_at_index(WUSMCConnection *connection, uint32_t index, uint32_t *key);
size_t wu_smc_struct_size(void);

typedef struct WUIOReport WUIOReport;
typedef struct {
    char name[256];
    char group[256];
    char subgroup[256];
    char unit[64];
    int64_t value;
} WUEnergyChannel;

/* No private framework is linked: all IOReport symbols are resolved at runtime. */
WUIOReport *wu_ioreport_open(char *error, size_t errorSize);
void wu_ioreport_close(WUIOReport *report);
/* Descriptors contain no energy readings; value is always zero and must not be shown as measured. */
int wu_ioreport_describe(WUEnergyChannel *channels, size_t capacity, size_t *count,
                         char *error, size_t errorSize);
/* 0 = success, 1 = initial baseline, negative = failure. */
int wu_ioreport_sample(WUIOReport *report, WUEnergyChannel *channels,
                       size_t capacity, size_t *count, double *elapsedSeconds,
                       char *error, size_t errorSize);

#endif
