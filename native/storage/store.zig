const std = @import("std");
const model = @import("model.zig");
const sqlite = @import("sqlite.zig");
const registrations = @import("registration.zig");
const exchange = @import("exchange.zig");
const recovery = @import("recovery.zig");
const library = @import("library.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub const Action = model.Action;
pub const Data = model.Data;
pub const Item = model.Item;
pub const Preferences = model.Preferences;
pub const Profile = model.Profile;
pub const Registration = model.Registration;
pub const Snapshot = model.Snapshot;
pub const action_count = model.action_count;
pub const default_shortcut_keys = model.default_shortcut_keys;
pub const validatePreferences = model.validatePreferences;
pub const validate = model.validate;
pub const backupForReset = recovery.backupForReset;
pub const ResetReport = recovery.Report;
pub const LibraryHistory = library.History;
pub const ItemCommand = library.ItemCommand;
pub const ProfileCommand = library.ProfileCommand;

pub const application_id = 1_129_335_892;
pub const schema_version = 5;
pub const FailureCodes = struct {
    original: c_int,
    rollback: ?c_int,
    close: ?c_int,
};
const scope_id = model.shared_id;
const scopes_table = "CREATE TABLE scopes(id TEXT PRIMARY KEY NOT NULL CHECK(id!=''), name TEXT NOT NULL, channel TEXT UNIQUE, position INTEGER NOT NULL CHECK(typeof(position)='integer' AND position>=0), CHECK(id!='@shared' OR (name='' AND channel IS NULL AND position=0)))";
const items_table = "CREATE TABLE items(id TEXT PRIMARY KEY NOT NULL CHECK(id!=''), scope_id TEXT NOT NULL REFERENCES scopes(id) ON DELETE CASCADE, position INTEGER NOT NULL CHECK(typeof(position)='integer'), name TEXT NOT NULL, body TEXT NOT NULL, slot INTEGER CHECK(slot IS NULL OR (typeof(slot)='integer' AND slot IN(1,2))), UNIQUE(scope_id,position), UNIQUE(scope_id,slot))";
const preferences_table = "CREATE TABLE preferences(id INTEGER PRIMARY KEY CHECK(id=1), active_scope TEXT REFERENCES scopes(id) ON DELETE SET NULL CHECK(active_scope IS NULL OR active_scope!='@shared'), auto_mode INTEGER NOT NULL CHECK(typeof(auto_mode)='integer' AND auto_mode IN(0,1)), reaction_kind INTEGER NOT NULL CHECK(typeof(reaction_kind)='integer' AND reaction_kind>=1), reaction_count INTEGER NOT NULL CHECK(typeof(reaction_count)='integer' AND reaction_count>0), reaction_interval INTEGER NOT NULL CHECK(typeof(reaction_interval)='integer' AND reaction_interval>=0))";
const schema = scopes_table ++ ";\n" ++ items_table ++ ";\n" ++ preferences_table ++ ";\n" ++
    \\CREATE TABLE reaction_registrations(browser TEXT PRIMARY KEY NOT NULL CHECK(browser!=''), payload TEXT NOT NULL CHECK(json_valid(payload) AND json_type(payload)='object' AND json_type(payload,'$.browser') IS NULL));
    \\CREATE TABLE shortcut_bindings(action TEXT PRIMARY KEY NOT NULL, key TEXT NOT NULL);
    \\PRAGMA application_id=1129335892;
    \\PRAGMA user_version=5;
;

pub const Store = struct {
    allocator: Allocator,
    db: sqlite.Connection,
    path: []u8,
    connection_id: u128,
    data_version: ?i64 = null,
    configured: bool = false,
    library_cache: ?LibraryCache = null,

    /// The caller creates the parent directory and handles any explicit recovery prompt.
    pub fn open(allocator: Allocator, path: []const u8) !Store {
        try checkSize(path, true);
        var db = try sqlite.Connection.open(allocator, path, .read_write);
        errdefer db.close();
        try db.preserveWalOnClose();
        try verifyFormat(&db);
        const owned_path = try allocator.dupe(u8, path);
        return .{ .db = db, .allocator = allocator, .path = owned_path, .connection_id = std.crypto.random.int(u128) };
    }

    pub fn close(self: *Store) void {
        self.discardLibraryCache();
        self.db.close();
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn failureCodes(self: *const Store) FailureCodes {
        return .{
            .original = self.db.last_code,
            .rollback = self.db.rollback_code,
            .close = self.db.recovery_close_code,
        };
    }

    pub fn load(self: *Store, allocator: Allocator) !Snapshot {
        self.db.clearFailure();
        try self.db.exec("BEGIN");
        errdefer self.db.rollback();
        const version_before = try self.db.scalarInt("PRAGMA data_version", &.{});
        var text_bytes: usize = undefined;
        var snapshot = try readSnapshot(allocator, &self.db, &text_bytes);
        errdefer snapshot.deinit();
        const version = try self.db.scalarInt("PRAGMA data_version", &.{});
        const revision = try readLibraryRevision(&self.db, version);
        try self.db.exec("COMMIT");
        if (version_before != version) return error.DatabaseChanged;
        // Reading a bad snapshot must not convert the underlying journal mode.
        if (!self.configured) {
            try configure(self.allocator, &self.db);
            self.configured = true;
        }
        if (try self.db.scalarInt("PRAGMA data_version", &.{}) != version) return error.DatabaseChanged;
        self.data_version = version;
        snapshot.library_origin = .{ .connection = self.connection_id, .revision = revision, .text_bytes = text_bytes };
        return snapshot;
    }

    fn beginWrite(self: *Store) !void {
        self.db.clearFailure();
        // Writes always compare against a successfully validated read, even for first use.
        if (self.data_version == null) {
            var initial = try self.load(self.allocator);
            initial.deinit();
        }
        try self.db.exec("BEGIN IMMEDIATE");
        errdefer self.db.rollback();
        const current = try self.db.scalarInt("PRAGMA data_version", &.{});
        if (current != self.data_version.?) return error.DatabaseChanged;
        try verifyFormat(&self.db);
    }

    /// Writes the complete snapshot. Prefer saveLibrary and savePreferences for edits
    /// that do not own the registration state.
    pub fn save(self: *Store, data: Data) !void {
        try self.saveData(data, true);
    }

    pub fn saveLibrary(self: *Store, data: Data) !void {
        try self.saveData(data, false);
    }

    pub fn saveLibraryFromSnapshot(self: *Store, before: *const Snapshot, after: *Snapshot, text: ?library.TextEdit) !void {
        const baseline = before.library_origin;
        if (baseline) |origin| {
            if (origin.connection != self.connection_id) return error.DatabaseChanged;
        }
        try self.beginWrite();
        errdefer self.db.rollback();
        const revision = try readLibraryRevision(&self.db, self.data_version.?);
        const old_bytes = if (baseline != null and std.meta.eql(baseline.?.revision, revision))
            baseline.?.text_bytes
        else checked: {
            // A settings write can change the revision without changing the
            // library. Imports have no revision until their first library edit.
            var text_bytes: usize = undefined;
            var live = try readSnapshot(self.allocator, &self.db, &text_bytes);
            defer live.deinit();
            if (!Data.libraryEql(live.data, before.data)) return error.DatabaseChanged;
            break :checked text_bytes;
        };

        const standard_tables = try hasStandardLibraryTables(&self.db);
        if (standard_tables and text != null) {
            const origin: model.LibraryOrigin = .{ .connection = self.connection_id, .revision = revision, .text_bytes = old_bytes };
            if (try self.saveItemText(before.data, after.data, text.?, origin)) |committed| {
                after.library_origin = committed;
                return;
            }
        }

        const text_bytes = try model.validatedTextBytes(self.allocator, after.data);
        var committed: LibraryRevision = undefined;
        try self.saveDataInTransaction(after.data, false, if (standard_tables) &committed else null);
        if (standard_tables)
            after.library_origin = .{ .connection = self.connection_id, .revision = committed, .text_bytes = text_bytes };
    }

    fn saveItemText(self: *Store, before: Data, after: Data, edit: library.TextEdit, origin: model.LibraryOrigin) !?model.LibraryOrigin {
        const previous = try before.itemsFor(edit.scope);
        const updated = try after.itemsFor(edit.scope);
        if (previous.len != updated.len or edit.index >= previous.len) return null;
        const old = previous[edit.index];
        const row = updated[edit.index];
        if (!eql(u8, old.id, row.id) or old.slot != row.slot) return null;
        if (!try normalizedTextScopes(&self.db, after.preferences.input_profile_id)) return null;
        _ = try model.validatePreferences(after.preferences);

        const old_bytes = try model.itemTextBytes(old.name, old.text);
        if (old_bytes > origin.text_bytes) return error.DatabaseChanged;
        const new_bytes = origin.text_bytes - old_bytes + try model.itemTextBytes(row.name, row.text);
        if (new_bytes > model.max_text_bytes) return error.TotalTextTooLong;

        try self.db.exec("SAVEPOINT edit_item_text");
        try self.db.run(
            \\UPDATE main.items SET name=?,body=?
            \\WHERE id=? AND scope_id=? AND name=? AND body=? AND slot IS NULLIF(?,0)
        , &.{
            .{ .text = row.name }, .{ .text = row.text },
            .{ .text = old.id },   .{ .text = if (edit.scope.len == 0) scope_id else edit.scope },
            .{ .text = old.name }, .{ .text = old.text },
            .{ .int = old.slot },
        });
        const revision = try readLibraryRevision(&self.db, origin.revision.data_version);
        const writes = revision.writes - origin.revision.writes;
        if (writes == 0) return error.DatabaseChanged;
        if (writes != 1) {
            // An auxiliary foreign key can change other rows. Preserve the
            // established writer for DB5 databases with those extensions.
            try self.db.exec("ROLLBACK TO edit_item_text; RELEASE edit_item_text");
            return null;
        }
        try self.db.exec("COMMIT");
        self.discardLibraryCache();
        return .{ .connection = self.connection_id, .revision = revision, .text_bytes = new_bytes };
    }

    fn saveData(self: *Store, data: Data, replace_registrations: bool) !void {
        self.db.clearFailure();
        try model.validate(self.allocator, data);
        try self.beginWrite();
        errdefer self.db.rollback();
        try self.saveDataInTransaction(data, replace_registrations, null);
    }

    fn saveDataInTransaction(self: *Store, data: Data, replace_registrations: bool, committed: ?*LibraryRevision) !void {
        if (!replace_registrations and try self.saveUnchangedLibraryShape(data, committed)) return;
        self.discardLibraryCache();
        try writeLibrary(self.allocator, &self.db, data);
        if (replace_registrations) {
            try writePreferences(&self.db, data.preferences);
            try self.db.exec("DELETE FROM reaction_registrations");
            var browsers = std.StringHashMap(void).init(self.allocator);
            defer browsers.deinit();
            for (data.registrations) |registration| {
                if ((try browsers.getOrPut(registration.browser)).found_existing)
                    return error.DuplicateRegistration;
                try registrations.save(self.allocator, &self.db, registration.payload_json, registration.browser);
            }
        } else {
            try writeActiveScope(&self.db, data.preferences.input_profile_id);
        }
        if (committed) |out| out.* = try readLibraryRevision(&self.db, self.data_version.?);
        try self.db.exec("COMMIT");
    }

    fn discardLibraryCache(self: *Store) void {
        if (self.library_cache) |*cache| cache.arena.deinit();
        self.library_cache = null;
    }

    fn saveUnchangedLibraryShape(self: *Store, data: Data, committed_out: ?*LibraryRevision) !bool {
        const version = self.data_version.?;
        const revision = try readLibraryRevision(&self.db, version);
        if (self.library_cache == null or !std.meta.eql(self.library_cache.?.revision, revision)) {
            self.discardLibraryCache();
            self.library_cache = try LibraryCache.read(self.allocator, &self.db, revision, data);
        }
        const cache = if (self.library_cache) |*current| current else return false;
        if (cache.scopes.len != data.profiles.len + 1) return false;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var changes: std.ArrayList(ItemChange) = .empty;
        var updates: std.ArrayList(CacheUpdate) = .empty;
        if (!try cache.appendChanges(scratch, &changes, &updates, &cache.scopes[0], data.shared_items)) return false;
        for (data.profiles, cache.scopes[1..], 1..) |profile, *scope, i| {
            if (scope.rank != i or !eql(u8, scope.id, profile.id) or
                !eql(u8, scope.name, profile.name) or !eql(u8, scope.channel, profile.channel)) return false;
            if (!try cache.appendChanges(scratch, &changes, &updates, scope, profile.items)) return false;
        }

        // Prepare owned publication before any statement can commit. A large rewrite
        // may retire the cache instead of keeping its old text allocations alive.
        errdefer self.discardLibraryCache();
        const retain = try cache.ownUpdates(changes.items, updates.items);
        try upsertScopes(&self.db, data.profiles);
        try applyItemChanges(&self.db, changes.items);
        try writeActiveScope(&self.db, data.preferences.input_profile_id);
        const committed = if (retain or committed_out != null) try readLibraryRevision(&self.db, version) else undefined;
        try self.db.exec("COMMIT");
        if (committed_out) |out| out.* = committed;
        if (retain) {
            cache.publish(committed, changes.items, updates.items);
        } else {
            self.discardLibraryCache();
        }
        return true;
    }

    pub fn savePreferences(self: *Store, prefs: Preferences) !void {
        self.db.clearFailure();
        _ = try model.validatePreferences(prefs);
        try self.beginWrite();
        errdefer self.db.rollback();
        try writePreferences(&self.db, prefs);
        try self.db.exec("COMMIT");
    }

    pub fn saveRegistration(self: *Store, payload_json: []const u8) !void {
        try self.beginWrite();
        errdefer self.db.rollback();
        try registrations.save(self.allocator, &self.db, payload_json, null);
        try self.db.exec("COMMIT");
    }

    pub fn hasReactionRegistration(self: *const Store, browser: []const u8) !bool {
        try checkSize(self.path, false);
        var reader = try sqlite.Connection.open(self.allocator, self.path, .read_only);
        defer reader.close();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        for (try registrations.read(arena.allocator(), &reader)) |entry| {
            if (std.mem.eql(u8, entry.browser, browser)) return true;
        }
        return false;
    }

    pub fn loadRegistrationSnapshot(self: *Store, allocator: Allocator) ![]u8 {
        self.db.clearFailure();
        // Validate before publication to the worker, including extension fields.
        try self.db.exec("BEGIN");
        errdefer self.db.rollback();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = try registrations.read(arena.allocator(), &self.db);
        const json = try self.db.scalarText(allocator,
            \\SELECT json_object('version',1,'profiles',json_group_array(json_set(payload,'$.browser',browser)))
            \\FROM reaction_registrations
        , &.{});
        errdefer allocator.free(json);
        try self.db.exec("COMMIT");
        return json;
    }

    pub fn exportJson(self: *Store, destination: []const u8) !void {
        self.db.clearFailure();
        // Use a read-only connection that cannot alter the source as part of export.
        try checkSize(self.path, false);
        var reader = try sqlite.Connection.open(self.allocator, self.path, .read_only);
        defer reader.close();
        try reader.exec("BEGIN");
        errdefer reader.rollback();
        try reader.checkIntegrity();
        var current = try readSnapshot(self.allocator, &reader, null);
        defer current.deinit();
        try reader.exec("COMMIT");
        try writeVerifiedJson(self.allocator, current.data, destination);
    }

    /// Call before changing native shortcut bindings. The subsequent save rechecks
    /// the revision in case another connection commits after this backup.
    pub fn createImportBackup(self: *Store, destination: []const u8) !void {
        try self.beginWrite();
        errdefer self.db.rollback();
        try self.db.checkIntegrity();
        var current = try readSnapshot(self.allocator, &self.db, null);
        defer current.deinit();
        try writeVerifiedJson(self.allocator, current.data, destination);
        try self.db.exec("COMMIT");
    }

    pub fn replaceFromBackup(self: *Store, data: Data, backup_destination: []const u8) !void {
        try self.createImportBackup(backup_destination);
        try self.save(data);
    }
};

fn checkSize(path: []const u8, create: bool) !void {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => if (create) return createDatabase(path) else return err,
        else => return err,
    };
    if (stat.kind != .file or stat.size == 0) return error.InvalidDatabase;
    if (stat.size > model.max_file_bytes) return error.DatabaseTooLarge;
}

fn verifyFormat(db: *sqlite.Connection) !void {
    if (try db.scalarInt("PRAGMA application_id", &.{}) != application_id)
        return error.WrongApplication;
    if (try db.scalarInt("PRAGMA user_version", &.{}) != schema_version)
        return error.UnsupportedDatabaseVersion;
}

fn configure(allocator: Allocator, db: *sqlite.Connection) !void {
    var mode = try db.prepare("PRAGMA journal_mode=DELETE");
    defer mode.close();
    if (!try mode.next() or !eql(u8, try mode.text(0), "delete") or try mode.next())
        return error.UnsafeJournalMode;
    try db.exec("PRAGMA synchronous=EXTRA; PRAGMA foreign_keys=ON");
    if (try db.scalarInt("PRAGMA synchronous", &.{}) != 3 or try db.scalarInt("PRAGMA foreign_keys", &.{}) != 1)
        return error.UnsafeSqliteOptions;
    try limitPages(allocator, db);
}

fn limitPages(allocator: Allocator, db: *sqlite.Connection) !void {
    const page_size = try db.scalarInt("PRAGMA page_size", &.{});
    if (page_size <= 0 or page_size > model.max_file_bytes) return error.InvalidDatabase;
    const maximum = @divFloor(model.max_file_bytes, page_size);
    const command = try std.fmt.allocPrintSentinel(allocator, "PRAGMA max_page_count={d}", .{maximum}, 0);
    defer allocator.free(command);
    if (try db.scalarInt(command, &.{}) != maximum) return error.DatabaseTooLarge;
}

fn reserveTemporary(allocator: Allocator, path: []const u8) ![]u8 {
    var nonce: [16]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.creating-{x}", .{ path, &nonce });
    errdefer allocator.free(temporary);
    const file = try std.fs.cwd().createFile(temporary, .{ .exclusive = true });
    file.close();
    return temporary;
}

fn createDatabase(path: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const temporary = try reserveTemporary(allocator, path);
    defer allocator.free(temporary);
    defer std.fs.cwd().deleteFile(temporary) catch {};
    const journal = try std.fmt.allocPrint(allocator, "{s}-journal", .{temporary});
    defer allocator.free(journal);
    defer std.fs.cwd().deleteFile(journal) catch {};
    {
        var db = try sqlite.Connection.open(allocator, temporary, .create);
        defer db.close();
        try configure(allocator, &db);
        try initialize(&db);
        try db.checkIntegrity();
        var check = try readSnapshot(allocator, &db, null);
        defer check.deinit();
        if (check.data.profiles.len != 0 or check.data.shared_items.len != 0 or check.data.registrations.len != 0)
            return error.InvalidDatabase;
    }
    // WRITE_THROUGH, without REPLACE_EXISTING. A concurrent initializer retains its database.
    try std.os.windows.MoveFileEx(temporary, path, 8);
}

fn initialize(db: *sqlite.Connection) !void {
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.rollback();
    try db.exec(schema);
    try db.exec("INSERT INTO scopes VALUES('@shared','',NULL,0); INSERT INTO preferences VALUES(1,NULL,1,1,1,200)");
    var binding = try db.prepare("INSERT INTO shortcut_bindings VALUES(?,?)");
    defer binding.close();
    for (std.enums.values(Action), default_shortcut_keys) |action, key|
        try binding.run(&.{ .{ .text = @tagName(action) }, .{ .text = key } });
    try db.exec("COMMIT");
}

pub fn readJson(allocator: Allocator, path: []const u8) !Snapshot {
    var from_file = try exchange.readFile(allocator, path);
    defer from_file.deinit();
    var db = try sqlite.Connection.open(allocator, ":memory:", .create);
    defer db.close();
    try db.exec("PRAGMA foreign_keys=ON");
    try limitPages(allocator, &db);
    try initialize(&db);
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.rollback();
    try writeLibrary(allocator, &db, from_file.data);
    try writePreferences(&db, from_file.data.preferences);
    for (from_file.data.registrations) |registration_value|
        try registrations.save(allocator, &db, registration_value.payload_json, registration_value.browser);
    try db.exec("COMMIT");
    try db.checkIntegrity();
    return readSnapshot(allocator, &db, null);
}

fn writeVerifiedJson(allocator: Allocator, data: Data, destination: []const u8) !void {
    if (std.fs.cwd().statFile(destination)) |_| {
        return error.PathAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const bytes = try exchange.write(allocator, data);
    defer allocator.free(bytes);
    const temporary = try reserveTemporary(allocator, destination);
    defer allocator.free(temporary);
    defer std.fs.cwd().deleteFile(temporary) catch {};
    {
        const file = try std.fs.cwd().openFile(temporary, .{ .mode = .write_only });
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }
    var check = try readJson(allocator, temporary);
    defer check.deinit();
    if (!Data.eql(data, check.data)) return error.BackupVerificationFailed;
    try std.os.windows.MoveFileEx(temporary, destination, 8);
}

fn readSnapshot(allocator: Allocator, db: *sqlite.Connection, text_bytes: ?*usize) !Snapshot {
    try verifyFormat(db);
    const scope_count = try db.scalarInt("SELECT COUNT(*) FROM scopes", &.{});
    const item_count = try db.scalarInt("SELECT COUNT(*) FROM items", &.{});
    if (scope_count < 1 or scope_count > model.max_profiles + 1) return error.InvalidProfileCount;
    if (item_count < 0 or item_count > model.max_items) return error.TooManyItems;

    var snapshot = Snapshot.init(allocator);
    errdefer snapshot.deinit();
    const owned = snapshot.arena.allocator();
    const profiles = try owned.alloc(Profile, @intCast(scope_count - 1));
    const items = try owned.alloc(Item, @intCast(item_count));
    var index = std.StringHashMap(usize).init(allocator);
    defer index.deinit();

    var scopes = try db.prepare("SELECT id,name,COALESCE(channel,''),position FROM scopes ORDER BY position,id");
    defer scopes.close();
    var seen_shared = false;
    var profile_count: usize = 0;
    while (try scopes.next()) {
        const id = try scopes.text(0);
        const name = try scopes.text(1);
        const channel = try scopes.text(2);
        const position = try scopes.int(3);
        if (eql(u8, id, scope_id)) {
            if (seen_shared or name.len != 0 or channel.len != 0 or position != 0)
                return error.InvalidSharedScope;
            seen_shared = true;
            try index.put(scope_id, profiles.len);
            continue;
        }
        if (profile_count == profiles.len or position < 0) return error.InvalidDatabase;
        const profile = &profiles[profile_count];
        profile.* = .{
            .id = try owned.dupe(u8, id),
            .name = try owned.dupe(u8, name),
            .channel = try owned.dupe(u8, channel),
        };
        try index.put(profile.id, profile_count);
        profile_count += 1;
    }
    if (!seen_shared or profile_count != profiles.len) return error.InvalidSharedScope;
    snapshot.data.profiles = profiles;

    var rows = try db.prepare("SELECT id,scope_id,position,name,body,COALESCE(slot,0) FROM items ORDER BY scope_id,position");
    defer rows.close();
    var prior_scope: ?usize = null;
    var position: i64 = 0;
    var first: usize = 0;
    var count: usize = 0;
    while (try rows.next()) {
        if (count == items.len) return error.InvalidDatabase;
        const group = index.get(try rows.text(1)) orelse return error.ProfileMissing;
        if (prior_scope == null or group != prior_scope.?) {
            if (prior_scope) |previous| assignReadItems(&snapshot, profiles, previous, items[first..count]);
            first = count;
            prior_scope = group;
            position = 0;
        }
        const rank = try rows.int(2);
        if (rank <= position) return error.InvalidItemOrder;
        position = rank;
        const slot = std.math.cast(u8, try rows.int(5)) orelse return error.InvalidSlot;
        items[count] = .{
            .id = try owned.dupe(u8, try rows.text(0)),
            .name = try owned.dupe(u8, try rows.text(3)),
            .text = try owned.dupe(u8, try rows.text(4)),
            .slot = slot,
        };
        count += 1;
    }
    if (count != items.len) return error.InvalidDatabase;
    if (prior_scope) |previous| assignReadItems(&snapshot, profiles, previous, items[first..count]);
    snapshot.data.preferences = try readPreferences(owned, db);
    const bytes = try model.validatedTextBytes(allocator, snapshot.data);
    snapshot.data.registrations = try registrations.read(owned, db);
    if (text_bytes) |out| out.* = bytes;
    return snapshot;
}

fn assignReadItems(snapshot: *Snapshot, profiles: []Profile, index: usize, items: []Item) void {
    if (index == profiles.len) snapshot.data.shared_items = items else profiles[index].items = items;
}

fn readPreferences(allocator: Allocator, db: *sqlite.Connection) !Preferences {
    var row = try db.prepare("SELECT id,COALESCE(active_scope,''),auto_mode,reaction_kind,reaction_count,reaction_interval FROM preferences");
    defer row.close();
    if (!try row.next() or try row.int(0) != 1) return error.InvalidPreferences;
    const auto = try row.int(2);
    if (auto != 0 and auto != 1) return error.InvalidPreferences;
    var result: Preferences = .{
        .input_profile_id = try allocator.dupe(u8, try row.text(1)),
        .auto_mode = auto == 1,
        .reaction_kind = std.math.cast(u8, try row.int(3)) orelse return error.InvalidPreferences,
        .reaction_count = std.math.cast(u32, try row.int(4)) orelse return error.InvalidPreferences,
        .reaction_interval_ms = std.math.cast(u32, try row.int(5)) orelse return error.InvalidPreferences,
    };
    if (try row.next()) return error.InvalidPreferences;

    var binding = try db.prepare("SELECT action,key FROM shortcut_bindings");
    defer binding.close();
    var seen: std.StaticBitSet(action_count) = .initEmpty();
    while (try binding.next()) {
        const name = try binding.text(0);
        const action = std.meta.stringToEnum(Action, name) orelse return error.InvalidShortcut;
        const i = @intFromEnum(action);
        if (seen.isSet(i)) return error.DuplicateShortcut;
        seen.set(i);
        result.shortcut_keys[i] = try allocator.dupe(u8, try binding.text(1));
    }
    if (seen.count() != action_count) return error.RequiredShortcut;
    return result;
}

fn writePreferences(db: *sqlite.Connection, prefs: Preferences) !void {
    if (prefs.input_profile_id.len > 0 and (eql(u8, prefs.input_profile_id, scope_id) or
        try db.scalarInt("SELECT EXISTS(SELECT 1 FROM scopes WHERE id=?)", &.{.{ .text = prefs.input_profile_id }}) != 1))
        return error.ProfileMissing;
    try db.run(
        \\INSERT INTO preferences VALUES(1,NULLIF(?,''),?,?,?,?) ON CONFLICT(id) DO UPDATE SET
        \\active_scope=excluded.active_scope,auto_mode=excluded.auto_mode,reaction_kind=excluded.reaction_kind,
        \\reaction_count=excluded.reaction_count,reaction_interval=excluded.reaction_interval
        \\WHERE active_scope IS NOT excluded.active_scope OR auto_mode IS NOT excluded.auto_mode
        \\OR reaction_kind IS NOT excluded.reaction_kind OR reaction_count IS NOT excluded.reaction_count
        \\OR reaction_interval IS NOT excluded.reaction_interval
    , &.{
        .{ .text = prefs.input_profile_id },    .{ .int = @intFromBool(prefs.auto_mode) },
        .{ .int = prefs.reaction_kind },        .{ .int = prefs.reaction_count },
        .{ .int = prefs.reaction_interval_ms },
    });
    var write = try db.prepare("UPDATE shortcut_bindings SET key=?1 WHERE action=?2 AND key IS NOT ?1");
    defer write.close();
    for (std.enums.values(Action), prefs.shortcut_keys) |action, key|
        try write.run(&.{ .{ .text = key }, .{ .text = @tagName(action) } });
}

const SavedItem = struct {
    item: Item,
    scope_id: []const u8,
    rank: i64,
};

const SavedScope = struct {
    id: []const u8,
    channel: []const u8,
};

const ItemChange = struct {
    item: Item,
    scope_id: []const u8,
    rank: i64,
    must_stage: bool,
};

const LibraryRevision = model.LibraryRevision;

fn readLibraryRevision(db: *sqlite.Connection, version: i64) !LibraryRevision {
    // data_version sees external commits and total_changes sees this connection's
    // writes (including writes later rolled back). DDL also has its own revision.
    return .{
        .data_version = version,
        .writes = try db.scalarInt("SELECT total_changes()", &.{}),
        .schema = try db.scalarInt("PRAGMA main.schema_version", &.{}),
        .temp_schema = try db.scalarInt("PRAGMA temp.schema_version", &.{}),
    };
}

fn localLibraryWritesSafe(db: *sqlite.Connection) !bool {
    // Triggers can modify other rows and temporary objects can shadow tables.
    return try db.scalarInt(
        \\SELECT EXISTS(SELECT 1 FROM main.sqlite_master WHERE type='trigger'
        \\              UNION ALL SELECT 1 FROM temp.sqlite_master)
    , &.{}) == 0;
}

fn hasStandardLibraryTables(db: *sqlite.Connection) !bool {
    if (!try localLibraryWritesSafe(db)) return false;
    return try db.scalarInt(
        \\SELECT COUNT(*) FROM main.sqlite_master WHERE type='table'
        \\AND ((name='scopes' AND sql=?1) OR (name='items' AND sql=?2)
        \\     OR (name='preferences' AND sql=?3))
    , &.{ .{ .text = scopes_table }, .{ .text = items_table }, .{ .text = preferences_table } }) == 3;
}

fn normalizedTextScopes(db: *sqlite.Connection, active_scope: []const u8) !bool {
    // The full writer normalizes the ranks and empty channels of scopes.
    return try db.scalarInt(
        \\SELECT NOT EXISTS(SELECT 1 FROM main.scopes WHERE channel='')
        \\AND (SELECT COUNT(*)=COUNT(DISTINCT position) AND MAX(position)=COUNT(*)-1 FROM main.scopes)
        \\AND (SELECT active_scope IS NULLIF(?,'') FROM main.preferences WHERE id=1)
    , &.{.{ .text = active_scope }}) == 1;
}

const CachedPosition = struct {
    rank: i64,
    row: *SavedItem,
};

const CachedScope = struct {
    id: []const u8,
    name: []const u8,
    channel: []const u8,
    rank: i64,
    positions: []CachedPosition,
};

const CacheUpdate = struct {
    position: *CachedPosition,
    row: *SavedItem,
};

const LibraryCache = struct {
    const max_replacement_bytes = 4 * 1024 * 1024;

    arena: std.heap.ArenaAllocator,
    revision: LibraryRevision,
    scopes: []CachedScope,
    by_id: std.StringHashMapUnmanaged(*SavedItem) = .empty,
    replacement_bytes: usize = 0,

    fn read(allocator: Allocator, db: *sqlite.Connection, revision: LibraryRevision, data: Data) !?LibraryCache {
        if (!try localLibraryWritesSafe(db)) return null;
        var cache: LibraryCache = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .scopes = undefined,
            .revision = revision,
        };
        var keep = false;
        defer if (!keep) cache.arena.deinit();
        const owned = cache.arena.allocator();
        const scopes = try owned.alloc(CachedScope, data.profiles.len + 1);
        var by_scope: std.StringHashMapUnmanaged(usize) = .empty;
        var scratch_arena = std.heap.ArenaAllocator.init(allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();
        const counts = try scratch.alloc(usize, scopes.len);
        @memset(counts, 0);

        var prior_scopes = try db.prepare(
            \\SELECT id,name,COALESCE(channel,''),position,channel IS NULL,
            \\       (SELECT COUNT(*) FROM items WHERE scope_id=scopes.id)
            \\FROM scopes ORDER BY position,id
        );
        defer prior_scopes.close();
        var row_count: usize = 0;
        for (scopes, 0..) |*scope, i| {
            if (!try prior_scopes.next()) return null;
            const profile: Profile = if (i == 0)
                .{ .id = scope_id, .name = "", .items = data.shared_items }
            else
                data.profiles[i - 1];
            const id = try prior_scopes.text(0);
            const name = try prior_scopes.text(1);
            const channel = try prior_scopes.text(2);
            const rank = try prior_scopes.int(3);
            if (rank != i or !eql(u8, id, profile.id) or !eql(u8, name, profile.name) or
                !eql(u8, channel, profile.channel) or (try prior_scopes.int(4) == 1) != (profile.channel.len == 0) or
                try prior_scopes.int(5) != profile.items.len) return null;
            scope.* = .{
                .id = try owned.dupe(u8, id),
                .name = try owned.dupe(u8, name),
                .channel = try owned.dupe(u8, channel),
                .rank = rank,
                .positions = try owned.alloc(CachedPosition, profile.items.len),
            };
            row_count += profile.items.len;
            try by_scope.put(scratch, scope.id, i);
        }
        if (try prior_scopes.next()) return null;
        cache.scopes = scopes;

        const rows = try owned.alloc(SavedItem, row_count);
        try cache.by_id.ensureTotalCapacity(owned, @intCast(row_count));
        var prior = try db.prepare("SELECT id,scope_id,position,name,body,COALESCE(slot,0) FROM items ORDER BY scope_id,position");
        defer prior.close();
        for (rows) |*row| {
            if (!try prior.next()) return null;
            const group = by_scope.get(try prior.text(1)) orelse return null;
            const scope = &scopes[group];
            const i = counts[group];
            if (i == scope.positions.len) return null;
            const rank = try prior.int(2);
            if (rank <= (if (i == 0) 0 else scope.positions[i - 1].rank)) return null;
            row.* = .{
                .scope_id = scope.id,
                .rank = rank,
                .item = .{
                    .id = try owned.dupe(u8, try prior.text(0)),
                    .name = try owned.dupe(u8, try prior.text(3)),
                    .text = try owned.dupe(u8, try prior.text(4)),
                    .slot = std.math.cast(u8, try prior.int(5)) orelse return null,
                },
            };
            cache.by_id.putAssumeCapacity(row.item.id, row);
            scope.positions[i] = .{ .rank = rank, .row = row };
            counts[group] += 1;
        }
        if (try prior.next()) return null;
        keep = true;
        return cache;
    }

    fn appendChanges(
        self: *const LibraryCache,
        scratch: Allocator,
        changes: *std.ArrayList(ItemChange),
        updates: *std.ArrayList(CacheUpdate),
        scope: *const CachedScope,
        items: []const Item,
    ) !bool {
        if (items.len != scope.positions.len) return false;
        for (items, scope.positions) |item, *position| {
            const row = if (eql(u8, item.id, position.row.item.id)) position.row else self.by_id.get(item.id) orelse return false;
            if (!eql(u8, scope.id, row.scope_id)) return false;
            const stage = row.rank != position.rank or row.item.slot != item.slot;
            if (!stage and eql(u8, row.item.name, item.name) and eql(u8, row.item.text, item.text)) continue;
            try changes.append(scratch, .{
                .item = item,
                .scope_id = scope.id,
                .rank = position.rank,
                .must_stage = stage,
            });
            try updates.append(scratch, .{ .position = position, .row = row });
        }
        return true;
    }

    fn ownUpdates(self: *LibraryCache, changes: []ItemChange, updates: []const CacheUpdate) !bool {
        var added: usize = 0;
        for (changes, updates) |change, update| {
            if (!eql(u8, change.item.name, update.row.item.name)) added += change.item.name.len;
            if (!eql(u8, change.item.text, update.row.item.text)) added += change.item.text.len;
        }
        if (added > max_replacement_bytes - self.replacement_bytes) return false;
        self.replacement_bytes += added;
        const owned = self.arena.allocator();
        for (changes, updates) |*change, update| {
            const prior = update.row.item;
            change.item.id = prior.id;
            change.item.name = if (eql(u8, change.item.name, prior.name)) prior.name else try owned.dupe(u8, change.item.name);
            change.item.text = if (eql(u8, change.item.text, prior.text)) prior.text else try owned.dupe(u8, change.item.text);
        }
        return true;
    }

    fn publish(self: *LibraryCache, revision: LibraryRevision, changes: []const ItemChange, updates: []const CacheUpdate) void {
        for (changes, updates) |change, update| {
            update.row.item = change.item;
            update.row.rank = change.rank;
            update.position.row = update.row;
        }
        self.revision = revision;
    }
};

fn writeActiveScope(db: *sqlite.Connection, selected: []const u8) !void {
    // Editing a library owns the active scope without changing common preferences.
    try db.run("UPDATE preferences SET active_scope=NULLIF(?1,'') WHERE id=1 AND active_scope IS NOT NULLIF(?1,'')", &.{.{ .text = selected }});
}

fn writeLibrary(allocator: Allocator, db: *sqlite.Connection, data: Data) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var persisted: std.StringHashMapUnmanaged(SavedItem) = .empty;
    var scopes: std.ArrayList(SavedScope) = .empty;
    {
        var old = try db.prepare("SELECT id,scope_id,position,name,body,COALESCE(slot,0) FROM items");
        defer old.close();
        while (try old.next()) {
            const id = try scratch.dupe(u8, try old.text(0));
            const slot = std.math.cast(u8, try old.int(5)) orelse return error.InvalidSlot;
            try persisted.put(scratch, id, .{
                .item = .{
                    .id = id,
                    .name = try scratch.dupe(u8, try old.text(3)),
                    .text = try scratch.dupe(u8, try old.text(4)),
                    .slot = slot,
                },
                .scope_id = try scratch.dupe(u8, try old.text(1)),
                .rank = try old.int(2),
            });
        }
        var prior_scopes = try db.prepare("SELECT id,COALESCE(channel,'') FROM scopes");
        defer prior_scopes.close();
        while (try prior_scopes.next()) try scopes.append(scratch, .{
            .id = try scratch.dupe(u8, try prior_scopes.text(0)),
            .channel = try scratch.dupe(u8, try prior_scopes.text(1)),
        });
    }

    var desired_scopes: std.StringHashMapUnmanaged(Profile) = .empty;
    for (data.profiles) |profile| try desired_scopes.put(scratch, profile.id, profile);
    {
        // Release old channel values before an exchange of two UNIQUE bindings.
        var release = try db.prepare("UPDATE scopes SET channel=NULL WHERE id=?");
        defer release.close();
        for (scopes.items) |prior| {
            const desired = if (desired_scopes.get(prior.id)) |profile| profile.channel else "";
            if (prior.channel.len != 0 and !eql(u8, desired, prior.channel))
                try release.run(&.{.{ .text = prior.id }});
        }
    }
    try upsertScopes(db, data.profiles);

    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    var delta: std.ArrayList(ItemChange) = .empty;
    try appendItemChanges(scratch, &persisted, &wanted, &delta, scope_id, data.shared_items);
    for (data.profiles) |profile|
        try appendItemChanges(scratch, &persisted, &wanted, &delta, profile.id, profile.items);

    var delete_item = try db.prepare("DELETE FROM items WHERE id=?");
    defer delete_item.close();
    var prior_items = persisted.keyIterator();
    while (prior_items.next()) |id| {
        if (!wanted.contains(id.*)) try delete_item.run(&.{.{ .text = id.* }});
    }

    try applyItemChanges(db, delta.items);

    var delete_scope = try db.prepare("DELETE FROM scopes WHERE id=?");
    defer delete_scope.close();
    for (scopes.items) |prior| {
        if (!eql(u8, prior.id, scope_id) and !desired_scopes.contains(prior.id))
            try delete_scope.run(&.{.{ .text = prior.id }});
    }
}

fn upsertScopes(db: *sqlite.Connection, profiles: []const Profile) !void {
    var write = try db.prepare(
        \\INSERT INTO scopes VALUES(?,?,NULLIF(?,''),?) ON CONFLICT(id) DO UPDATE SET
        \\name=excluded.name,channel=excluded.channel,position=excluded.position
        \\WHERE name IS NOT excluded.name OR channel IS NOT excluded.channel OR position IS NOT excluded.position
    );
    defer write.close();
    try write.run(&.{ .{ .text = scope_id }, .{ .text = "" }, .{ .text = "" }, .{ .int = 0 } });
    for (profiles, 1..) |profile, i|
        try write.run(&.{
            .{ .text = profile.id },      .{ .text = profile.name },
            .{ .text = profile.channel }, .{ .int = @intCast(i) },
        });
}

fn applyItemChanges(db: *sqlite.Connection, changes: []const ItemChange) !void {
    var stage = try db.prepare("UPDATE items SET position=?,slot=NULL WHERE id=?");
    defer stage.close();
    for (changes, 1..) |change, i| {
        if (change.must_stage)
            try stage.run(&.{ .{ .int = -@as(i64, @intCast(i)) }, .{ .text = change.item.id } });
    }
    var write = try db.prepare(
        \\INSERT INTO items VALUES(?,?,?,?,?,NULLIF(?,0))
        \\ON CONFLICT(id) DO UPDATE SET scope_id=excluded.scope_id,position=excluded.position,name=excluded.name,body=excluded.body,slot=excluded.slot
    );
    defer write.close();
    for (changes) |change| try write.run(&.{
        .{ .text = change.item.id },   .{ .text = change.scope_id },  .{ .int = change.rank },
        .{ .text = change.item.name }, .{ .text = change.item.text }, .{ .int = change.item.slot },
    });
}

fn appendItemChanges(
    allocator: Allocator,
    persisted: *const std.StringHashMapUnmanaged(SavedItem),
    wanted: *std.StringHashMapUnmanaged(void),
    changes: *std.ArrayList(ItemChange),
    target: []const u8,
    items: []const Item,
) !void {
    if (items.len == 0) return;
    const ranks = try allocator.alloc(i64, items.len);
    const known = try allocator.alloc(i64, items.len);
    var known_count: usize = 0;
    var ordered = true;
    var last: i64 = 0;
    for (items, ranks) |item, *rank| {
        try wanted.put(allocator, item.id, {});
        const previous = persisted.get(item.id);
        rank.* = if (previous != null and eql(u8, previous.?.scope_id, target)) previous.?.rank else 0;
        if (rank.* != 0) {
            ordered = ordered and rank.* > last;
            last = rank.*;
            known[known_count] = rank.*;
            known_count += 1;
        }
    }
    if (!ordered) std.mem.sort(i64, known[0..known_count], {}, std.sort.asc(i64));
    var next: usize = 0;
    last = 0;
    for (ranks) |*rank| {
        if (rank.* != 0) {
            rank.* = known[next];
            next += 1;
        } else {
            const before = if (next < known_count) known[next] else std.math.maxInt(i64);
            rank.* = if (next < known_count) last + @divFloor(before - last, 2) else last +| 1024;
            if (rank.* <= last) {
                for (ranks, 1..) |*entry, i| entry.* = @as(i64, @intCast(i)) * 1024;
                break;
            }
        }
        last = rank.*;
    }

    for (items, ranks) |item, rank| {
        const previous = persisted.get(item.id);
        const stage = if (previous) |old|
            old.rank != rank or old.item.slot != item.slot or !eql(u8, target, old.scope_id)
        else
            false;
        if (previous) |old| {
            if (!stage and eql(u8, old.item.name, item.name) and eql(u8, old.item.text, item.text)) continue;
        }
        try changes.append(allocator, .{ .item = item, .scope_id = target, .rank = rank, .must_stage = stage });
    }
}

test "DB5 opens, preserves exact ranks, handles swaps and detects independent updates" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    var first = try Store.open(alloc, path);
    defer first.close();
    var defaults = try first.load(alloc);
    defer defaults.deinit();
    try std.testing.expect(defaults.data.preferences.auto_mode);
    try std.testing.expectEqual(@as(usize, 0), defaults.data.profiles.len);
    const a: Item = .{ .id = "A", .name = "多言語👏", .text = "full", .slot = 1 };
    const b: Item = .{ .id = "a", .name = "two", .text = "second", .slot = 2 };
    try first.saveLibrary(.{ .shared_items = &.{ a, b } });
    try first.db.exec("UPDATE items SET position=9007199254740993 WHERE id='A'; UPDATE items SET position=9007199254740994 WHERE id='a'");
    var prior = try first.load(alloc);
    defer prior.deinit();
    const changes = try first.db.scalarInt("SELECT total_changes()", &.{});
    try first.saveLibrary(prior.data);
    try std.testing.expectEqual(changes, try first.db.scalarInt("SELECT total_changes()", &.{}));
    try std.testing.expectEqual(@as(i64, 9007199254740993), try first.db.scalarInt("SELECT position FROM items WHERE id='A'", &.{}));

    var second = try Store.open(alloc, path);
    defer second.close();
    var baseline = try second.load(alloc);
    defer baseline.deinit();
    var updated = b;
    updated.slot = 0;
    try first.saveLibrary(.{ .profiles = &.{.{ .id = "P", .name = "配信者", .items = &.{updated} }}, .shared_items = &.{a} });
    try std.testing.expectError(error.DatabaseChanged, second.saveLibrary(baseline.data));
    var published = try first.load(alloc);
    defer published.deinit();
    try std.testing.expectEqualStrings("a", published.data.profiles[0].items[0].id);
    try std.testing.expectEqualStrings("多言語👏", published.data.shared_items[0].name);
}

