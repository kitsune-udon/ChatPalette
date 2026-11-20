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
    registered,
    save_failed,
    sync_failed,
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
            .cleared, .enter_sent, .inserted, .registered, .save_failed, .sync_failed => .unknown,
            else => |state| state,
        };
    }

    fn label(self: State) []const u8 {
        return switch (self) {
            .ok => "確認できました",
            .focused => "チャット欄へ移動しました",
            .hovered => "表示用UIへマウスを移動しました（表示は未確認）",
            .cleared => "クリアキーを送りました（内容は未取得）",
            .enter_sent => "Enterキーを送りました（送信受理は未確認）",
            .inserted => "弾幕を入力しました",
            .operated => "ボタンを操作しました（受理は未確認）",
            .ready => "操作対象を確認できました",
            .captured => "リアクションボタンを確認できました",
            .configured => "設定済み（認識は未確認）",
            .registered => "登録できました",
            .save_failed => "登録情報を保存できませんでした",
            .sync_failed => "登録情報を同期できませんでした",
            .unavailable => "情報を取得できませんでした",
            .changed => "動画・タブ・ウィンドウが切り替わりました",
            .cancelled => "中止しました",
            .wrong_input => "入力欄を確認できませんでした",
            .invalid_text => "本文に入力できない制御文字が含まれています",
            .wrong_window => "操作先が変わったため中止しました",
            .chat_missing => "入力可能なチャット欄が見つかりません",
            .chat_ambiguous => "チャット入力欄が複数あります",
            .focus_failed => "チャット欄へのフォーカス移動を確認できませんでした",
            .menu_closed => "リアクションメニューが見つかりません",
            .not_registered => "操作ボタンが未登録です",
            .unsupported => "操作対象を識別できませんでした",
            .unknown => "操作結果を確認できませんでした",
        };
    }
};

fn operationLabel(mode: transport.Mode) []const u8 {
    return switch (mode) {
        .browser_context => "現在の動画の確認",
        .resolve => "配信者の自動判別",
        .verify_input => "チャット欄・コメント欄の確認",
        .verify_chat => "チャット欄の確認",
        .chat_focus => "チャット欄への移動",
        .reactions_show => "リアクションUIの表示操作",
        .reaction_configure => "リアクションボタンの設定",
        .reaction_capture => "リアクションボタンの登録",
        .reaction_check => "リアクションの検出確認",
        .reaction_send => "リアクションボタンの操作",
        .chat_enter => "Enterでメッセージ送信",
        .chat_clear => "チャット欄のクリア",
        .input_insert => "弾幕の入力",
    };
}

fn pageActionLabel(action: shortcuts.Action) []const u8 {
    return switch (action) {
        .chat_focus => operationLabel(.chat_focus),
        .chat_clear => operationLabel(.chat_clear),
        .chat_send => operationLabel(.chat_enter),
        .reactions_show => operationLabel(.reactions_show),
        else => "ページ操作",
    };
}

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

