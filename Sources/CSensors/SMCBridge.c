#include "CSensors.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} SMCVersion;
typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPowerLimit;
typedef struct {
    uint32_t dataSize, dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPowerLimit powerLimit;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;
_Static_assert(sizeof(SMCParam) == 80, "AppleSMC ABI requires 80 bytes");
_Static_assert(offsetof(SMCParam, bytes) == 48, "AppleSMC bytes offset");

struct WUSMCConnection { io_connect_t handle; };

size_t wu_smc_struct_size(void) { return sizeof(SMCParam); }

WUSMCConnection *wu_smc_open(int32_t *error) {
    if (error) *error = 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) { if (error) *error = (int32_t) kIOReturnNotFound; return NULL; }
    io_connect_t handle = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &handle);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) { if (error) *error = result; return NULL; }
    WUSMCConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) { IOServiceClose(handle); if (error) *error = (int32_t) kIOReturnNoMemory; return NULL; }
    connection->handle = handle;
    return connection;
}

void wu_smc_close(WUSMCConnection *connection) {
    if (!connection) return;
    if (connection->handle) IOServiceClose(connection->handle);
    free(connection);
}

static int32_t call_smc(WUSMCConnection *connection, const SMCParam *input, SMCParam *output) {
    if (!connection) return (int32_t) kIOReturnNotOpen;
    size_t outputSize = sizeof(*output);
    memset(output, 0, sizeof(*output));
    kern_return_t status = IOConnectCallStructMethod(connection->handle, 2, input, sizeof(*input), output, &outputSize);
    if (status != KERN_SUCCESS) return status;
    if (outputSize != sizeof(*output)) return (int32_t) kIOReturnUnderrun;
    if (output->result != 0) return (int32_t) kIOReturnError;
    return 0;
}

int32_t wu_smc_read(WUSMCConnection *connection, uint32_t key, WUSMCValue *value) {
    if (!value) return (int32_t) kIOReturnBadArgument;
    memset(value, 0, sizeof(*value));
    SMCParam input = {0}, output = {0};
    input.key = key;
    input.data8 = 9;
    int32_t status = call_smc(connection, &input, &output);
    value->result = output.result;
    value->status = output.status;
    if (status) return status;
    value->type = output.keyInfo.dataType;
    value->size = output.keyInfo.dataSize;
    if (value->size > sizeof(value->bytes)) return (int32_t) kIOReturnOverrun;
    input.keyInfo = output.keyInfo;
    input.data8 = 5;
    status = call_smc(connection, &input, &output);
    value->result = output.result;
    value->status = output.status;
    if (status) return status;
    memcpy(value->bytes, output.bytes, value->size);
    return 0;
}

int32_t wu_smc_key_at_index(WUSMCConnection *connection, uint32_t index, uint32_t *key) {
    if (!key) return (int32_t) kIOReturnBadArgument;
    SMCParam input = {0}, output = {0};
    input.data8 = 8;
    input.data32 = index;
    int32_t status = call_smc(connection, &input, &output);
    if (!status) *key = output.key;
    return status;
}