test "library cache follows actual SQLite writes, owns edits and publishes only after commit" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    var store = try Store.open(alloc, path);
    defer store.close();

    var values = [_]Item{
        .{ .id = "A", .name = "one", .text = "first", .slot = 1 },
        .{ .id = "B", .name = "two", .text = "second", .slot = 2 },
    };
    const desired: Data = .{ .shared_items = &values };
    try store.saveLibrary(desired);
    try store.saveLibrary(desired);
    try std.testing.expect(store.library_cache != null);

    var body: [4]u8 = "edit".*;
    values[0].text = &body;
    try store.saveLibrary(desired);
    body = "next".*;
    try store.saveLibrary(desired);
    var owned_readback = try store.load(alloc);
    defer owned_readback.deinit();
    try std.testing.expect(Data.eql(desired, owned_readback.data));

    try store.db.exec(
        "UPDATE items SET body='outside',position=9007199254740993 WHERE id='A';" ++
            "UPDATE items SET position=9007199254740994 WHERE id='B'",
    );
    std.mem.swap(Item, &values[0], &values[1]);
    std.mem.swap(u8, &values[0].slot, &values[1].slot);
    try store.saveLibrary(desired);
    try std.testing.expectEqual(@as(i64, 9007199254740993), try store.db.scalarInt("SELECT position FROM items WHERE id='B'", &.{}));
    var swapped = try store.load(alloc);
    defer swapped.deinit();
    try std.testing.expect(Data.eql(desired, swapped.data));

    try store.db.exec("CREATE TEMP TRIGGER reject_cached_scope BEFORE INSERT ON main.scopes BEGIN SELECT RAISE(ABORT,'injected'); END");
    try std.testing.expectError(error.ConstraintViolation, store.saveLibrary(desired));
    try std.testing.expect(store.library_cache == null);
    try store.db.exec("DROP TRIGGER reject_cached_scope; PRAGMA busy_timeout=0");
    try store.saveLibrary(desired);
    try std.testing.expect(store.library_cache != null);

    var separate = try sqlite.Connection.open(alloc, path, .read_write);
    defer separate.close();
    try separate.exec("BEGIN");
    _ = try separate.scalarInt("SELECT COUNT(*) FROM items", &.{});
    body = "lock".*;
    try std.testing.expectError(error.DatabaseLocked, store.saveLibrary(desired));
    try std.testing.expect(store.library_cache == null);
    try separate.exec("ROLLBACK");
    var recovered = try store.load(alloc);
    defer recovered.deinit();
    try std.testing.expect(Data.eql(swapped.data, recovered.data));

    body = "next".*;
    try store.saveLibrary(desired);
    try std.testing.expect(store.library_cache != null);
    try separate.exec("UPDATE items SET body='other connection' WHERE id='A'");
    try std.testing.expectError(error.DatabaseChanged, store.saveLibrary(desired));
    var external = try store.load(alloc);
    defer external.deinit();
    try std.testing.expectEqualStrings("other connection", external.data.shared_items[1].text);
    try store.saveLibrary(desired);
    var restored = try store.load(alloc);
    defer restored.deinit();
    try std.testing.expect(Data.eql(desired, restored.data));
}