pub const RegistrationOperation = struct {
    browser: Browser,
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

pub const ResolveFailure = enum {
    deadline,
    network,
    metadata,
    automation,

    pub fn fromWorker(detail: []const u8) ?ResolveFailure {
        const reasons = std.StaticStringMap(ResolveFailure).initComptime(.{
            .{ "ResolveDeadlineExceeded", .deadline },
            .{ "HttpOpenFailed", .network },
            .{ "HttpSetupFailed", .network },
            .{ "HttpConnectionFailed", .network },
            .{ "HttpRequestFailed", .network },
            .{ "HttpResponseFailed", .network },
            .{ "HttpReadFailed", .network },
            .{ "MetadataTooLarge", .metadata },
            .{ "MissingAuthor", .metadata },
            .{ "InvalidChannel", .metadata },
            .{ "AutomationUnavailable", .automation },
        });
        return reasons.get(detail);
    }

    pub fn message(self: ResolveFailure) []const u8 {
        return switch (self) {
            .deadline => "配信者情報を時間内に取得できませんでした。もう一度お試しください。",
            .network => "YouTubeから配信者情報を受け取れませんでした。",
            .metadata => "YouTubeから受け取った配信者情報を確認できませんでした。",
            .automation => "ブラウザーから動画情報を確認できませんでした。",
        };
    }
};

/// Only diagnostic conditions are admitted. Worker reply text, window identity,
/// profiles, item text and local paths have no field in the displayed document.
pub const Snapshot = struct {
    distribution: Distribution,
    browser: Browser,
    operation: ?transport.Mode,
    page_operation: ?PageOperation = null,
    registration_operation: ?RegistrationOperation = null,
    state: State,
    elapsed_ms: u64,
    worker_failure: ?WorkerFailure = null,
    resolve_failure: ?ResolveFailure = null,
    stop_failure: ?anyerror = null,
    phase: Phase,
    worker_running: bool,
    automatic: bool,

    pub fn format(self: Snapshot, buffer: []u8, version: []const u8) ![]const u8 {
        var detail: [256]u8 = undefined;
        const failure = if (self.worker_failure) |value| try value.format(&detail) else "";
        const worker_request = if (self.operation) |mode| @tagName(mode) else "未実行";
        var operation = worker_request;
        var state = if (self.operation != null) @tagName(self.state) else @as([]const u8, "未実行");
        const not_run = "まだ実行していません";
        var operation_label = if (self.operation) |mode| operationLabel(mode) else @as([]const u8, not_run);
        var state_label = if (self.operation != null) self.state.label() else @as([]const u8, not_run);
        var browser = self.browser;
        var elapsed_ms = self.elapsed_ms;
        var has_operation = self.operation != null;
        var stage_buffer: [512]u8 = undefined;
        const stage = if (self.page_operation) |page| info: {
            if (page.latest) {
                operation = @tagName(page.action);
                state = @tagName(page.state);
                operation_label = pageActionLabel(page.action);
                state_label = page.state.label();
                browser = page.browser;
                elapsed_ms = page.elapsed_ms;
                has_operation = true;
                break :info try std.fmt.bufPrint(&stage_buffer, "\r\n処理段階 {s}\r\n補助プロセスの要求 {s}", .{ page.stage.label(), worker_request });
            }
            break :info try std.fmt.bufPrint(&stage_buffer, "\r\n直近のページ操作 {s}\r\nページ操作の処理段階 {s}\r\nページ操作の結果 {s}\r\nページ操作のブラウザー {s}\r\nページ操作の説明 {s}\r\nページ操作の結果の説明 {s}", .{
                @tagName(page.action), page.stage.label(), @tagName(page.state), page.browser.label(), pageActionLabel(page.action), page.state.label(),
            });
        } else "";
        var registration_buffer: [256]u8 = undefined;
        const registration_info = if (self.registration_operation) |registration| info: {
            if (registration.latest) {
                operation = "reaction_capture";
                state = @tagName(registration.state);
                operation_label = operationLabel(.reaction_capture);
                state_label = registration.state.label();
                browser = registration.browser;
                elapsed_ms = registration.elapsed_ms;
                has_operation = true;
                break :info try std.fmt.bufPrint(&registration_buffer, "\r\n補助プロセスの要求 {s}\r\n補助プロセスの応答 {s}", .{
                    worker_request, if (self.operation != null) @tagName(self.state) else "未実行",
                });
            }
            break :info try std.fmt.bufPrint(&registration_buffer, "\r\n直近のリアクション登録 {s}", .{@tagName(registration.state)});
        } else "";
        var duration_buffer: [32]u8 = undefined;
        const duration = if (has_operation) try std.fmt.bufPrint(&duration_buffer, "{d} ms", .{elapsed_ms}) else "—（未実行）";
        return std.fmt.bufPrint(buffer, "ChatPalette {s}\r\nWindows x64\r\n配布物 {s}\r\nブラウザー {s}\r\n直近の操作 {s}\r\n結果 {s}{s}{s}\r\n処理時間 {s}\r\n操作の説明 {s}\r\n結果の説明 {s}{s}{s}{s}{s}{s}{s}\r\nリアクション {s} ({s})\r\n補助プロセス {s}\r\n自動判別 {s}\r\nDB形式 5   JSON形式 2\r\n再起動は現在の展開先の ChatPalette.exe から行います。", .{
            version,
            self.distribution.label(),
            browser.label(),
            operation,
            state,
            stage,
            registration_info,
            duration,
            operation_label,
            state_label,
            if (failure.len != 0) "\r\n" else "",
            failure,
            if (self.resolve_failure != null) "\r\n配信者の自動判定 " else "",
            if (self.resolve_failure) |reason| reason.message() else "",
            if (self.stop_failure != null) "\r\n補助プロセスの終了失敗 " else "",
            if (self.stop_failure) |value| @errorName(value) else "",
            self.phase.label(),
            @tagName(self.phase),
            if (self.worker_running) "起動中" else "待機中（必要なときに起動）",
            if (self.automatic) "ON" else "OFF",
        });
    }
};

test "resolve diagnostics classify known failures without preserving reply text" {
    try std.testing.expectEqual(ResolveFailure.network, ResolveFailure.fromWorker("HttpResponseFailed").?);
    try std.testing.expectEqual(ResolveFailure.deadline, ResolveFailure.fromWorker("ResolveDeadlineExceeded").?);
    try std.testing.expectEqual(ResolveFailure.metadata, ResolveFailure.fromWorker("MissingAuthor").?);
    try std.testing.expectEqual(ResolveFailure.automation, ResolveFailure.fromWorker("AutomationUnavailable").?);
    try std.testing.expect(ResolveFailure.fromWorker("HttpResponseFailed C:/private/data") == null);
    try std.testing.expect(ResolveFailure.fromWorker("https://www.youtube.com/watch?v=ZigTest0001") == null);
}

test "empty settings diagnostic explanations preserve the contiguous page and worker codes" {
    const expect = std.testing.expect;
    var snapshot: Snapshot = .{
        .distribution = .matching,
        .browser = .unselected,
        .operation = null,
        .state = .unknown,
        .elapsed_ms = 0,
        .phase = .idle,
        .worker_running = false,
        .automatic = true,
    };
    var buffer: [2048]u8 = undefined;
    const idle = try snapshot.format(&buffer, "test");
    try expect(std.mem.indexOf(u8, idle, "結果 未実行\r\n処理時間 —（未実行）") != null);
    try expect(std.mem.indexOf(u8, idle, "補助プロセス 待機中（必要なときに起動）") != null);

    snapshot.browser = .firefox;
    snapshot.operation = .verify_input;
    snapshot.state = .wrong_input;
    snapshot.worker_running = true;
    const failed = try snapshot.format(&buffer, "test");
    try expect(std.mem.indexOf(u8, failed, "直近の操作 verify_input\r\n結果 wrong_input\r\n処理時間 0 ms") != null);
    try expect(std.mem.indexOf(u8, failed, "結果の説明 入力欄を確認できませんでした") != null);
    try expect(std.mem.indexOf(u8, failed, "補助プロセス 起動中") != null);

    snapshot.operation = .verify_chat;
    snapshot.state = .ok;
    snapshot.page_operation = .{
        .action = .chat_clear,
        .browser = .brave,
        .stage = .clear_check,
        .state = .ok,
        .elapsed_ms = 12,
    };
    const page = try snapshot.format(&buffer, "test");
    try expect(std.mem.indexOf(u8, page, "ブラウザー Brave\r\n直近の操作 chat_clear\r\n結果 ok\r\n処理段階 クリア前の確認\r\n補助プロセスの要求 verify_chat\r\n") != null);
    try expect(std.mem.indexOf(u8, page, "処理時間 12 ms\r\n操作の説明 チャット欄のクリア\r\n結果の説明 確認できました") != null);
}
