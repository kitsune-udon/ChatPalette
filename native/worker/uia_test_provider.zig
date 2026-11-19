const std = @import("std");
const win = @import("windows.zig");
const uia = @import("uia.zig");
const sdk = win.sdk;

pub const hwnd = 123;
pub const text = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Node = struct {
    element: win.Element = .{ .lpVtbl = &element_methods },
    parent: ?*Node = null,
    handle: usize = 0,
    kind: i32,
    id: []const u16 = &.{},
    class: []const u16 = &.{},
    name: []const u16 = &.{},
    value: []const u16 = &.{},
    focus_child: ?*Node = null,
    editable: bool = false,
    read_only: bool = false,
    enabled: bool = true,
    offscreen: bool = false,
    focused: bool = true,
    foreign: bool = false,
    parent_fails: bool = false,
    leaf_attributes_fail: bool = false,
    leaf_reads: usize = 0,
    focus_calls: usize = 0,
    geometry_reads: usize = 0,
    value_reads: usize = 0,
    refs: usize = 0,

    fn from(element: [*c]win.Element) *Node {
        return @fieldParentPtr("element", @as(*win.Element, element));
    }

    fn retain(element: [*c]win.Element) callconv(.c) sdk.ULONG {
        const self = from(element);
        self.refs += 1;
        return @intCast(self.refs);
    }

    fn release(element: [*c]win.Element) callconv(.c) sdk.ULONG {
        const self = from(element);
        self.refs -= 1;
        return @intCast(self.refs);
    }

    fn owned(self: *Node) *win.Element {
        _ = retain(&self.element);
        return &self.element;
    }

    pub fn expectReleased(self: Node) !void {
        try std.testing.expectEqual(@as(usize, 0), self.refs);
    }
};

var element_methods: sdk.IUIAutomationElementVtbl = .{
    .AddRef = Node.retain,
    .Release = Node.release,
    .FindFirst = findFirst,
    .FindAll = findAll,
    .GetCurrentPatternAs = getPattern,
    .get_CurrentAutomationId = getString("id"),
    .get_CurrentClassName = getString("class"),
    .get_CurrentName = getString("name"),
    .get_CurrentIsEnabled = leafFlag("enabled"),
    .get_CurrentIsOffscreen = leafFlag("offscreen"),
    .get_CurrentHasKeyboardFocus = hasFocus,
    .get_CurrentControlType = getKind,
    .get_CurrentNativeWindowHandle = getHandle,
    .SetFocus = setFocus,
    .GetClickablePoint = getClickablePoint,
};

var automation_methods: sdk.IUIAutomationVtbl = .{
    .ElementFromHandle = fromHandle,
    .CreatePropertyCondition = createCondition,
    .CreateAndCondition = combineConditions,
    .CreateOrCondition = combineConditions,
    .GetFocusedElement = getFocusedElement,
    .CompareElements = compareElements,
};
var walker_methods: sdk.IUIAutomationTreeWalkerVtbl = .{
    .NormalizeElement = normalize,
    .GetParentElement = getParent,
};
var array_methods: sdk.IUIAutomationElementArrayVtbl = .{
    .Release = releaseStub(win.Elements),
    .get_Length = length,
    .GetElement = getElement,
};
var condition_methods: sdk.IUIAutomationConditionVtbl = .{ .Release = releaseStub(win.Condition) };
var value_methods: sdk.IUIAutomationValuePatternVtbl = .{
    .Release = releaseStub(sdk.IUIAutomationValuePattern),
    .get_CurrentIsReadOnly = isReadOnly,
    .get_CurrentValue = getValue,
};
var automation: win.Automation = .{ .lpVtbl = &automation_methods };
var walker: win.Walker = .{ .lpVtbl = &walker_methods };
var elements: win.Elements = .{ .lpVtbl = &array_methods };
var condition: win.Condition = .{ .lpVtbl = &condition_methods };
var value_pattern: sdk.IUIAutomationValuePattern = .{ .lpVtbl = &value_methods };
threadlocal var value_owner: *Node = undefined;
threadlocal var root: *Node = undefined;
threadlocal var candidates: []const *Node = &.{};
threadlocal var focus: ?*Node = null;
threadlocal var later_focus: ?*Node = null;
threadlocal var focus_reads: usize = 0;
pub threadlocal var candidate_reads: usize = 0;