const sample_registration =
    \\{"browser":"edge","tokens":[{"name":"👏","id":"one","class":"button","type":50000,"extra":1.2500},{"name":"a","id":"two","class":"button","type":50000},{"name":"b","id":"three","class":"button","type":50000},{"name":"c","id":"four","class":"button","type":50000},{"name":"d","id":"five","class":"button","type":50000}],"extra":{"flag":true}}
;

test "JSON2 backup and replacement preserve selected profile, ranks, and registration extension fields" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const db_path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(db_path);
    const exported = try std.fs.path.join(alloc, &.{ parent, "export.json" });
    defer alloc.free(exported);
    const backup = try std.fs.path.join(alloc, &.{ parent, "before.json" });
    defer alloc.free(backup);
    var store = try Store.open(alloc, db_path);
    defer store.close();
    const old: Data = .{
        .preferences = .{ .input_profile_id = "Caster", .auto_mode = false, .reaction_interval_ms = 250 },
        .profiles = &.{.{
            .id = "Caster",
            .name = "配信者",
            .channel = "/@名前",
            .items = &.{.{ .id = "Id", .name = "表示", .text = "👏", .slot = 2 }},
        }},
        .shared_items = &.{.{ .id = "id", .name = "共通", .text = "😀", .slot = 1 }},
    };
    try store.save(old);
    try store.saveRegistration(sample_registration);
    const worker = try store.loadRegistrationSnapshot(alloc);
    defer alloc.free(worker);
    try std.testing.expect(std.mem.indexOf(u8, worker, "\"extra\":1.2500") != null);
    var before = try store.load(alloc);
    defer before.deinit();
    try store.exportJson(exported);
    try std.testing.expectError(error.PathAlreadyExists, store.exportJson(exported));
    var roundtrip = try readJson(alloc, exported);
    defer roundtrip.deinit();
    try std.testing.expect(Data.eql(before.data, roundtrip.data));
    const missing_parent = try std.fs.path.join(alloc, &.{ parent, "missing", "before.json" });
    defer alloc.free(missing_parent);
    try std.testing.expectError(error.FileNotFound, store.replaceFromBackup(.{}, missing_parent));
    var preserved = try store.load(alloc);
    defer preserved.deinit();
    try std.testing.expect(Data.eql(before.data, preserved.data));

    var other = try sqlite.Connection.open(alloc, db_path, .read_write);
    defer other.close();
    const conflict = try std.fs.path.join(alloc, &.{ parent, "conflict.json" });
    defer alloc.free(conflict);
    try other.exec("UPDATE preferences SET reaction_count=10");
    try std.testing.expectError(error.DatabaseChanged, store.replaceFromBackup(.{}, conflict));
    try std.testing.expectError(error.FileNotFound, directory.dir.access("conflict.json", .{}));
    var externally_changed = try store.load(alloc);
    defer externally_changed.deinit();
    var expected = before.data;
    expected.preferences.reaction_count = 10;
    try std.testing.expect(Data.eql(expected, externally_changed.data));

    try other.exec("UPDATE preferences SET reaction_count=1");
    try other.exec("CREATE TRIGGER fail_import BEFORE INSERT ON items BEGIN SELECT RAISE(ABORT, 'fixture import failure'); END");
    var with_trigger = try store.load(alloc);
    defer with_trigger.deinit();
    try std.testing.expect(Data.eql(before.data, with_trigger.data));
    const failed = try std.fs.path.join(alloc, &.{ parent, "before-failed-import.json" });
    defer alloc.free(failed);
    const incoming: Data = .{ .shared_items = &.{.{ .id = "new", .name = "New", .text = "Replacement" }} };
    try std.testing.expectError(error.ConstraintViolation, store.replaceFromBackup(incoming, failed));
    var failure_backup = try readJson(alloc, failed);
    defer failure_backup.deinit();
    try std.testing.expect(Data.eql(before.data, failure_backup.data));
    var after_failure = try store.load(alloc);
    defer after_failure.deinit();
    try std.testing.expect(Data.eql(before.data, after_failure.data));
    try other.exec("DROP TRIGGER fail_import");
    var after_trigger = try store.load(alloc);
    defer after_trigger.deinit();
    try std.testing.expect(Data.eql(before.data, after_trigger.data));

    try store.replaceFromBackup(.{}, backup);
    var empty = try store.load(alloc);
    defer empty.deinit();
    try std.testing.expect(Data.eql(.{}, empty.data));
    var restore = try readJson(alloc, backup);
    defer restore.deinit();
    try store.save(restore.data);
    var restored = try store.load(alloc);
    defer restored.deinit();
    try std.testing.expect(Data.eql(before.data, restored.data));
}

