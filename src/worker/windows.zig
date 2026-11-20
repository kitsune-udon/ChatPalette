const std = @import("std");

pub const sdk = @cImport({
    // HWND is an encoded Win32 handle. SDK tag structs impose alignment that HWND values do not have.
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("oleauto.h");
    @cInclude("uiautomation.h");
    @cInclude("winhttp.h");
});

pub const Automation = sdk.IUIAutomation;
pub const Element = sdk.IUIAutomationElement;
pub const Walker = sdk.IUIAutomationTreeWalker;
pub const Condition = sdk.IUIAutomationCondition;
pub const Elements = sdk.IUIAutomationElementArray;
pub const Point = sdk.POINT;

pub fn windowProcessId(hwnd: usize) u32 {
    var pid: u32 = 0;
    _ = sdk.GetWindowThreadProcessId(@ptrFromInt(hwnd), &pid);
    return pid;
}

// Values are the DEFINE_GUID constants in uiautomationclient.h.
fn guid(a: u32, b: u16, c: u16, d: [8]u8) sdk.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = c, .Data4 = d };
}
const automation_class = guid(0xff48dba4, 0x60ef, 0x4201, .{ 0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e });
const automation_iid = guid(0x30cbe57d, 0xd9d0, 0x452a, .{ 0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee });
const value_iid = guid(0xa94cd8b1, 0x0844, 0x4cd6, .{ 0x9d, 0x2d, 0x64, 0x05, 0x37, 0xab, 0x39, 0xe9 });
const text_iid = guid(0x32eba289, 0x3583, 0x42c9, .{ 0x9c, 0x59, 0x3b, 0x6d, 0x9a, 0x1e, 0x9b, 0x6a });
const invoke_iid = guid(0xfb377fbe, 0x8ea6, 0x46d5, .{ 0x9c, 0x73, 0x64, 0x99, 0x64, 0x2d, 0x30, 0x59 });
const legacy_iid = guid(0x828055ad, 0x355b, 0x4435, .{ 0x86, 0xd5, 0x3b, 0x51, 0xc1, 0x4a, 0x9b, 0x1b });

pub fn acquire() !*Automation {
    try check(sdk.CoInitializeEx(null, sdk.COINIT_MULTITHREADED));
    errdefer sdk.CoUninitialize();
    var out: ?*anyopaque = null;
    try check(sdk.CoCreateInstance(&automation_class, null, sdk.CLSCTX_INPROC_SERVER, &automation_iid, &out));
    return @ptrCast(@alignCast(out orelse return error.AutomationUnavailable));
}

pub fn check(hr: sdk.HRESULT) !void {
    if (hr < 0) return error.AutomationUnavailable;
}

pub fn call(comptime method: []const u8, instance: anytype, arguments: anytype) sdk.HRESULT {
    return @call(.auto, @field(instance.lpVtbl.*, method).?, .{instance} ++ arguments);
}

pub fn release(instance: anytype) void {
    _ = instance.lpVtbl.*.Release.?(instance);
}

pub fn retain(instance: anytype) void {
    _ = instance.lpVtbl.*.AddRef.?(instance);
}

pub fn get(comptime T: type, comptime method: []const u8, instance: anytype, arguments: anytype) !T {
    var out = std.mem.zeroes(T);
    try check(call(method, instance, arguments ++ .{&out}));
    return out;
}

pub fn objectOrNull(comptime T: type, comptime method: []const u8, instance: anytype, arguments: anytype) !?*T {
    return try get([*c]T, method, instance, arguments);
}

pub fn object(comptime T: type, comptime method: []const u8, instance: anytype, arguments: anytype) !*T {
    return (try objectOrNull(T, method, instance, arguments)) orelse error.AutomationUnavailable;
}

pub fn flag(comptime method: []const u8, element: *Element) !bool {
    return try get(sdk.BOOL, method, element, .{}) != sdk.FALSE;
}

