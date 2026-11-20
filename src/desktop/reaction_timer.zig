const win = @import("win.zig").api;

pub const Timer = struct {
    pub const Kind = enum { preparation, send };

    first_id: win.UINT_PTR,
    next_id: win.UINT_PTR,
    armed: ?Armed = null,

    const Armed = struct {
        id: win.UINT_PTR,
        kind: Kind,
    };

    pub fn init(first_id: win.UINT_PTR) Timer {
        return .{ .first_id = first_id, .next_id = first_id };
    }

    pub fn arm(self: *Timer, window: win.HWND, kind: Kind, wait_ms: u32) bool {
        self.cancel(window);
        // KillTimer does not remove a WM_TIMER that is already queued.
        const id = self.next_id;
        self.next_id = @max(self.first_id, id +% 1);
        if (win.SetTimer(window, id, wait_ms, null) == 0) return false;
        self.armed = .{ .id = id, .kind = kind };
        return true;
    }

    pub fn cancel(self: *Timer, window: win.HWND) void {
        const timer = self.armed orelse return;
        self.armed = null;
        _ = win.KillTimer(window, timer.id);
    }

    pub fn matches(self: Timer, id: win.UINT_PTR) ?Kind {
        const timer = self.armed orelse return null;
        return if (timer.id == id) timer.kind else null;
    }
};