test "DB5 and JSON2 preserve shortcut spelling and distinguish an empty binding from a missing action" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const db_path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(db_path);
    const json_path = try std.fs.path.join(alloc, &.{ parent, "keys.json" });
    defer alloc.free(json_path);

    var store = try Store.open(alloc, db_path);
    defer store.close();
    var prefs: Preferences = .{};
    prefs.shortcut_keys[@intFromEnum(Action.profile1)] = "";
    prefs.shortcut_keys[@intFromEnum(Action.chat_focus)] = "!^f12";
    prefs.shortcut_keys[@intFromEnum(Action.stop)] = "eSC";
    try store.savePreferences(prefs);
    var readback = try store.load(alloc);
    defer readback.deinit();
    try std.testing.expect(Data.eql(.{ .preferences = prefs }, readback.data));

    try store.exportJson(json_path);
    var exchanged = try readJson(alloc, json_path);
    defer exchanged.deinit();
    try std.testing.expect(Data.eql(readback.data, exchanged.data));
    const encoded = try directory.dir.readFileAlloc(alloc, "keys.json", 4096);
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"profile1\":\"\",") != null);
    const missing = try std.mem.replaceOwned(u8, alloc, encoded, "\"profile1\":\"\",", "");
    defer alloc.free(missing);
    try directory.dir.writeFile(.{ .sub_path = "keys.json", .data = missing });
    try std.testing.expectError(error.InvalidShortcut, readJson(alloc, json_path));

    try store.db.exec("DELETE FROM shortcut_bindings WHERE action='profile1'");
    try std.testing.expectError(error.RequiredShortcut, store.load(alloc));
}

