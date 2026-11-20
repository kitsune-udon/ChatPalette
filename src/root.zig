//! Product modules shared with the development tools and integration tests.
pub const input = @import("desktop/input.zig");
pub const management = @import("desktop/management.zig");
pub const operations = @import("desktop/operations.zig");
pub const palette = @import("desktop/palette.zig");
pub const windows = @import("desktop/win.zig");
pub const worker_client = @import("desktop/worker_client.zig");

pub const storage = @import("storage/store.zig");
pub const sqlite = @import("storage/sqlite.zig");
pub const max_file_bytes = @import("storage/model.zig").max_file_bytes;

pub const worker = @import("worker/main.zig");
pub const keyboard = @import("worker/keyboard.zig");
pub const uia = @import("worker/uia.zig");
