const std = @import("std");

pub const header_bytes = @sizeOf(u32);
pub const Header = [header_bytes]u8;
pub const max_body_bytes = 32 * 1024;
pub const Buffer = [header_bytes + max_body_bytes]u8;

pub fn decodeLength(header: *const Header) ?u32 {
    const length = std.mem.readInt(u32, header, .little);
    return if (length == 0 or length > max_body_bytes) null else length;
}

pub fn encodeLength(header: *Header, length: usize) void {
    std.debug.assert(length > 0 and length <= max_body_bytes);
    std.mem.writeInt(u32, header, @intCast(length), .little);
}

pub const Mode = enum {
    browser_context,
    resolve,
    verify_input,
    verify_chat,
    chat_focus,
    reactions_show,
    reaction_configure,
    reaction_capture,
    reaction_check,
    reaction_send,
    chat_enter,
    chat_clear,
    input_insert,

    pub fn parse(value: []const u8) ?Mode {
        inline for (std.meta.fields(Mode)) |field| {
            if (std.ascii.eqlIgnoreCase(value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn deadlineMs(self: Mode) u64 {
        return switch (self) {
            .verify_input, .verify_chat, .chat_enter, .chat_clear, .input_insert => 2500,
            else => 8000,
        };
    }

    pub fn inputOutcome(self: Mode) ?[]const u8 {
        return switch (self) {
            .chat_enter => "enter_sent",
            .chat_clear => "cleared",
            .input_insert => "inserted",
            else => null,
        };
    }
};
