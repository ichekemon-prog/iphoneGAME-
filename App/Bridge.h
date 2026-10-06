#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
bool probe_configure(const char *target, const char *documents, uint32_t seconds);
bool probe_start(const char *path, const char *host, const char *runner, const char *self_bundle);
void probe_stop(void);
bool probe_running(void);
char *probe_status(void);
bool probe_enable_diagnostics(void);
void probe_set_ddi_dir(const char *path);
char *probe_diagnostics(void);
void probe_free_string(char *p);
bool agent_ready(void);
uint64_t agent_frame_seq(void);
uint8_t *agent_copy_frame(size_t *len_out);
void agent_free_frame(uint8_t *p, size_t len);
char *agent_command(const char *json);