pub fn string(allocator: std.mem.Allocator, comptime method: []const u8, instance: anytype) ![]const u8 {
    const value = try get(sdk.BSTR, method, instance, .{});
    defer sdk.SysFreeString(value);
    if (value == null) return "";
    return std.unicode.utf16LeToUtf8Alloc(allocator, value[0..sdk.SysStringLen(value)]);
}

fn integerVariant(value: i32) sdk.VARIANT {
    var variant = std.mem.zeroes(sdk.VARIANT);
    variant.unnamed_0.unnamed_0.vt = sdk.VT_I4;
    variant.unnamed_0.unnamed_0.unnamed_0.lVal = value;
    return variant;
}

pub fn integerCondition(client: *Automation, property: i32, value: i32) !*Condition {
    return object(Condition, "CreatePropertyCondition", client, .{ property, integerVariant(value) });
}

pub fn booleanCondition(client: *Automation, property: i32) !*Condition {
    var variant = std.mem.zeroes(sdk.VARIANT);
    variant.unnamed_0.unnamed_0.vt = sdk.VT_BOOL;
    variant.unnamed_0.unnamed_0.unnamed_0.boolVal = sdk.VARIANT_TRUE;
    return object(Condition, "CreatePropertyCondition", client, .{ property, variant });
}

pub fn textCondition(client: *Automation, property: i32, text: []const u8) !*Condition {
    const allocator = std.heap.page_allocator;
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(utf16);
    const value = sdk.SysAllocStringLen(utf16.ptr, @intCast(utf16.len));
    if (value == null) return error.OutOfMemory;
    defer sdk.SysFreeString(value);
    var variant = std.mem.zeroes(sdk.VARIANT);
    variant.unnamed_0.unnamed_0.vt = sdk.VT_BSTR;
    variant.unnamed_0.unnamed_0.unnamed_0.bstrVal = value;
    return object(Condition, "CreatePropertyCondition", client, .{ property, variant });
}

pub fn pattern(comptime T: type, element: *Element, id: i32, iid: *const sdk.GUID) !?*T {
    var out: ?*anyopaque = null;
    const hr = call("GetCurrentPatternAs", element, .{ id, iid, &out });
    if (hr == sdk.E_NOINTERFACE or @as(u32, @bitCast(hr)) == 0x80040204) return null;
    try check(hr);
    return @ptrCast(@alignCast(out));
}

pub fn address(allocator: std.mem.Allocator, element: *Element) ![]const u8 {
    const value = (try pattern(sdk.IUIAutomationValuePattern, element, sdk.UIA_ValuePatternId, &value_iid)) orelse
        return error.StaleAddress;
    defer release(value);
    return string(allocator, "get_CurrentValue", value);
}

pub fn editable(element: *Element) !bool {
    if (try pattern(sdk.IUIAutomationValuePattern, element, sdk.UIA_ValuePatternId, &value_iid)) |value| {
        defer release(value);
        return try get(sdk.BOOL, "get_CurrentIsReadOnly", value, .{}) == sdk.FALSE;
    }
    const text = (try pattern(sdk.IUIAutomationTextPattern, element, sdk.UIA_TextPatternId, &text_iid)) orelse return false;
    defer release(text);
    const range = (try objectOrNull(sdk.IUIAutomationTextRange, "get_DocumentRange", text, .{})) orelse return false;
    defer release(range);
    var attribute = std.mem.zeroes(sdk.VARIANT);
    defer _ = sdk.VariantClear(&attribute);
    try check(call("GetAttributeValue", range, .{ sdk.UIA_IsReadOnlyAttributeId, &attribute }));
    const data = attribute.unnamed_0.unnamed_0;
    return data.vt == sdk.VT_BOOL and data.unnamed_0.boolVal == sdk.VARIANT_FALSE;
}

