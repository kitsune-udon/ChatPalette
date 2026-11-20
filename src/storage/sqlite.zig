const std = @import("std");

const Database = opaque {};
const Prepared = opaque {};
const Destructor = ?*const fn (?*anyopaque) callconv(.c) void;
const ExecCallback = ?*const fn (?*anyopaque, c_int, [*c]?[*:0]u8, [*c]?[*:0]u8) callconv(.c) c_int;

const Api = struct {
    sqlite3_open_v2: *const fn ([*:0]const u8, *?*Database, c_int, ?[*:0]const u8) callconv(.c) c_int,
    sqlite3_close_v2: *const fn (*Database) callconv(.c) c_int,
    sqlite3_exec: *const fn (*Database, [*:0]const u8, ExecCallback, ?*anyopaque, ?*?[*:0]u8) callconv(.c) c_int,
    sqlite3_prepare_v2: *const fn (*Database, [*]const u8, c_int, *?*Prepared, ?*[*]const u8) callconv(.c) c_int,
    sqlite3_step: *const fn (*Prepared) callconv(.c) c_int,
    sqlite3_finalize: *const fn (*Prepared) callconv(.c) c_int,
    sqlite3_reset: *const fn (*Prepared) callconv(.c) c_int,
    sqlite3_clear_bindings: *const fn (*Prepared) callconv(.c) c_int,
    sqlite3_bind_int64: *const fn (*Prepared, c_int, i64) callconv(.c) c_int,
    sqlite3_bind_text: *const fn (*Prepared, c_int, [*]const u8, c_int, Destructor) callconv(.c) c_int,
    sqlite3_column_count: *const fn (*Prepared) callconv(.c) c_int,
    sqlite3_column_type: *const fn (*Prepared, c_int) callconv(.c) c_int,
    sqlite3_column_int64: *const fn (*Prepared, c_int) callconv(.c) i64,
    sqlite3_column_text: *const fn (*Prepared, c_int) callconv(.c) ?[*]const u8,
    sqlite3_column_bytes: *const fn (*Prepared, c_int) callconv(.c) c_int,
    sqlite3_get_autocommit: *const fn (*Database) callconv(.c) c_int,
    sqlite3_db_config: *const fn (*Database, c_int, ...) callconv(.c) c_int,
};

pub const OpenMode = enum(c_int) { read_only = 1, read_write = 2, create = 6 };

pub const Value = union(enum) { text: []const u8, int: i64 };

/// The close result did not confirm whether the handle is still live.
/// Pin the DLL and keep the identity for diagnosis. Never retry or query this handle implicitly.
pub const RejectedClose = struct {
    cause: anyerror,
    sqlite_code: c_int,
    close_code: c_int,
    module: std.DynLib,
    handle: *Database,
};

