-- Mission Editor DO SCRIPT FILE, after authored-control.lua has run.
-- Removes only its named test group. When DCS reports all four terminals free,
-- run authored-control.lua again; it will use the fresh name set below.
local prior = "Issue3-EmptyAuthored-AH64"
local group = assert(Group.getByName(prior), "authored control group is absent")
assert(group:isExist(), "authored control group no longer exists")
local base = assert(Airbase.getByName("Static FARP-1-1"))
assert(base:getCoalition() == coalition.side.BLUE)
local started = timer.getTime()
env.info("[issue3 recycle] destroying=" .. prior .. " time=" .. started
  .. " free_before=" .. #base:getParking(true))
group:destroy()
_G.__issue3_authored_case_name = nil
local function check(_, time)
  local free = #base:getParking(true)
  if free == 4 then
    _G.__issue3_authored_case_name = "Issue3-EmptyAuthored-Reuse-" .. math.floor(time)
    env.info("[issue3 recycle] ready time=" .. time .. " free=4 next="
      .. _G.__issue3_authored_case_name .. " run authored-control.lua now")
    return nil
  end
  if time - started >= 60 then
    env.info("[issue3 recycle] timeout time=" .. time .. " free=" .. free
      .. " no second spawn requested")
    return nil
  end
  return time + 1
end
timer.scheduleFunction(check, nil, started + 1)