test "DB5 rejects malformed persisted data without rewriting the database" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const baseline: Data = .{ .shared_items = &.{.{ .id = "integrity-item", .name = "kept", .text = "important" }} };
    const corruptions = [_][:0]const u8{
        "DELETE FROM preferences",
        "DELETE FROM scopes WHERE id='@shared'",
        "DELETE FROM shortcut_bindings WHERE action='chat_focus'",
        "UPDATE shortcut_bindings SET action='CHAT_FOCUS' WHERE action='chat_focus'",
        "INSERT INTO shortcut_bindings VALUES('CHAT_FOCUS','^!f')",
        "DELETE FROM shortcut_bindings WHERE action='reaction'",
        "UPDATE preferences SET reaction_count=7",
        "UPDATE preferences SET reaction_kind=1.5",
        "UPDATE preferences SET reaction_count=10.5",
        "UPDATE preferences SET reaction_interval=200.5",
        "UPDATE scopes SET position=0.5",
        "UPDATE items SET position=1024.5",
        "UPDATE preferences SET reaction_interval=-0.5",
        "UPDATE preferences SET reaction_kind='0x1'",
        "UPDATE items SET position='0x10000000000000400'",
        "UPDATE items SET position=1e30",
        "UPDATE preferences SET reaction_kind=CAST('1' AS BLOB)",
        "UPDATE items SET position=CAST('1024' AS BLOB)",
        "UPDATE items SET body=char(10)",
        "UPDATE items SET id=''",
        "UPDATE items SET body='prefix'||char(0)||'suffix'",
        "UPDATE items SET body=char(0)||'suffix'",
        "UPDATE items SET body='prefix'||char(0)",
        "UPDATE items SET id=id||char(0)||'other'",
    };
    for (corruptions, 0..) |sql, index| {
        const name = try std.fmt.allocPrint(alloc, "corrupt-{d}.db", .{index});
        defer alloc.free(name);
        const path = try std.fs.path.join(alloc, &.{ parent, name });
        defer alloc.free(path);
        {
            var writer = try Store.open(alloc, path);
            defer writer.close();
            try writer.save(baseline);
            try writer.db.exec("PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON");
            try writer.db.exec(sql);
        }
        const before = try directory.dir.readFileAlloc(alloc, name, model.max_file_bytes);
        defer alloc.free(before);
        {
            var reader = try Store.open(alloc, path);
            defer reader.close();
            if (reader.load(alloc)) |result| {
                var accepted = result;
                accepted.deinit();
                std.debug.print("Unexpectedly loaded DB5 after {s}\n", .{sql});
                return error.MalformedDatabaseAccepted;
            } else |_| {}
        }
        const after = try directory.dir.readFileAlloc(alloc, name, model.max_file_bytes);
        defer alloc.free(after);
        if (!eql(u8, before, after)) {
            std.debug.print("DB5 bytes changed on rejection after {s}\n", .{sql});
            return error.RejectedDatabaseChanged;
        }
    }
}

