-- Select the HDMI profile by the connected monitor's identity, not its GPU
-- address or HDMI port number. Keep the normal policy when it is absent.
local cutils = require ("common-utils")
local log = Log.open_topic ("s-prefer-mi-monitor")

local function route_monitor (route)
  -- SPA Route.info is a Struct: pair count followed by key/value pairs.
  local info = route.info or {}
  for i = 2, #info, 2 do
    if info[i] == "device.product.name" then
      return info[i + 1]
    end
  end
end

local function monitor_profile (device)
  local candidates = {}
  for param in device:iterate_params ("EnumRoute") do
    local route = cutils.parseParam (param, "EnumRoute")
    if route and route.direction == "Output" and route.available == "yes"
        and route_monitor (route) == "Mi Monitor" then
      for _, index in ipairs (route.profiles or {}) do
        candidates[index] = true
      end
    end
  end

  local best
  for param in device:iterate_params ("EnumProfile") do
    local profile = cutils.parseParam (param, "EnumProfile")
    if profile and candidates[profile.index] and profile.available ~= "no"
        and (not best or profile.priority > best.priority) then
      best = profile
    end
  end
  return best
end

SimpleEventHook {
  name = "device/prefer-mi-monitor",
  after = "device/find-preferred-profile",
  before = "device/find-best-profile",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-profile" },
      Constraint { "device.api", "=", "alsa" },
    },
  },
  execute = function (event)
    local device = event:get_subject ()
    local profile = monitor_profile (device)
    if profile then
      -- Override saved port numbers as well: cabling/topology may have changed.
      log:info (device, "Selecting Mi Monitor profile: " .. profile.name)
      event:set_data ("selected-profile", profile)
    end
  end,
}:register ()

-- The stock profile selector watches EnumProfile. Also watch EnumRoute so a
-- monitor identity change on an already-available port is handled.
SimpleEventHook {
  name = "device/reselect-mi-monitor",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "device-params-changed" },
      Constraint { "event.subject.param-id", "=", "EnumRoute" },
      Constraint { "device.api", "=", "alsa" },
    },
  },
  execute = function (event)
    local device = event:get_subject ()
    local profile = monitor_profile (device)
    if not profile then return end
    for param in device:iterate_params ("Profile") do
      local active = cutils.parseParam (param, "Profile")
      if active and active.index == profile.index then return end
    end
    event:get_source ():call ("push-event", "select-profile", device, nil)
  end,
}:register ()
