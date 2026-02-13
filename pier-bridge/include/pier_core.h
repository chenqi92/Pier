#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * SSH session manager.
 */
typedef struct SshSession SshSession;

/**
 * Represents a terminal session with a PTY backend and VT parser.
 */
typedef struct TerminalSession TerminalSession;

/**
 * Opaque pointer to a TerminalSession.
 */
typedef struct TerminalSession *PierTerminalHandle;

/**
 * Opaque pointer to an SSH session.
 */
typedef struct SshSession *PierSshHandle;

/**
 * Create a new terminal session.
 * Returns null on failure.
 */
PierTerminalHandle pier_terminal_create(uint16_t cols, uint16_t rows, const char *shell);

/**
 * Destroy a terminal session.
 */
void pier_terminal_destroy(PierTerminalHandle handle);

/**
 * Write user input to the terminal.
 * Returns 0 on success, -1 on failure.
 */
int32_t pier_terminal_write(PierTerminalHandle handle, const uint8_t *data, uintptr_t len);

/**
 * Read output from the terminal.
 * Writes data into the provided buffer and returns the number of bytes read.
 * Returns -1 on failure.
 */
int64_t pier_terminal_read(PierTerminalHandle handle, uint8_t *buffer, uintptr_t buffer_len);

/**
 * Resize the terminal.
 */
int32_t pier_terminal_resize(PierTerminalHandle handle, uint16_t cols, uint16_t rows);

/**
 * Get the PTY file descriptor for polling.
 */
int32_t pier_terminal_fd(PierTerminalHandle handle);

/**
 * Search result returned via FFI as a JSON string.
 * Caller must free the returned string with pier_string_free.
 */
char *pier_search_files(const char *root, const char *pattern, uintptr_t max_results);

/**
 * List directory contents. Returns JSON string.
 * Caller must free the returned string with pier_string_free.
 */
char *pier_list_directory(const char *path);

/**
 * Connect to an SSH server.
 * auth_type: 0 = password, 1 = key file
 * credential: password string (auth_type=0) or key file path (auth_type=1)
 * Returns null on failure.
 */
PierSshHandle pier_ssh_connect(const char *host,
                               uint16_t port,
                               const char *username,
                               int32_t auth_type,
                               const char *credential);

/**
 * Disconnect an SSH session and free the handle.
 */
int32_t pier_ssh_disconnect(PierSshHandle handle);

/**
 * Check if SSH session is connected.
 * Returns 1 if connected, 0 if not, -1 on invalid handle.
 */
int32_t pier_ssh_is_connected(PierSshHandle handle);

/**
 * Detect services installed on the remote server.
 * Returns a JSON array of DetectedService.
 * Caller must free with pier_string_free.
 */
char *pier_ssh_detect_services(PierSshHandle handle);

/**
 * Execute a command on the remote server.
 * Returns JSON: {"exit_code": N, "stdout": "..."}
 * Caller must free with pier_string_free.
 */
char *pier_ssh_exec(PierSshHandle handle, const char *command);

/**
 * Start local port forwarding: 127.0.0.1:local_port → remote_host:remote_port.
 * Returns 0 on success, -1 on failure.
 */
int32_t pier_ssh_forward_port(PierSshHandle handle,
                              uint16_t local_port,
                              const char *remote_host,
                              uint16_t remote_port);

/**
 * Stop a local port forward.
 * Returns 0 on success, -1 if no such forward.
 */
int32_t pier_ssh_stop_forward(PierSshHandle handle, uint16_t local_port);

/**
 * List active forward ports as a JSON array.
 * Caller must free with pier_string_free.
 */
char *pier_ssh_list_forwards(PierSshHandle handle);

/**
 * Free a string allocated by Rust.
 */
void pier_string_free(char *s);

/**
 * Initialize the Rust logger.
 */
void pier_init(void);