test "DB5 schema rejects invalid writes and preserves the prior data" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    var store = try Store.open(alloc, path);
    defer store.close();
    const baseline: Data = .{ .shared_items = &.{.{ .id = "constraint-item", .name = "kept", .text = "important" }} };
    try store.save(baseline);
    const writes = try store.db.scalarInt("SELECT total_changes()", &.{});

    for ([_][:0]const u8{
        "UPDATE items SET id=''",
        "UPDATE scopes SET id=''",
        "UPDATE scopes SET name='unexpected' WHERE id='@shared'",
        "UPDATE scopes SET channel='unexpected' WHERE id='@shared'",
        "UPDATE scopes SET position=1 WHERE id='@shared'",
        "UPDATE scopes SET position=0.5",
        "UPDATE items SET position=1.5",
        "UPDATE items SET slot=1.5",
        "UPDATE preferences SET active_scope='@shared'",
        "UPDATE preferences SET auto_mode=0.5",
        "UPDATE preferences SET reaction_kind=1.5",
        "UPDATE preferences SET reaction_kind=0",
        "UPDATE preferences SET reaction_count=0",
        "UPDATE preferences SET reaction_count=10.5",
        "UPDATE preferences SET reaction_interval=-1",
        "UPDATE preferences SET reaction_interval=200.5",
        "UPDATE preferences SET reaction_kind=CAST('1' AS BLOB)",
    }) |sql| {
        errdefer std.debug.print("Unexpected result for DB5 constraint: {s}\n", .{sql});
        try std.testing.expectError(error.ConstraintViolation, store.db.exec(sql));
        try std.testing.expectEqual(writes, try store.db.scalarInt("SELECT total_changes()", &.{}));
        var verified = try store.load(alloc);
        defer verified.deinit();
        try std.testing.expect(Data.eql(baseline, verified.data));
        try store.db.checkIntegrity();
    }
}

test "DB5 failed reload leaves the validated revision and cannot overwrite a later row" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    var store = try Store.open(alloc, path);
    defer store.close();
    try store.save(.{ .shared_items = &.{
        .{ .id = "first", .name = "First", .text = "before" },
        .{ .id = "last", .name = "Last", .text = "old" },
    } });
    var baseline = try store.load(alloc);
    defer baseline.deinit();
    const old_version = store.data_version;

    var writer = try sqlite.Connection.open(alloc, path, .read_write);
    defer writer.close();
    try writer.exec("UPDATE items SET body='prefix'||char(0)||'suffix' WHERE id='last'");
    try std.testing.expectError(error.InvalidDatabase, store.load(alloc));
    try std.testing.expectEqual(old_version, store.data_version);
    try std.testing.expectEqualStrings("old", baseline.data.shared_items[1].text);
    try std.testing.expectError(error.DatabaseChanged, store.saveLibrary(baseline.data));
    const kept = try writer.scalarText(alloc, "SELECT hex(body) FROM items WHERE id='last'", &.{});
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("70726566697800737566666978", kept);

    try writer.exec("UPDATE items SET body='repaired' WHERE id='last'");
    var repaired = try store.load(alloc);
    defer repaired.deinit();
    try std.testing.expectEqualStrings("before", repaired.data.shared_items[0].text);
    try std.testing.expectEqualStrings("repaired", repaired.data.shared_items[1].text);
    try store.saveLibrary(repaired.data);
    try store.db.checkIntegrity();
}

