#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Represents a terminal session with a PTY backend and VT parser.
 */
typedef struct TerminalSession TerminalSession;

/**
 * Opaque pointer to a TerminalSession.
 */
typedef struct TerminalSession *PierTerminalHandle;

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
 * Free a string allocated by Rust.
 */
void pier_string_free(char *s);

/**
 * Initialize the Rust logger.
 */
void pier_init(void);