pub fn setCandidates(root_node: *Node, results: []const *Node) void {
    root = root_node;
    candidates = results;
    candidate_reads = 0;
}

pub fn setFocusObservations(first: ?*Node, later: ?*Node) void {
    focus = first;
    later_focus = later;
    focus_reads = 0;
}

pub fn client() uia.Client {
    // Only the COM calls needed for discovery and focus observation exist.
    return .{ .automation = &automation, .raw = &walker, .control = &walker, .address_controls = &condition };
}

pub fn window() uia.Window {
    return .{ .hwnd = hwnd, .walker = &walker };
}

fn releaseStub(comptime T: type) *const fn ([*c]T) callconv(.c) sdk.ULONG {
    return &struct {
        fn release(_: [*c]T) callconv(.c) sdk.ULONG {
            return 0;
        }
    }.release;
}

fn getString(comptime field: []const u8) *const fn ([*c]win.Element, [*c]sdk.BSTR) callconv(.c) sdk.HRESULT {
    return &struct {
        fn read(element: [*c]win.Element, out: [*c]sdk.BSTR) callconv(.c) sdk.HRESULT {
            const node = Node.from(element);
            if (comptime std.mem.eql(u8, field, "name")) {
                node.leaf_reads += 1;
                if (node.leaf_attributes_fail) return sdk.E_FAIL;
            }
            return writeBstr(@field(node, field), out);
        }
    }.read;
}

fn writeBstr(value: []const u16, out: [*c]sdk.BSTR) sdk.HRESULT {
    out[0] = if (value.len == 0) null else sdk.SysAllocStringLen(value.ptr, @intCast(value.len));
    return if (value.len == 0 or out[0] != null) sdk.S_OK else sdk.E_OUTOFMEMORY;
}

fn leafFlag(comptime field: []const u8) *const fn ([*c]win.Element, [*c]sdk.BOOL) callconv(.c) sdk.HRESULT {
    return &struct {
        fn read(element: [*c]win.Element, out: [*c]sdk.BOOL) callconv(.c) sdk.HRESULT {
            const node = Node.from(element);
            node.leaf_reads += 1;
            if (node.leaf_attributes_fail) return sdk.E_FAIL;
            out[0] = @intFromBool(@field(node, field));
            return sdk.S_OK;
        }
    }.read;
}

fn getKind(element: [*c]win.Element, out: [*c]sdk.CONTROLTYPEID) callconv(.c) sdk.HRESULT {
    out[0] = Node.from(element).kind;
    return sdk.S_OK;
}

fn getHandle(element: [*c]win.Element, out: [*c]sdk.UIA_HWND) callconv(.c) sdk.HRESULT {
    out[0] = @ptrFromInt(Node.from(element).handle);
    return sdk.S_OK;
}

fn hasFocus(element: [*c]win.Element, out: [*c]sdk.BOOL) callconv(.c) sdk.HRESULT {
    out[0] = @intFromBool(Node.from(element).focused);
    return sdk.S_OK;
}

fn getPattern(element: [*c]win.Element, pattern: sdk.PATTERNID, _: [*c]const sdk.IID, out: [*c]?*anyopaque) callconv(.c) sdk.HRESULT {
    const node = Node.from(element);
    if (pattern != sdk.UIA_ValuePatternId or !node.editable) return sdk.E_NOINTERFACE;
    value_owner = node;
    out[0] = &value_pattern;
    return sdk.S_OK;
}

fn isReadOnly(_: [*c]sdk.IUIAutomationValuePattern, out: [*c]sdk.BOOL) callconv(.c) sdk.HRESULT {
    out[0] = @intFromBool(value_owner.read_only);
    return sdk.S_OK;
}