pub const Invoker = union(enum) {
    invoke: *sdk.IUIAutomationInvokePattern,
    legacy: *sdk.IUIAutomationLegacyIAccessiblePattern,

    pub fn releasePattern(self: Invoker) void {
        switch (self) {
            inline else => |ptr| release(ptr),
        }
    }

    pub fn operate(self: Invoker) !void {
        try check(switch (self) {
            .invoke => |ptr| call("Invoke", ptr, .{}),
            .legacy => |ptr| call("DoDefaultAction", ptr, .{}),
        });
    }
};

pub fn invoker(element: *Element) !?Invoker {
    if (try pattern(sdk.IUIAutomationInvokePattern, element, sdk.UIA_InvokePatternId, &invoke_iid)) |ptr|
        return .{ .invoke = ptr };
    const legacy = (try pattern(sdk.IUIAutomationLegacyIAccessiblePattern, element, sdk.UIA_LegacyIAccessiblePatternId, &legacy_iid)) orelse return null;
    errdefer release(legacy);
    if (try get(sdk.DWORD, "get_CurrentRole", legacy, .{}) != 43) {
        release(legacy);
        return null;
    }
    return .{ .legacy = legacy };
}

test "Win32 accepts opaque handle values with low bits set" {
    const raw: usize = 2;
    const hwnd: sdk.HWND = @ptrFromInt(raw);
    try std.testing.expectEqual(raw, @intFromPtr(hwnd));
    _ = sdk.IsWindow(hwnd);
    _ = windowProcessId(raw);
}

test "TextPattern is editable only when IsReadOnly is explicitly false" {
    const Provider = struct {
        const Observation = enum { editable, read_only, unsupported, mixed, no_range, no_pattern, failure };
        threadlocal var observation: Observation = .editable;
        threadlocal var text_releases: usize = 0;
        threadlocal var range_releases: usize = 0;
        var element_methods: sdk.IUIAutomationElementVtbl = .{ .GetCurrentPatternAs = patternAs };
        var text_methods: sdk.IUIAutomationTextPatternVtbl = .{ .get_DocumentRange = getRange, .Release = releaseText };
        var range_methods: sdk.IUIAutomationTextRangeVtbl = .{ .GetAttributeValue = getAttribute, .Release = releaseRange };
        var element: Element = .{ .lpVtbl = &element_methods };
        var text: sdk.IUIAutomationTextPattern = .{ .lpVtbl = &text_methods };
        var range: sdk.IUIAutomationTextRange = .{ .lpVtbl = &range_methods };

        fn patternAs(_: [*c]Element, id: sdk.PATTERNID, _: [*c]const sdk.IID, out: [*c]?*anyopaque) callconv(.c) sdk.HRESULT {
            if (id != sdk.UIA_TextPatternId or observation == .no_pattern) return sdk.E_NOINTERFACE;
            out[0] = &text;
            return sdk.S_OK;
        }

        fn getRange(_: [*c]sdk.IUIAutomationTextPattern, out: [*c][*c]sdk.IUIAutomationTextRange) callconv(.c) sdk.HRESULT {
            out[0] = if (observation == .no_range) null else &range;
            return sdk.S_OK;
        }

        fn getAttribute(_: [*c]sdk.IUIAutomationTextRange, id: sdk.TEXTATTRIBUTEID, out: [*c]sdk.VARIANT) callconv(.c) sdk.HRESULT {
            if (id != sdk.UIA_IsReadOnlyAttributeId or observation == .failure) return sdk.E_FAIL;
            const value = &out[0].unnamed_0.unnamed_0;
            switch (observation) {
                .editable, .read_only => {
                    value.vt = sdk.VT_BOOL;
                    value.unnamed_0.boolVal = if (observation == .editable) sdk.VARIANT_FALSE else sdk.VARIANT_TRUE;
                },
                .unsupported => value.vt = sdk.VT_EMPTY,
                .mixed => value.vt = sdk.VT_UNKNOWN,
                else => unreachable,
            }
            return sdk.S_OK;
        }

        fn releaseText(_: [*c]sdk.IUIAutomationTextPattern) callconv(.c) sdk.ULONG {
            text_releases += 1;
            return 0;
        }

        fn releaseRange(_: [*c]sdk.IUIAutomationTextRange) callconv(.c) sdk.ULONG {
            range_releases += 1;
            return 0;
        }
    };

    for (std.enums.values(Provider.Observation)) |observation| {
        Provider.observation = observation;
        Provider.text_releases = 0;
        Provider.range_releases = 0;
        if (observation == .failure) {
            try std.testing.expectError(error.AutomationUnavailable, editable(&Provider.element));
        } else {
            try std.testing.expectEqual(observation == .editable, try editable(&Provider.element));
        }
        try std.testing.expectEqual(@as(usize, @intFromBool(observation != .no_pattern)), Provider.text_releases);
        try std.testing.expectEqual(@as(usize, @intFromBool(observation != .no_pattern and observation != .no_range)), Provider.range_releases);
    }
}