pub const Connection = struct {
    dll: std.DynLib,
    handle: *Database,
    api: Api,
    unusable: bool = false,
    closed: bool = false,
    last_code: c_int = 0,
    rollback_code: ?c_int = null,
    recovery_close_code: ?c_int = null,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, mode: OpenMode) !Connection {
        return openReporting(allocator, path, mode, null);
    }

    pub fn openReporting(allocator: std.mem.Allocator, path: []const u8, mode: OpenMode, rejected: ?*?RejectedClose) !Connection {
        if (std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path))
            return error.InvalidPath;
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var dll: std.DynLib = .{ .inner = try @FieldType(std.DynLib, "inner").openExW(
            std.unicode.utf8ToUtf16LeStringLiteral("winsqlite3.dll"),
            .load_library_search_system32,
        ) };
        var owns_module = true;
        errdefer if (owns_module) dll.close();
        var api: Api = undefined;
        inline for (std.meta.fields(Api)) |field| {
            @field(api, field.name) = dll.lookup(field.type, field.name) orelse return error.IncompatibleSqlite;
        }
        var handle: ?*Database = null;
        const code = api.sqlite3_open_v2(path_z, &handle, @intFromEnum(mode), null);
        const opened = handle orelse {
            try checkCode(code);
            return error.SqliteFailure;
        };
        var connection = Connection{ .dll = dll, .api = api, .handle = opened };
        owns_module = false;
        errdefer |cause| connection.finish(cause, rejected);
        try connection.check(code);
        try connection.exec("PRAGMA busy_timeout=100");
        return connection;
    }

    pub fn close(self: *Connection) void {
        self.finish(null, null);
    }

    pub fn finish(self: *Connection, cause: ?anyerror, rejected: ?*?RejectedClose) void {
        // Every prepared statement is finalized before this call.
        if (!self.closed) {
            const code = self.api.sqlite3_close_v2(self.handle);
            if (code != 0) {
                const primary = cause orelse error.CloseDatabaseFailed;
                if (rejected) |slot| {
                    std.debug.assert(slot.* == null);
                    slot.* = .{ .cause = primary, .sqlite_code = self.last_code, .close_code = code, .module = self.dll, .handle = self.handle };
                    self.* = undefined;
                    return;
                }
                std.debug.panic("SQLite {s} (code {d}), close failed ({d})", .{ @errorName(primary), self.last_code, code });
            }
        }
        self.dll.close();
        self.* = undefined;
    }

    fn checkCode(code: c_int) !void {
        return switch (code & 0xff) {
            0 => {},
            5, 6 => error.DatabaseLocked,
            8 => error.DatabaseReadOnly,
            10 => error.DatabaseIoFailure,
            11, 26 => error.InvalidDatabase,
            13 => error.DatabaseFull,
            14 => error.OpenDatabaseFailed,
            19 => error.ConstraintViolation,
            else => error.SqliteFailure,
        };
    }

    fn check(self: *Connection, code: c_int) !void {
        if (code != 0) self.last_code = code;
        return checkCode(code);
    }

    pub fn exec(self: *Connection, sql: [:0]const u8) !void {
        if (self.unusable) return error.DatabaseClosedAfterRollbackFailure;
        try self.check(self.api.sqlite3_exec(self.handle, sql, null, null, null));
    }

    pub fn prepare(self: *Connection, sql: []const u8) !Statement {
        if (self.unusable) return error.DatabaseClosedAfterRollbackFailure;
        var statement: ?*Prepared = null;
        try self.check(self.api.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &statement, null));
        return .{ .connection = self, .handle = statement orelse return error.InvalidStatement };
    }

    pub fn run(self: *Connection, sql: []const u8, values: []const Value) !void {
        var statement = try self.prepare(sql);
        defer statement.close();
        try statement.run(values);
    }

    pub fn scalarInt(self: *Connection, sql: []const u8, values: []const Value) !i64 {
        var statement = try self.prepare(sql);
        defer statement.close();
        try statement.bind(values);
        if (!try statement.next()) return error.InvalidDatabase;
        return statement.int(0);
    }

    pub fn scalarText(self: *Connection, allocator: std.mem.Allocator, sql: []const u8, values: []const Value) ![]u8 {
        var statement = try self.prepare(sql);
        defer statement.close();
        try statement.bind(values);
        if (!try statement.next()) return error.InvalidDatabase;
        return allocator.dupe(u8, try statement.text(0));
    }

    pub fn rollback(self: *Connection) void {
        if (self.unusable or self.api.sqlite3_get_autocommit(self.handle) != 0) return;
        const original_code = self.last_code;
        self.exec("ROLLBACK") catch {
            self.rollback_code = self.last_code;
            const code = self.api.sqlite3_close_v2(self.handle);
            if (code == 0) self.closed = true else self.recovery_close_code = code;
            self.unusable = true;
        };
        self.last_code = original_code;
    }

    pub fn preserveWalOnClose(self: *Connection) !void {
        const no_checkpoint_on_close: c_int = 1006;
        var enabled: c_int = 0;
        try self.check(self.api.sqlite3_db_config(self.handle, no_checkpoint_on_close, @as(c_int, 1), &enabled));
        if (enabled != 1) return error.UnsafeSqliteOptions;
    }

    pub fn clearFailure(self: *Connection) void {
        if (self.unusable) return;
        self.last_code = 0;
        self.rollback_code = null;
        self.recovery_close_code = null;
    }

    pub fn checkIntegrity(self: *Connection) !void {
        var integrity = try self.prepare("PRAGMA integrity_check");
        defer integrity.close();
        if (!try integrity.next() or !std.mem.eql(u8, try integrity.text(0), "ok") or try integrity.next())
            return error.InvalidDatabase;
        var foreign_key = try self.prepare("PRAGMA foreign_key_check");
        defer foreign_key.close();
        if (try foreign_key.next()) return error.InvalidDatabase;
    }
};