fn getValue(_: [*c]sdk.IUIAutomationValuePattern, out: [*c]sdk.BSTR) callconv(.c) sdk.HRESULT {
    const node = value_owner;
    node.value_reads += 1;
    return writeBstr(node.value, out);
}

fn setFocus(element: [*c]win.Element) callconv(.c) sdk.HRESULT {
    Node.from(element).focus_calls += 1;
    return sdk.E_FAIL;
}

fn getClickablePoint(element: [*c]win.Element, _: [*c]win.Point, known: [*c]sdk.BOOL) callconv(.c) sdk.HRESULT {
    Node.from(element).geometry_reads += 1;
    known[0] = sdk.FALSE;
    return sdk.S_OK;
}

fn normalize(_: [*c]win.Walker, element: [*c]win.Element, out: [*c][*c]win.Element) callconv(.c) sdk.HRESULT {
    const node = Node.from(element);
    out[0] = if (node.foreign) null else node.owned();
    return sdk.S_OK;
}

fn getParent(_: [*c]win.Walker, element: [*c]win.Element, out: [*c][*c]win.Element) callconv(.c) sdk.HRESULT {
    const node = Node.from(element);
    if (node.parent_fails) return @bitCast(@as(u32, sdk.UIA_E_ELEMENTNOTAVAILABLE));
    out[0] = if (node.parent) |parent| parent.owned() else null;
    return sdk.S_OK;
}

fn fromHandle(_: [*c]win.Automation, handle: sdk.UIA_HWND, out: [*c][*c]win.Element) callconv(.c) sdk.HRESULT {
    if (@intFromPtr(handle) != hwnd) return sdk.E_FAIL;
    out[0] = root.owned();
    return sdk.S_OK;
}

fn getFocusedElement(_: [*c]win.Automation, out: [*c][*c]win.Element) callconv(.c) sdk.HRESULT {
    const observed = if (focus_reads == 0) focus else later_focus;
    focus_reads += 1;
    out[0] = if (observed) |node| node.owned() else null;
    return sdk.S_OK;
}

fn compareElements(_: [*c]win.Automation, first: [*c]win.Element, second: [*c]win.Element, same: [*c]sdk.BOOL) callconv(.c) sdk.HRESULT {
    same[0] = @intFromBool(first == second);
    return sdk.S_OK;
}

fn createCondition(_: [*c]win.Automation, _: sdk.PROPERTYID, _: sdk.VARIANT, out: [*c][*c]win.Condition) callconv(.c) sdk.HRESULT {
    out[0] = &condition;
    return sdk.S_OK;
}

fn combineConditions(_: [*c]win.Automation, _: [*c]win.Condition, _: [*c]win.Condition, out: [*c][*c]win.Condition) callconv(.c) sdk.HRESULT {
    out[0] = &condition;
    return sdk.S_OK;
}

fn findAll(_: [*c]win.Element, scope: sdk.TreeScope, _: [*c]win.Condition, out: [*c][*c]win.Elements) callconv(.c) sdk.HRESULT {
    if (scope != sdk.TreeScope_Descendants) return sdk.E_FAIL;
    out[0] = &elements;
    return sdk.S_OK;
}

fn findFirst(element: [*c]win.Element, scope: sdk.TreeScope, _: [*c]win.Condition, out: [*c][*c]win.Element) callconv(.c) sdk.HRESULT {
    if (scope != sdk.TreeScope_Descendants) return sdk.E_FAIL;
    const child = Node.from(element).focus_child;
    out[0] = if (child != null and child.?.focused) child.?.owned() else null;
    return sdk.S_OK;
}

fn length(_: [*c]win.Elements, out: [*c]c_int) callconv(.c) sdk.HRESULT {
    out[0] = @intCast(candidates.len);
    return sdk.S_OK;
}

fn getElement(_: [*c]win.Elements, index: c_int, out: [*c][*c]win.Element) callconv(.c) sdk.HRESULT {
    candidate_reads += 1;
    out[0] = candidates[@intCast(index)].owned();
    return sdk.S_OK;
}
