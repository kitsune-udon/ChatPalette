const std = @import("std");
const transport = @import("worker_client.zig");
const shortcuts = @import("shortcuts.zig");

pub const Distribution = enum {
    matching,
    modified,
    running_unknown,
    disk_unknown,

    fn label(self: Distribution) []const u8 {
        return switch (self) {
            .matching => "起動時の配布物と一致",
            .modified => "更新あり。再起動で反映",
            .running_unknown => "起動時の配布物を確認できませんでした",
            .disk_unknown => "配布物の確認に失敗しました",
        };
    }
};

pub const Browser = enum {
    unselected,
    chrome,
    msedge,
    firefox,
    brave,
    opera,
    vivaldi,

    pub fn fromName(name: ?[]const u8) Browser {
        return std.meta.stringToEnum(Browser, name orelse return .unselected) orelse .unselected;
    }

    fn label(self: Browser) []const u8 {
        return switch (self) {
            .unselected => "未選択",
            .chrome => "Chrome",
            .msedge => "Edge",
            .firefox => "Firefox",
            .brave => "Brave",
            .opera => "Opera",
            .vivaldi => "Vivaldi",
        };
    }
};

pub const State = enum {
    ok,
    focused,
    hovered,
    cleared,
    enter_sent,
    inserted,
    operated,
    ready,
    captured,
    configured,
    unavailable,
    changed,
    cancelled,
    wrong_input,
    invalid_text,
    wrong_window,
    chat_missing,
    chat_ambiguous,
    focus_failed,
    menu_closed,
    not_registered,
    unsupported,
    unknown,

    pub fn fromCode(code: []const u8) State {
        return std.meta.stringToEnum(State, code) orelse .unknown;
    }

    pub fn fromWorker(code: []const u8) State {
        return switch (fromCode(code)) {
            .cleared, .enter_sent, .inserted => .unknown,
            else => |state| state,
        };
    }
};

pub const PageStage = enum {
    focus,
    clear_check,
    clear_keys,
    send_check,
    enter_key,
    show_reactions,

    fn label(self: PageStage) []const u8 {
        return switch (self) {
            .focus => "フォーカス",
            .clear_check => "クリア前の確認",
            .clear_keys => "クリアキー送信",
            .send_check => "送信前の確認",
            .enter_key => "Enterキー送信",
            .show_reactions => "表示操作",
        };
    }
};

pub const PageOperation = struct {
    action: shortcuts.Action,
    browser: Browser,
    stage: PageStage,
    state: State,
    elapsed_ms: u64,
    latest: bool = true,
};

pub const Phase = enum {
    idle,
    queued,
    waiting,
    running,
    stopping,
    finished,

    fn label(self: Phase) []const u8 {
        return switch (self) {
            .idle => "待機中",
            .queued => "ショートカット開始待ち",
            .waiting => "開始・登録待ち",
            .running => "実行中",
            .stopping => "停止処理中",
            .finished => "終了",
        };
    }
};

pub const WorkerFailure = struct {
    cause: anyerror,
    cleanup: ?anyerror,
    may_have_arrived: bool,

    pub fn format(self: WorkerFailure, buffer: []u8) ![]const u8 {
        if (self.cleanup) |failure| {
            if (failure == self.cause) return std.fmt.bufPrint(buffer, "補助プロセスの終了を確認できませんでした（{s}）。", .{@errorName(failure)});
            return std.fmt.bufPrint(buffer, "補助プロセスの要求失敗 {s}\r\n補助プロセスの終了を確認できませんでした（{s}）。", .{ @errorName(self.cause), @errorName(failure) });
        }
        return std.fmt.bufPrint(buffer, "補助プロセスの要求失敗 {s}", .{@errorName(self.cause)});
    }
};

/// Only diagnostic conditions are admitted. Worker reply text, window identity,
/// profiles, item text and local paths have no field in the displayed document.
pub const Snapshot = struct {
    distribution: Distribution,
    browser: Browser,
    operation: ?transport.Mode,
    page_operation: ?PageOperation = null,
    state: State,
    elapsed_ms: u64,
    worker_failure: ?WorkerFailure = null,
    stop_failure: ?anyerror = null,
    phase: Phase,
    worker_running: bool,
    automatic: bool,

    pub fn format(self: Snapshot, buffer: []u8, comptime version: []const u8) ![]const u8 {
        var detail: [256]u8 = undefined;
        const failure = if (self.worker_failure) |value| try value.format(&detail) else "";
        const worker_request = if (self.operation) |mode| @tagName(mode) else "未実行";
        var stage_buffer: [256]u8 = undefined;
        var operation = worker_request;
        var state = if (self.operation != null) @tagName(self.state) else @as([]const u8, "未実行");
        var browser = self.browser;
        var elapsed_ms = self.elapsed_ms;
        const stage = if (self.page_operation) |page| info: {
            if (page.latest) {
                operation = @tagName(page.action);
                state = @tagName(page.state);
                browser = page.browser;
                elapsed_ms = page.elapsed_ms;
                break :info try std.fmt.bufPrint(&stage_buffer, "\r\n処理段階 {s}\r\n補助プロセスの要求 {s}", .{ page.stage.label(), worker_request });
            }
            break :info try std.fmt.bufPrint(&stage_buffer, "\r\n直近のページ操作 {s}\r\nページ操作の処理段階 {s}\r\nページ操作の結果 {s}\r\nページ操作のブラウザー {s}", .{
                @tagName(page.action), page.stage.label(), @tagName(page.state), page.browser.label(),
            });
        } else "";
        return std.fmt.bufPrint(buffer, "ChatPalette {s}\r\nWindows x64\r\n配布物 {s}\r\nブラウザー {s}\r\n直近の操作 {s}\r\n結果 {s}{s}\r\n処理時間 {d} ms{s}{s}{s}{s}\r\nリアクション {s} ({s})\r\n補助プロセス {s}\r\n自動判別 {s}\r\nDB形式 5   JSON形式 2\r\n再起動は現在の展開先の ChatPalette.exe から行います。", .{
            version,
            self.distribution.label(),
            browser.label(),
            operation,
            state,
            stage,
            elapsed_ms,
            if (failure.len != 0) "\r\n" else "",
            failure,
            if (self.stop_failure != null) "\r\n終了操作での補助プロセス終了失敗 " else "",
            if (self.stop_failure) |value| @errorName(value) else "",
            self.phase.label(),
            @tagName(self.phase),
            if (self.worker_running) "起動中" else "待機中",
            if (self.automatic) "ON" else "OFF",
        });
    }
};