test "SQLite preserves signed integers, numeric text, and Unicode identifiers" {
    const alloc = std.testing.allocator;
    var db = try Connection.open(alloc, ":memory:", .create);
    defer db.close();

    for ([_]i64{ 0, -1, 2_147_483_648, 9_007_199_254_740_993, std.math.minInt(i64), std.math.maxInt(i64) }) |integer| {
        try std.testing.expectEqual(integer, try db.scalarInt("SELECT ?", &.{.{ .int = integer }}));
    }

    var row = try db.prepare("SELECT 7,'0007',NULL,1.5");
    defer row.close();
    try std.testing.expect(try row.next());
    try std.testing.expectEqual(@as(i64, 7), try row.int(0));
    try std.testing.expectEqualStrings("0007", try row.text(1));
    try std.testing.expectError(error.InvalidDatabase, row.text(0));
    try std.testing.expectError(error.InvalidDatabase, row.int(1));
    for (2..4) |index| {
        try std.testing.expectError(error.InvalidDatabase, row.int(@intCast(index)));
        try std.testing.expectError(error.InvalidDatabase, row.text(@intCast(index)));
    }
    try std.testing.expect(!try row.next());

    try db.exec(
        \\CREATE TABLE "日本語🎉"(value TEXT);
        \\INSERT INTO "日本語🎉" VALUES('日本語👏');
    );
    const unicode = try db.scalarText(alloc, "SELECT value FROM \"日本語🎉\"", &.{});
    defer alloc.free(unicode);
    try std.testing.expectEqualStrings("日本語👏", unicode);
}

test "SQLite clears write bindings on step and bind failures and preserves rejected text" {
    const alloc = std.testing.allocator;
    var db = try Connection.open(alloc, ":memory:", .create);
    defer db.close();
    try db.exec("CREATE TABLE sample(id INTEGER PRIMARY KEY, value TEXT)");
    var write = try db.prepare("INSERT INTO sample VALUES(?,?)");
    defer write.close();

    try write.run(&.{ .{ .int = 1 }, .{ .text = "first" } });
    try std.testing.expectError(error.ConstraintViolation, write.run(&.{ .{ .int = 1 }, .{ .text = "duplicate" } }));
    try write.run(&.{.{ .int = 2 }});
    try std.testing.expectError(error.SqliteFailure, write.run(&.{ .{ .int = 3 }, .{ .text = "partial" }, .{ .int = 99 } }));
    try std.testing.expectEqual(@as(c_int, 25), db.last_code); // SQLITE_RANGE
    try write.run(&.{.{ .int = 3 }});
    try std.testing.expectEqual(@as(i64, 2), try db.scalarInt("SELECT COUNT(*) FROM sample WHERE id IN (2,3) AND value IS NULL", &.{}));

    const first = try db.scalarText(alloc, "SELECT value FROM sample WHERE id=?", &.{.{ .int = 1 }});
    defer alloc.free(first);
    try std.testing.expectEqualStrings("first", first);
    try std.testing.expectError(error.InvalidDatabase, db.scalarText(alloc, "SELECT value FROM sample WHERE id=?", &.{}));

    try db.exec("INSERT INTO sample VALUES(6,'prefix'||char(0)||'suffix'); INSERT INTO sample VALUES(7,CAST(X'80' AS TEXT))");
    for ([_]struct { id: i64, bytes: []const u8 }{
        .{ .id = 6, .bytes = "70726566697800737566666978" },
        .{ .id = 7, .bytes = "80" },
    }) |example| {
        const id: []const Value = &.{.{ .int = example.id }};
        try std.testing.expectError(error.InvalidDatabase, db.scalarText(alloc, "SELECT value FROM sample WHERE id=?", id));
        const bytes = try db.scalarText(alloc, "SELECT hex(value) FROM sample WHERE id=?", id);
        defer alloc.free(bytes);
        try std.testing.expectEqualStrings(example.bytes, bytes);
    }
    try write.run(&.{ .{ .int = 8 }, .{ .text = "Ω" } });
    const retry = try db.scalarText(alloc, "SELECT value FROM sample WHERE id=8", &.{});
    defer alloc.free(retry);
    try std.testing.expectEqualStrings("Ω", retry);
}

fn testWriteFailure(db: *Connection) !void {
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.rollback();
    try db.exec("INSERT INTO sample VALUES(2)");
    try db.exec("INSERT INTO sample VALUES(1)");
    try db.exec("COMMIT");
}

