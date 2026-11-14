#include <GameControllerKit/game_device.h>
#include <GameControllerKit/game_pad.h>
#include <multimodalinput/oh_key_code.h>
#include <napi/native_api.h>
#include <dlfcn.h>
#include <atomic>
#include <deque>
#include <mutex>

namespace {
enum class EventKind { Button, LeftStick, Dpad };
struct Event {
    EventKind kind;
    int code = 0;
    bool down = false;
    double x = 0;
    double y = 0;
};

void* kit = nullptr;
std::atomic<bool> active{false};
std::atomic<bool> capturing{false};
std::mutex mutex;
std::deque<Event> events;
decltype(&OH_GamePad_ButtonEvent_GetButtonAction) getButtonAction = nullptr;
decltype(&OH_GamePad_AxisEvent_GetXAxisValue) getX = nullptr;
decltype(&OH_GamePad_AxisEvent_GetYAxisValue) getY = nullptr;
decltype(&OH_GamePad_AxisEvent_GetHatXAxisValue) getHatX = nullptr;
decltype(&OH_GamePad_AxisEvent_GetHatYAxisValue) getHatY = nullptr;
bool deviceMonitorActive = false;
unsigned activeMask = 0;

template <typename Function>
Function Symbol(const char* name)
{
    return reinterpret_cast<Function>(dlsym(kit, name));
}

void Push(const Event& event)
{
    if (!active.load() || !capturing.load()) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex);
    if (!active.load() || !capturing.load()) {
        return;
    }
    if (events.size() >= 128) {
        events.pop_front();
    }
    events.push_back(event);
}

template <int code>
void Button(const GamePad_ButtonEvent* event)
{
    GamePad_Button_ActionType action;
    if (active.load() && getButtonAction(event, &action) == GAME_CONTROLLER_SUCCESS) {
        Push({EventKind::Button, code, action == DOWN});
    }
}

template <EventKind kind>
void Axis(const GamePad_AxisEvent* event)
{
    if (!active.load()) {
        return;
    }
    Event result{kind};
    auto readX = kind == EventKind::Dpad ? getHatX : getX;
    auto readY = kind == EventKind::Dpad ? getHatY : getY;
    if (readX(event, &result.x) == GAME_CONTROLLER_SUCCESS &&
        readY(event, &result.y) == GAME_CONTROLLER_SUCCESS) {
        Push(result);
    }
}

using RegisterButton = GameController_ErrorCode (*)(GamePad_ButtonInputMonitorCallback);
using RegisterAxis = GameController_ErrorCode (*)(GamePad_AxisInputMonitorCallback);
using Unregister = GameController_ErrorCode (*)();

struct ButtonMonitor {
    const char* add;
    const char* remove;
    GamePad_ButtonInputMonitorCallback callback;
};

struct AxisMonitor {
    const char* add;
    const char* remove;
    GamePad_AxisInputMonitorCallback callback;
};

constexpr ButtonMonitor buttons[] = {
    {"OH_GamePad_ButtonA_RegisterButtonInputMonitor", "OH_GamePad_ButtonA_UnregisterButtonInputMonitor",
        Button<KEYCODE_BUTTON_A>},
    {"OH_GamePad_ButtonB_RegisterButtonInputMonitor", "OH_GamePad_ButtonB_UnregisterButtonInputMonitor",
        Button<KEYCODE_BUTTON_B>},
    {"OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor", "OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor",
        Button<KEYCODE_DPAD_LEFT>},
    {"OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor", "OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor",
        Button<KEYCODE_DPAD_RIGHT>},
    {"OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor", "OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor",
        Button<KEYCODE_DPAD_UP>},
    {"OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor", "OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor",
        Button<KEYCODE_DPAD_DOWN>}
};
constexpr AxisMonitor axes[] = {
    {"OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor", "OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor",
        Axis<EventKind::LeftStick>},
    {"OH_GamePad_Dpad_RegisterAxisInputMonitor", "OH_GamePad_Dpad_UnregisterAxisInputMonitor", Axis<EventKind::Dpad>}
};

void DeviceChanged(const GameDevice_DeviceEvent*) {}

void Stop()
{
    active.store(false);
    capturing.store(false);
    if (kit != nullptr) {
        unsigned bit = 1;
        for (const auto& monitor : buttons) {
            if (activeMask & bit) {
                Symbol<Unregister>(monitor.remove)();
            }
            bit <<= 1;
        }
        for (const auto& monitor : axes) {
            if (activeMask & bit) {
                Symbol<Unregister>(monitor.remove)();
            }
            bit <<= 1;
        }
        if (deviceMonitorActive) {
            Symbol<Unregister>("OH_GameDevice_UnregisterDeviceMonitor")();
        }
    }
    deviceMonitorActive = false;
    activeMask = 0;
    std::lock_guard<std::mutex> lock(mutex);
    events.clear();
}