test "Invoke takes precedence and LegacyIAccessible acts only for the button role" {
    const Provider = struct {
        threadlocal var allow_invoke: bool = true;
        threadlocal var role: sdk.DWORD = 43;
        threadlocal var invokes: usize = 0;
        threadlocal var defaults: usize = 0;
        threadlocal var releases: usize = 0;
        var button_methods: sdk.IUIAutomationInvokePatternVtbl = .{ .Invoke = invoke, .Release = releaseInvoke };
        var legacy_methods: sdk.IUIAutomationLegacyIAccessiblePatternVtbl = .{
            .get_CurrentRole = getRole,
            .DoDefaultAction = doDefault,
            .Release = releaseLegacy,
        };
        var button: sdk.IUIAutomationInvokePattern = .{ .lpVtbl = &button_methods };
        var legacy: sdk.IUIAutomationLegacyIAccessiblePattern = .{ .lpVtbl = &legacy_methods };

        fn patternAs(_: [*c]Element, kind: sdk.PATTERNID, _: [*c]const sdk.IID, result: [*c]?*anyopaque) callconv(.c) sdk.HRESULT {
            result[0] = switch (kind) {
                sdk.UIA_InvokePatternId => if (allow_invoke) &button else return sdk.E_NOINTERFACE,
                sdk.UIA_LegacyIAccessiblePatternId => &legacy,
                else => return sdk.E_NOINTERFACE,
            };
            return sdk.S_OK;
        }
        fn getRole(_: [*c]sdk.IUIAutomationLegacyIAccessiblePattern, out: [*c]sdk.DWORD) callconv(.c) sdk.HRESULT {
            out[0] = role;
            return sdk.S_OK;
        }
        fn invoke(_: [*c]sdk.IUIAutomationInvokePattern) callconv(.c) sdk.HRESULT {
            invokes += 1;
            return sdk.S_OK;
        }
        fn doDefault(_: [*c]sdk.IUIAutomationLegacyIAccessiblePattern) callconv(.c) sdk.HRESULT {
            defaults += 1;
            return sdk.S_OK;
        }
        fn releaseInvoke(_: [*c]sdk.IUIAutomationInvokePattern) callconv(.c) sdk.ULONG {
            releases += 1;
            return 0;
        }
        fn releaseLegacy(_: [*c]sdk.IUIAutomationLegacyIAccessiblePattern) callconv(.c) sdk.ULONG {
            releases += 1;
            return 0;
        }
    };
    var table: sdk.IUIAutomationElementVtbl = .{ .GetCurrentPatternAs = Provider.patternAs };
    var element: Element = .{ .lpVtbl = &table };
    const native = (try invoker(&element)).?;
    try native.operate();
    native.releasePattern();
    Provider.allow_invoke = false;
    const fallback = (try invoker(&element)).?;
    try fallback.operate();
    fallback.releasePattern();
    Provider.role = 42;
    try std.testing.expect((try invoker(&element)) == null);
    try std.testing.expectEqual(@as(usize, 1), Provider.invokes);
    try std.testing.expectEqual(@as(usize, 1), Provider.defaults);
    try std.testing.expectEqual(@as(usize, 3), Provider.releases);
}