test "failed transaction preserves both the original SQLite failure and cleanup outcomes" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const base = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);
    const test_api = struct {
        threadlocal var original_exec: @FieldType(Api, "sqlite3_exec") = undefined;
        fn failRollback(handle: *Database, sql: [*:0]const u8, callback: ExecCallback, context: ?*anyopaque, errmsg: ?*?[*:0]u8) callconv(.c) c_int {
            if (std.mem.eql(u8, std.mem.span(sql), "ROLLBACK")) return 10;
            return original_exec(handle, sql, callback, context, errmsg);
        }
        fn failClose(_: *Database) callconv(.c) c_int {
            return 5;
        }
    };
    for (0..3) |case| {
        const path = try std.fmt.allocPrint(alloc, "{s}\\recovery-{d}.db", .{ base, case });
        defer alloc.free(path);
        {
            var db = try Connection.open(alloc, path, .create);
            defer db.close();
            try db.exec("CREATE TABLE sample(id INTEGER PRIMARY KEY); INSERT INTO sample VALUES(1)");
            const close_original = db.api.sqlite3_close_v2;
            test_api.original_exec = db.api.sqlite3_exec;
            defer {
                db.api.sqlite3_close_v2 = close_original;
                db.api.sqlite3_exec = test_api.original_exec;
            }
            if (case != 0) db.api.sqlite3_exec = test_api.failRollback;
            if (case == 2) db.api.sqlite3_close_v2 = test_api.failClose;
            try std.testing.expectError(error.ConstraintViolation, testWriteFailure(&db));
            try std.testing.expectEqual(@as(c_int, 19), db.last_code);
            try std.testing.expectEqual(@as(?c_int, if (case != 0) 10 else null), db.rollback_code);
            try std.testing.expectEqual(@as(?c_int, if (case == 2) 5 else null), db.recovery_close_code);
            try std.testing.expectEqual(case == 1, db.closed);
            if (case != 0) try std.testing.expectError(error.DatabaseClosedAfterRollbackFailure, db.exec("SELECT 1"));
        }
        var reopened = try Connection.open(alloc, path, .read_write);
        defer reopened.close();
        try std.testing.expectEqual(@as(i64, 1), try reopened.scalarInt("SELECT COUNT(*) FROM sample", &.{}));
        try reopened.exec("INSERT INTO sample VALUES(2)");
    }
}

pub const Statement = struct {
    connection: *Connection,
    handle: *Prepared,

    pub fn close(self: *Statement) void {
        _ = self.connection.api.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    pub fn bind(self: *Statement, values: []const Value) !void {
        const api = &self.connection.api;
        for (values, 1..) |value, index| {
            const i: c_int = @intCast(index);
            const code = switch (value) {
                .int => |x| api.sqlite3_bind_int64(self.handle, i, x),
                // SQLITE_STATIC. All callers retain the slice until step and reset/finalize.
                .text => |x| api.sqlite3_bind_text(self.handle, i, x.ptr, @intCast(x.len), null),
            };
            try self.connection.check(code);
        }
    }

    pub fn run(self: *Statement, values: []const Value) !void {
        const api = &self.connection.api;
        defer {
            _ = api.sqlite3_reset(self.handle);
            _ = api.sqlite3_clear_bindings(self.handle);
        }
        try self.bind(values);
        if (try self.next()) return error.InvalidStatement;
    }

    pub fn next(self: *Statement) !bool {
        const code = self.connection.api.sqlite3_step(self.handle);
        switch (code) {
            100 => return true,
            101 => return false,
            else => {
                try self.connection.check(code);
                return error.InvalidStatement;
            },
        }
    }

    pub fn int(self: *const Statement, column: c_int) !i64 {
        if (self.connection.api.sqlite3_column_type(self.handle, column) != 1)
            return error.InvalidDatabase;
        return self.connection.api.sqlite3_column_int64(self.handle, column);
    }

    pub fn text(self: *const Statement, column: c_int) ![]const u8 {
        const api = &self.connection.api;
        if (api.sqlite3_column_type(self.handle, column) != 3) return error.InvalidDatabase;
        const ptr = api.sqlite3_column_text(self.handle, column) orelse return error.InvalidDatabase;
        const value = ptr[0..@intCast(api.sqlite3_column_bytes(self.handle, column))];
        if (std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value))
            return error.InvalidDatabase;
        return value;
    }
};