test "JSON2 rejects invalid scope, duplicate names, unexpected keys, and malformed Unicode" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "import.json" });
    defer alloc.free(path);
    const json = try exchange.write(alloc, .{ .shared_items = &.{.{ .id = "a", .name = "あ", .text = "hello" }} });
    defer alloc.free(json);
    const cases = [_]struct { needle: []const u8, replacement: []const u8 }{
        .{ .needle = "\"version\":2", .replacement = "\"Version\":2,\"version\":2" },
        .{ .needle = "\"version\":2", .replacement = "\"version\":1" },
        .{ .needle = "\"version\":2", .replacement = "\"version\":2.0" },
        .{ .needle = "\"version\":2", .replacement = "\"version\":2,\"extra\":1" },
        .{ .needle = "\"inputProfileId\":\"\"", .replacement = "\"inputProfileId\":\"missing\"" },
        .{ .needle = "\"slot\":0", .replacement = "\"slot\":3" },
        .{ .needle = "hello", .replacement = "\\u0000" },
        .{ .needle = "hello", .replacement = "\\udc00" },
        .{ .needle = "hello", .replacement = "\xf0\x80\x80\x80" },
    };
    for (cases) |case| {
        const variant = try std.mem.replaceOwned(u8, alloc, json, case.needle, case.replacement);
        defer alloc.free(variant);
        try directory.dir.writeFile(.{ .sub_path = "import.json", .data = variant });
        if (readJson(alloc, path)) |result| {
            var accepted = result;
            accepted.deinit();
            return error.IllegalJsonWasAccepted;
        } else |_| {}
    }
    const bom = try std.fmt.allocPrint(alloc, "\xef\xbb\xbf{s}", .{json});
    defer alloc.free(bom);
    try directory.dir.writeFile(.{ .sub_path = "import.json", .data = bom });
    var accepted = try readJson(alloc, path);
    defer accepted.deinit();
    try std.testing.expectEqualStrings("あ", accepted.data.shared_items[0].name);
}

test "text saves and undo use one row and reject stale snapshots on the same connection" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    var store = try Store.open(alloc, path);
    defer store.close();
    try store.save(.{ .shared_items = &.{
        .{ .id = "first", .name = "First", .text = "最初の本文", .slot = 1 },
        .{ .id = "second", .name = "Second", .text = "original" },
    } });
    try store.db.exec("UPDATE items SET position=47 WHERE id='first'");

    var first = try store.load(alloc);
    defer first.deinit();
    var stale = try store.load(alloc);
    defer stale.deinit();
    var first_history = LibraryHistory.init(alloc);
    defer first_history.deinit();
    var other_history = LibraryHistory.init(alloc);
    defer other_history.deinit();
    const edit_first: ItemCommand = .{ .edit = .{ .id = "first", .values = .{ .name = "一番", .text = "変更後👏", .slot = 1 } } };
    const edit_second: ItemCommand = .{ .edit = .{ .id = "second", .values = .{ .name = "Second", .text = "new value" } } };
    const start_writes = try store.db.scalarInt("SELECT total_changes()", &.{});
    _ = try first_history.item(&store, &first, "", edit_first);
    try std.testing.expect(store.library_cache == null);
    try std.testing.expectEqual(start_writes + 1, first.library_origin.?.revision.writes);
    try std.testing.expectEqual(try model.validatedTextBytes(alloc, first.data), first.library_origin.?.text_bytes);
    try std.testing.expectError(error.DatabaseChanged, other_history.item(&store, &stale, "", edit_second));
    try std.testing.expectEqual(@as(usize, 0), other_history.length);
    try std.testing.expectEqualStrings("original", stale.data.shared_items[1].text);

    try std.testing.expect(try first_history.undo(&store, &first));
    try std.testing.expect(store.library_cache == null);
    try std.testing.expectEqual(start_writes + 2, first.library_origin.?.revision.writes);
    try std.testing.expectEqualStrings("最初の本文", first.data.shared_items[0].text);
    try std.testing.expectEqual(@as(i64, 47), try store.db.scalarInt("SELECT position FROM items WHERE id='first'", &.{}));

    _ = try first_history.item(&store, &first, "", edit_first);
    var other = try store.load(alloc);
    defer other.deinit();
    _ = try other_history.item(&store, &other, "", edit_second);
    try std.testing.expectError(error.DatabaseChanged, first_history.undo(&store, &first));
    try std.testing.expectEqual(@as(usize, 1), first_history.length);
    try std.testing.expectError(error.DatabaseChanged, first_history.item(&store, &first, "", .{ .delete = "first" }));
    var readback = try store.load(alloc);
    defer readback.deinit();
    try std.testing.expect(Data.eql(other.data, readback.data));

    readback.data.preferences.auto_mode = false;
    try store.savePreferences(readback.data.preferences);
    _ = try first_history.item(&store, &readback, "", .{ .edit = .{ .id = "first", .values = .{ .name = "First", .text = "after settings", .slot = 1 } } });
    var after_settings = try store.load(alloc);
    defer after_settings.deinit();
    try std.testing.expect(Data.eql(readback.data, after_settings.data));

    // A structural save must carry the same revision protection. A snapshot
    // without a stamp must also be compared to the database before saving.
    _ = try first_history.item(&store, &readback, "", .{ .add = .{ .name = "Third", .text = "added" } });
    try std.testing.expect(readback.library_origin != null);
    var unstamped = try Snapshot.clone(alloc, readback.data);
    defer unstamped.deinit();
    var after_add = try store.load(alloc);
    defer after_add.deinit();
    _ = try other_history.item(&store, &after_add, "", .{ .edit = .{ .id = "second", .values = .{ .name = "Second", .text = "later edit" } } });
    try std.testing.expectError(error.DatabaseChanged, first_history.item(&store, &readback, "", edit_first));
    try std.testing.expectError(error.DatabaseChanged, first_history.item(&store, &unstamped, "", edit_first));
    var final = try store.load(alloc);
    defer final.deinit();
    try std.testing.expect(Data.eql(after_add.data, final.data));
}

test "library edits preserve identity and original slot owners through undo" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    var store = try Store.open(alloc, path);
    defer store.close();
    var current = try store.load(alloc);
    defer current.deinit();
    var history = LibraryHistory.init(alloc);
    defer history.deinit();

    const new_profile = (try history.profile(&store, &current, .{ .add = .{ .name = " 作成 ", .channel = "/@creator" } })).?;
    const profile = try alloc.dupe(u8, new_profile);
    defer alloc.free(profile);
    try std.testing.expectEqualStrings("作成", current.data.findProfile(profile).?.name);
    const first_id = (try history.item(&store, &current, "", .{ .add = .{ .name = " First ", .text = "👏", .slot = 1 } })).?;
    const first = try alloc.dupe(u8, first_id);
    defer alloc.free(first);
    const second_id = (try history.item(&store, &current, "", .{ .add = .{ .name = "Second", .text = "short", .slot = 1 } })).?;
    const second = try alloc.dupe(u8, second_id);
    defer alloc.free(second);
    try std.testing.expectEqual(@as(u8, 0), current.data.shared_items[0].slot);
    try std.testing.expectEqual(@as(u8, 1), current.data.shared_items[1].slot);
    _ = try history.item(&store, &current, "", .{ .edit = .{ .id = first, .values = .{ .name = "First", .text = " changed ", .slot = 2 } } });
    try std.testing.expect(try history.assign(&store, &current, "", first, second));
    try std.testing.expectEqual(@as(u8, 1), current.data.shared_items[0].slot);
    try std.testing.expectEqual(@as(u8, 2), current.data.shared_items[1].slot);
    _ = try history.item(&store, &current, "", .{ .up = second });
    try std.testing.expectEqualStrings(second, current.data.shared_items[0].id);
    _ = try history.item(&store, &current, "", .{ .down = second });
    const duplicated = (try history.item(&store, &current, "", .{ .duplicate = first })).?;
    try std.testing.expect(!eql(u8, first, duplicated));
    try std.testing.expectEqualStrings("First（コピー）", current.data.shared_items[1].name);
    _ = try history.item(&store, &current, "", .{ .delete = duplicated });
    _ = try history.item(&store, &current, "", .{ .move = .{ .id = first, .destination = profile } });
    try std.testing.expectEqual(@as(u8, 0), current.data.findProfile(profile).?.items[0].slot);
    _ = try history.profile(&store, &current, .{ .rename = .{ .id = profile, .name = "Changed" } });
    _ = try history.profile(&store, &current, .{ .unbind = profile });
    _ = try history.profile(&store, &current, .{ .bind = .{ .id = profile, .channel = "/@new" } });
    _ = try history.profile(&store, &current, .{ .delete = profile });
    try std.testing.expectEqual(@as(usize, 0), current.data.profiles.len);

    try std.testing.expect(try history.undo(&store, &current));
    try std.testing.expectEqualStrings(first, current.data.profiles[0].items[0].id);
    try std.testing.expectEqualStrings("/@new", current.data.profiles[0].channel);
    for (0..4) |_| try std.testing.expect(try history.undo(&store, &current));
    try std.testing.expectEqualStrings("作成", current.data.profiles[0].name);
    try std.testing.expectEqualStrings(first, current.data.shared_items[0].id);
    try std.testing.expectEqual(@as(u8, 1), current.data.shared_items[0].slot);
    var readback = try store.load(alloc);
    defer readback.deinit();
    try std.testing.expect(Data.eql(current.data, readback.data));
    while (try history.undo(&store, &current)) {}
    try std.testing.expect(Data.eql(.{}, current.data));
}