unsigned Start()
{
    Stop();
    if (kit == nullptr) {
        kit = dlopen("libohgame_controller.z.so", RTLD_NOW | RTLD_LOCAL);
        if (kit == nullptr) {
            return 0;
        }
        getButtonAction = Symbol<decltype(getButtonAction)>("OH_GamePad_ButtonEvent_GetButtonAction");
        getX = Symbol<decltype(getX)>("OH_GamePad_AxisEvent_GetXAxisValue");
        getY = Symbol<decltype(getY)>("OH_GamePad_AxisEvent_GetYAxisValue");
        getHatX = Symbol<decltype(getHatX)>("OH_GamePad_AxisEvent_GetHatXAxisValue");
        getHatY = Symbol<decltype(getHatY)>("OH_GamePad_AxisEvent_GetHatYAxisValue");
    }
    auto monitorDevice = Symbol<decltype(&OH_GameDevice_RegisterDeviceMonitor)>("OH_GameDevice_RegisterDeviceMonitor");
    if (monitorDevice != nullptr && Symbol<Unregister>("OH_GameDevice_UnregisterDeviceMonitor") != nullptr) {
        deviceMonitorActive = monitorDevice(DeviceChanged) == GAME_CONTROLLER_SUCCESS;
    }
    active.store(true);
    unsigned bit = 1;
    for (const auto& monitor : buttons) {
        auto add = Symbol<RegisterButton>(monitor.add);
        if (getButtonAction != nullptr && add != nullptr && Symbol<Unregister>(monitor.remove) != nullptr &&
            add(monitor.callback) == GAME_CONTROLLER_SUCCESS) {
            activeMask |= bit;
        }
        bit <<= 1;
    }
    for (const auto& monitor : axes) {
        auto add = Symbol<RegisterAxis>(monitor.add);
        if (getX != nullptr && getY != nullptr && getHatX != nullptr && getHatY != nullptr &&
            add != nullptr && Symbol<Unregister>(monitor.remove) != nullptr &&
            add(monitor.callback) == GAME_CONTROLLER_SUCCESS) {
            activeMask |= bit;
        }
        bit <<= 1;
    }
    if (activeMask == 0) {
        Stop();
    }
    return activeMask;
}

napi_value StartJs(napi_env env, napi_callback_info)
{
    napi_value result;
    napi_create_uint32(env, Start(), &result);
    return result;
}

napi_value StopJs(napi_env env, napi_callback_info)
{
    Stop();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

napi_value CaptureJs(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argument;
    napi_get_cb_info(env, info, &argc, &argument, nullptr, nullptr);
    bool enabled = false;
    if (argc == 1) {
        napi_get_value_bool(env, argument, &enabled);
    }
    {
        std::lock_guard<std::mutex> lock(mutex);
        events.clear();
        capturing.store(enabled);
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

void SetNumber(napi_env env, napi_value object, const char* key, double value)
{
    napi_value property;
    napi_create_double(env, value, &property);
    napi_set_named_property(env, object, key, property);
}

napi_value ReadJs(napi_env env, napi_callback_info)
{
    std::deque<Event> pending;
    {
        std::lock_guard<std::mutex> lock(mutex);
        pending.swap(events);
    }
    napi_value result;
    napi_create_array_with_length(env, pending.size(), &result);
    uint32_t index = 0;
    for (const auto& event : pending) {
        napi_value item;
        napi_create_object(env, &item);
        SetNumber(env, item, "kind", static_cast<int>(event.kind));
        SetNumber(env, item, "code", event.code);
        SetNumber(env, item, "x", event.x);
        SetNumber(env, item, "y", event.y);
        napi_value down;
        napi_get_boolean(env, event.down, &down);
        napi_set_named_property(env, item, "down", down);
        napi_set_element(env, result, index++, item);
    }
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    const napi_property_descriptor methods[] = {
        {"start", nullptr, StartJs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, StopJs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"capture", nullptr, CaptureJs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"read", nullptr, ReadJs, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
    return exports;
}

napi_module module = {1, 0, nullptr, Init, "linkfiles_pad", nullptr, {0}};
}

extern "C" __attribute__((constructor)) void RegisterLinkfilesPad()
{
    napi_module_register(&module);
}
