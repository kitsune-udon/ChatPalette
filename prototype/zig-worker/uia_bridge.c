/* Windows SDK types and COM calls. Browser policy and object lifetime live in uia.zig. */
#define COBJMACROS
#include <windows.h>
#include <oleauto.h>
#include <initguid.h>
#include <uiautomation.h>

HRESULT cp_client(IUIAutomation **out) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) return hr;
    hr = CoCreateInstance(&CLSID_CUIAutomation, NULL, CLSCTX_INPROC_SERVER,
                          &IID_IUIAutomation, (void **)out);
    if (FAILED(hr)) CoUninitialize();
    return hr;
}

void cp_uninit(void) { CoUninitialize(); }
void cp_release(IUnknown *obj) { IUnknown_Release(obj); }
void cp_retain(IUnknown *obj) { IUnknown_AddRef(obj); }
void cp_free_string(BSTR value) { SysFreeString(value); }
UINT cp_string_length(BSTR value) { return SysStringLen(value); }

static HRESULT integer_condition(IUIAutomation *client, PROPERTYID prop, LONG value,
                                 IUIAutomationCondition **out) {
    VARIANT v;
    VariantInit(&v);
    V_VT(&v) = VT_I4;
    V_I4(&v) = value;
    return IUIAutomation_CreatePropertyCondition(client, prop, v, out);
}

HRESULT cp_edit_condition(IUIAutomation *client, IUIAutomationCondition **out) {
    return integer_condition(client, UIA_ControlTypePropertyId, UIA_EditControlTypeId, out);
}

HRESULT cp_window_walker(IUIAutomation *client, UINT_PTR hwnd, IUIAutomationTreeWalker **out) {
    IUIAutomationCondition *condition = NULL;
    HRESULT hr = integer_condition(client, UIA_NativeWindowHandlePropertyId, (LONG)hwnd, &condition);
    if (FAILED(hr)) return hr;
    hr = IUIAutomation_CreateTreeWalker(client, condition, out);
    IUIAutomationCondition_Release(condition);
    return hr;
}

HRESULT cp_raw(IUIAutomation *client, IUIAutomationTreeWalker **out) {
    return IUIAutomation_get_RawViewWalker(client, out);
}
HRESULT cp_control(IUIAutomation *client, IUIAutomationTreeWalker **out) {
    return IUIAutomation_get_ControlViewWalker(client, out);
}
HRESULT cp_root(IUIAutomation *client, UINT_PTR hwnd, IUIAutomationElement **out) {
    return IUIAutomation_ElementFromHandle(client, (UIA_HWND)hwnd, out);
}
HRESULT cp_focused(IUIAutomation *client, IUIAutomationElement **out) {
    return IUIAutomation_GetFocusedElement(client, out);
}
HRESULT cp_same(IUIAutomation *client, IUIAutomationElement *a, IUIAutomationElement *b, BOOL *same) {
    return IUIAutomation_CompareElements(client, a, b, same);
}
HRESULT cp_normalize(IUIAutomationTreeWalker *walker, IUIAutomationElement *element, IUIAutomationElement **out) {
    return IUIAutomationTreeWalker_NormalizeElement(walker, element, out);
}
HRESULT cp_parent(IUIAutomationTreeWalker *walker, IUIAutomationElement *element, IUIAutomationElement **out) {
    return IUIAutomationTreeWalker_GetParentElement(walker, element, out);
}
HRESULT cp_find_edits(IUIAutomationElement *root, IUIAutomationCondition *condition, IUIAutomationElementArray **out) {
    return IUIAutomationElement_FindAll(root, TreeScope_Descendants, condition, out);
}
HRESULT cp_length(IUIAutomationElementArray *array, int *out) {
    return IUIAutomationElementArray_get_Length(array, out);
}
HRESULT cp_at(IUIAutomationElementArray *array, int i, IUIAutomationElement **out) {
    return IUIAutomationElementArray_GetElement(array, i, out);
}

HRESULT cp_hwnd(IUIAutomationElement *element, UIA_HWND *out) {
    return IUIAutomationElement_get_CurrentNativeWindowHandle(element, out);
}
HRESULT cp_type(IUIAutomationElement *element, CONTROLTYPEID *out) {
    return IUIAutomationElement_get_CurrentControlType(element, out);
}
HRESULT cp_id(IUIAutomationElement *element, BSTR *out) {
    return IUIAutomationElement_get_CurrentAutomationId(element, out);
}
HRESULT cp_name(IUIAutomationElement *element, BSTR *out) {
    return IUIAutomationElement_get_CurrentName(element, out);
}
HRESULT cp_class(IUIAutomationElement *element, BSTR *out) {
    return IUIAutomationElement_get_CurrentClassName(element, out);
}
HRESULT cp_has_focus(IUIAutomationElement *element, BOOL *out) {
    return IUIAutomationElement_get_CurrentHasKeyboardFocus(element, out);
}
HRESULT cp_enabled(IUIAutomationElement *element, BOOL *out) {
    return IUIAutomationElement_get_CurrentIsEnabled(element, out);
}
HRESULT cp_hidden(IUIAutomationElement *element, BOOL *out) {
    return IUIAutomationElement_get_CurrentIsOffscreen(element, out);
}
HRESULT cp_address_value(IUIAutomationElement *element, BSTR *out) {
    IUIAutomationValuePattern *pattern = NULL;
    HRESULT hr = IUIAutomationElement_GetCurrentPatternAs(element, UIA_ValuePatternId,
        &IID_IUIAutomationValuePattern, (void **)&pattern);
    if (FAILED(hr)) return hr;
    if (!pattern) return E_NOINTERFACE;
    hr = IUIAutomationValuePattern_get_CurrentValue(pattern, out);
    IUIAutomationValuePattern_Release(pattern);
    return hr;
}

/* Query only editability. Never retrieve the focused control's text. */
HRESULT cp_editable(IUIAutomationElement *element, BOOL *out) {
    IUIAutomationValuePattern *value = NULL;
    IUIAutomationTextPattern *text = NULL;
    IUIAutomationTextRange *range = NULL;
    *out = FALSE;
    HRESULT hr = IUIAutomationElement_GetCurrentPatternAs(element, UIA_ValuePatternId,
        &IID_IUIAutomationValuePattern, (void **)&value);
    if (FAILED(hr) && hr != UIA_E_NOTSUPPORTED && hr != E_NOINTERFACE) return hr;
    if (value) {
        BOOL readonly = TRUE;
        hr = IUIAutomationValuePattern_get_CurrentIsReadOnly(value, &readonly);
        IUIAutomationValuePattern_Release(value);
        if (SUCCEEDED(hr)) *out = !readonly;
        return hr;
    }
    hr = IUIAutomationElement_GetCurrentPatternAs(element, UIA_TextPatternId,
        &IID_IUIAutomationTextPattern, (void **)&text);
    if (hr == UIA_E_NOTSUPPORTED || hr == E_NOINTERFACE) return S_OK;
    if (FAILED(hr) || !text) return hr;
    hr = IUIAutomationTextPattern_get_DocumentRange(text, &range);
    IUIAutomationTextPattern_Release(text);
    if (FAILED(hr) || !range) return hr;
    VARIANT attribute;
    VariantInit(&attribute);
    hr = IUIAutomationTextRange_GetAttributeValue(range, UIA_IsReadOnlyAttributeId, &attribute);
    if (SUCCEEDED(hr)) *out = V_VT(&attribute) == VT_BOOL && V_BOOL(&attribute) == VARIANT_FALSE;
    VariantClear(&attribute);
    IUIAutomationTextRange_Release(range);
    return hr;
}