test "library keeps only 30 successful edits and preserves undo when save fails" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    var store = try Store.open(alloc, path);
    defer store.close();
    var current = try store.load(alloc);
    defer current.deinit();
    var history = LibraryHistory.init(alloc);
    defer history.deinit();
    const id = (try history.item(&store, &current, "", .{ .add = .{ .name = "name", .text = "first" } })).?;
    const saved_id = try alloc.dupe(u8, id);
    defer alloc.free(saved_id);
    for (0..31) |count| {
        var buffer: [24]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "Text {d}", .{count});
        _ = try history.item(&store, &current, "", .{ .edit = .{ .id = saved_id, .values = .{ .name = "name", .text = text } } });
    }
    try std.testing.expectEqual(@as(usize, 30), history.length);
    var writer = try Store.open(alloc, path);
    defer writer.close();
    var other = try writer.load(alloc);
    defer other.deinit();
    var preferences = other.data.preferences;
    preferences.auto_mode = false;
    try writer.savePreferences(preferences);
    try std.testing.expectError(error.DatabaseChanged, history.undo(&store, &current));
    try std.testing.expectEqualStrings("Text 30", current.data.shared_items[0].text);
    try std.testing.expectEqual(@as(usize, 30), history.length);
}

test "a version committed only to WAL is refused without rewriting existing files" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    var store = try Store.open(alloc, path);
    store.close();
    var keeper = try sqlite.Connection.open(alloc, path, .read_write);
    defer keeper.close();
    try keeper.exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA user_version=4");
    const db_before = try directory.dir.readFileAlloc(alloc, "settings.db", model.max_file_bytes);
    defer alloc.free(db_before);
    const wal_before = try directory.dir.readFileAlloc(alloc, "settings.db-wal", model.max_file_bytes);
    defer alloc.free(wal_before);
    try std.testing.expectError(error.UnsupportedDatabaseVersion, Store.open(alloc, path));
    const db_after = try directory.dir.readFileAlloc(alloc, "settings.db", model.max_file_bytes);
    defer alloc.free(db_after);
    const wal_after = try directory.dir.readFileAlloc(alloc, "settings.db-wal", model.max_file_bytes);
    defer alloc.free(wal_after);
    try std.testing.expectEqualSlices(u8, db_before, db_after);
    try std.testing.expectEqualSlices(u8, wal_before, wal_after);
}

test "storage bounds leave the committed DB intact on a failed write" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    var store = try Store.open(alloc, path);
    defer store.close();
    var empty = try store.load(alloc);
    defer empty.deinit();
    const pages = try store.db.scalarInt("PRAGMA page_count", &.{});
    const limit = try std.fmt.allocPrintSentinel(alloc, "PRAGMA max_page_count={d}", .{pages + 1}, 0);
    defer alloc.free(limit);
    try std.testing.expectEqual(pages + 1, try store.db.scalarInt(limit, &.{}));
    const text = try alloc.alloc(u8, 1_024 * 1_024);
    defer alloc.free(text);
    @memset(text, 'x');
    const too_large: Data = .{ .shared_items = &.{.{ .id = "id", .name = "name", .text = text }} };
    try std.testing.expectError(error.DatabaseFull, store.saveLibrary(too_large));
    var after = try store.load(alloc);
    defer after.deinit();
    try std.testing.expect(Data.eql(empty.data, after.data));
}

test "registration limits count the trailing NUL and reject an oversized combined snapshot" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(path);
    var store = try Store.open(alloc, path);
    defer store.close();
    const template = sample_registration[0 .. sample_registration.len - 1] ++ ",\"padding\":\"";
    const target_size = model.max_registration_bytes - 1;
    const padding = try alloc.alloc(u8, target_size - template.len - 2);
    defer alloc.free(padding);
    @memset(padding, 'x');
    const exact = try std.fmt.allocPrint(alloc, "{s}{s}\"}}", .{ template, padding });
    defer alloc.free(exact);
    try std.testing.expectEqual(@as(usize, target_size), exact.len);
    try store.saveRegistration(exact);
    const second = try std.mem.replaceOwned(u8, alloc, exact, "\"edge\"", "\"test\"");
    defer alloc.free(second);
    try store.saveRegistration(second);
    const third_over = try std.mem.replaceOwned(u8, alloc, exact, "\"edge\"", "\"fire\"");
    defer alloc.free(third_over);
    const third_size = model.max_registrations_bytes - 2 * target_size;
    const third = try std.fmt.allocPrint(alloc, "{s}\"}}", .{third_over[0 .. third_size - 2]});
    defer alloc.free(third);
    try store.saveRegistration(third);
    const combined = try store.db.scalarInt(
        "SELECT SUM(length(CAST(json_set(payload,'$.browser',browser) AS BLOB))) FROM reaction_registrations",
        &.{},
    );
    try std.testing.expectEqual(@as(i64, model.max_registrations_bytes), combined);
    const extra_byte = try std.fmt.allocPrint(alloc, "{s}x\"}}", .{third_over[0 .. third_size - 2]});
    defer alloc.free(extra_byte);
    try std.testing.expectError(error.RegistrationsTooLarge, store.saveRegistration(extra_byte));
    const over = try std.fmt.allocPrint(alloc, "{s} ", .{exact});
    defer alloc.free(over);
    try std.testing.expectError(error.RegistrationTooLarge, store.saveRegistration(over));
    var data = try store.load(alloc);
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 3), data.data.registrations.len);
}

test "data limits allow exact profile and item counts and use UTF-16 bytes for Japanese and emoji" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const owned = arena.allocator();
    const profiles = try owned.alloc(Profile, model.max_profiles + 1);
    for (profiles, 0..) |*profile, i| profile.* = .{
        .id = try std.fmt.allocPrint(owned, "profile-{d}", .{i}),
        .name = "配信者",
    };
    const items = try owned.alloc(Item, model.max_items + 1);
    for (items, 0..) |*item, i| item.* = .{
        .id = try std.fmt.allocPrint(owned, "item-{d}", .{i}),
        .name = "弾幕",
        .text = "👏",
    };
    try validate(alloc, .{ .profiles = profiles[0..model.max_profiles], .shared_items = items[0..model.max_items] });
    try std.testing.expectError(error.TooManyProfiles, validate(alloc, .{ .profiles = profiles }));
    try std.testing.expectError(error.TooManyItems, validate(alloc, .{ .shared_items = items }));

    const text = try owned.alloc(u8, model.max_text_bytes);
    for (0..text.len / 4) |i| @memcpy(text[i * 4 ..][0..4], "👏");
    const max_text: Item = .{ .id = "i", .name = "一二", .text = text[0 .. text.len - 4] };
    try validate(alloc, .{ .shared_items = &.{max_text} });
    var longer = max_text;
    longer.text = text;
    try std.testing.expectError(error.TotalTextTooLong, validate(alloc, .{ .shared_items = &.{longer} }));
}

test "DB5 and JSON2 accept 128 MiB files and reject the first excess byte" {
    const alloc = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const parent = try directory.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent);
    const database_path = try std.fs.path.join(alloc, &.{ parent, "settings.db" });
    defer alloc.free(database_path);
    {
        var store = try Store.open(alloc, database_path);
        defer store.close();
        var snapshot = try store.load(alloc);
        defer snapshot.deinit();
        const page_size = try store.db.scalarInt("PRAGMA page_size", &.{});
        const limit = @divExact(model.max_file_bytes, page_size);
        try std.testing.expectEqual(limit, try store.db.scalarInt("PRAGMA max_page_count", &.{}));
        // Fill a synthetic table to the last allowed page without weakening
        // the application's actual SQLite growth guard.
        try store.db.exec("CREATE TABLE capacity_test(value BLOB)");
        try store.db.run("INSERT INTO capacity_test VALUES(zeroblob(?))", &.{.{ .int = 126 * 1024 * 1024 }});
        try store.db.exec("BEGIN IMMEDIATE");
        errdefer store.db.rollback();
        var append = try store.db.prepare("INSERT INTO capacity_test VALUES(zeroblob(480))");
        defer append.close();
        var count: i64 = 0;
        for (0..20_000) |_| {
            try append.run(&.{});
            count = try store.db.scalarInt("PRAGMA page_count", &.{});
            if (count == limit) break;
        }
        try std.testing.expectEqual(limit, count);
        try store.db.exec("COMMIT");
    }
    try std.testing.expectEqual(@as(u64, model.max_file_bytes), (try directory.dir.statFile("settings.db")).size);
    {
        var reopened = try Store.open(alloc, database_path);
        defer reopened.close();
        var settings = try reopened.load(alloc);
        defer settings.deinit();
        try std.testing.expect(Data.eql(.{}, settings.data));
        try reopened.db.checkIntegrity();
    }
    {
        const file = try directory.dir.openFile("settings.db", .{ .mode = .write_only });
        defer file.close();
        try file.setEndPos(model.max_file_bytes + 1);
    }
    try std.testing.expectError(error.DatabaseTooLarge, Store.open(alloc, database_path));
    try std.testing.expectEqual(@as(u64, model.max_file_bytes + 1), (try directory.dir.statFile("settings.db")).size);

    const document = try exchange.write(alloc, .{});
    defer alloc.free(document);
    const json_path = try std.fs.path.join(alloc, &.{ parent, "large.json" });
    defer alloc.free(json_path);
    {
        const file = try directory.dir.createFile("large.json", .{});
        defer file.close();
        try file.writeAll(document);
        const spaces: [128 * 1024]u8 = @splat(' ');
        var remaining = model.max_file_bytes - document.len;
        while (remaining != 0) {
            const length = @min(remaining, spaces.len);
            try file.writeAll(spaces[0..length]);
            remaining -= length;
        }
    }
    try std.testing.expectEqual(@as(u64, model.max_file_bytes), (try directory.dir.statFile("large.json")).size);
    var parsed = try readJson(alloc, json_path);
    defer parsed.deinit();
    try std.testing.expect(Data.eql(.{}, parsed.data));
    {
        const file = try directory.dir.openFile("large.json", .{ .mode = .write_only });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(" ");
    }
    try std.testing.expectError(error.InvalidJsonSize, readJson(alloc, json_path));
}

test {
    _ = recovery;
    _ = sqlite;
}
