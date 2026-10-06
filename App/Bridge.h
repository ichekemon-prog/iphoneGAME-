#include <stdbool.h>
#include <stdint.h>
bool probe_configure(const char *target, const char *documents, uint32_t seconds);
bool probe_start(const char *path, const char *host, const char *runner, const char *self_bundle);
void probe_stop(void);
bool probe_running(void);
char *probe_status(void);
void probe_free_string(char *p);
