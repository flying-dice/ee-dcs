-- Run in the same minimal Caucasus mission as authored-control.lua.
-- The runtime site was verified clear of units/statics within 300 m.
local farpName = "Issue3-Recheck-RuntimeFARP"
assert(StaticObject.getByName(farpName) == nil and Airbase.getByName(farpName) == nil)
local farp = coalition.addStaticObject(2, {
  name=farpName, type="FARP", shape_name="FARPS", category="Heliports",
  heading=0, x=-255436.609375, y=604143.375, dead=false,
  heliport_frequency="127.5", heliport_modulation=0, heliport_callsign_id=1,
})
assert(farp and farp:isExist())
local farpBase = assert(Airbase.getByName(farpName))
local initialSide = farpBase:getCoalition()
farpBase:autoCapture(false)
farpBase:setCoalition(coalition.side.BLUE)
assert(farpBase:getCoalition() == coalition.side.BLUE)
assert(#farpBase:getParking(true) == 4)
env.info("[issue3 runtime-farp] id=" .. farpBase:getID()
  .. " initial_side=" .. initialSide .. " side=" .. farpBase:getCoalition()
  .. " free=" .. #farpBase:getParking(true))
-- Spawn the exact same AH-64D group at the runtime FARP above.
local original = (function()
return {
								["dynSpawnTemplate"] = false,
								["modulation"] = 0,
								["tasks"] = {},
								["task"] = "CAS",
								["uncontrolled"] = false,
								["route"] = 
								{
									["points"] = 
									{
										[1] = 
										{
											["alt"] = 6,
											["action"] = "From Parking Area Hot",
											["alt_type"] = "BARO",
											["linkUnit"] = 1,
											["helipadId"] = 1,
											["speed"] = 41.666666666667,
											["task"] = 
											{
												["id"] = "ComboTask",
												["params"] = 
												{
													["tasks"] = 
													{
														[1] = 
														{
															["enabled"] = true,
															["key"] = "CAS",
															["id"] = "EngageTargets",
															["number"] = 1,
															["auto"] = true,
															["params"] = 
															{
																["targetTypes"] = 
																{
																	[1] = "Helicopters",
																	[2] = "Ground Units",
																	[3] = "Light armed ships",
																}, -- end of ["targetTypes"]
																["priority"] = 0,
															}, -- end of ["params"]
														}, -- end of [1]
													}, -- end of ["tasks"]
												}, -- end of ["params"]
											}, -- end of ["task"]
											["type"] = "TakeOffParkingHot",
											["ETA"] = 0,
											["ETA_locked"] = true,
											["y"] = 634249.46070276,
											["x"] = -324174.81816897,
											["speed_locked"] = true,
											["formation_template"] = "",
										}, -- end of [1]
										[2] = 
										{
											["alt"] = 11,
											["action"] = "Turning Point",
											["alt_type"] = "BARO",
											["speed"] = 55.555555555556,
											["task"] = 
											{
												["id"] = "ComboTask",
												["params"] = 
												{
													["tasks"] = {},
												}, -- end of ["params"]
											}, -- end of ["task"]
											["type"] = "Turning Point",
											["ETA"] = 15.767861522192,
											["ETA_locked"] = false,
											["y"] = 634950.10260963,
											["x"] = -323607.92281455,
											["speed_locked"] = true,
											["formation_template"] = "",
										}, -- end of [2]
									}, -- end of ["points"]
								}, -- end of ["route"]
								["groupId"] = 2,
								["hidden"] = false,
								["units"] = 
								{
									[1] = 
									{
										["alt"] = 6,
										["alt_type"] = "BARO",
										["livery_id"] = "ah-64_d_green neth",
										["skill"] = "High",
										["parking"] = "1",
										["speed"] = 41.666666666667,
										["type"] = "AH-64D",
										["unitId"] = 2,
										["psi"] = -0.89052601785946,
										["onboard_num"] = "010",
										["parking_id"] = "1",
										["x"] = -324174.81816897,
										["name"] = "Rotary-1-1",
										["payload"] = 
										{
											["pylons"] = 
											{
												[1] = 
												{
													["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
												}, -- end of [1]
												[2] = 
												{
													["CLSID"] = "{FD90A1DC-9147-49FA-BF56-CB83EF0BD32B}",
												}, -- end of [2]
												[3] = 
												{
													["CLSID"] = "{FD90A1DC-9147-49FA-BF56-CB83EF0BD32B}",
												}, -- end of [3]
												[4] = 
												{
													["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
												}, -- end of [4]
											}, -- end of ["pylons"]
											["fuel"] = "1157",
											["flare"] = 30,
											["chaff"] = 30,
											["gun"] = 100,
										}, -- end of ["payload"]
										["y"] = 634249.46070276,
										["heading"] = 0.89052601785946,
										["callsign"] = 
										{
											[1] = 1,
											[2] = 1,
											["name"] = "Enfield11",
											[3] = 1,
										}, -- end of ["callsign"]
									}, -- end of [1]
									[2] = 
									{
										["alt"] = 6,
										["alt_type"] = "BARO",
										["livery_id"] = "ah-64_d_green neth",
										["skill"] = "High",
										["parking"] = "3",
										["speed"] = 41.666666666667,
										["type"] = "AH-64D",
										["unitId"] = 3,
										["psi"] = -0.89052601785946,
										["onboard_num"] = "011",
										["parking_id"] = "3",
										["x"] = -324174.81816897,
										["name"] = "Rotary-1-2",
										["payload"] = 
										{
											["pylons"] = 
											{
												[1] = 
												{
													["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
												}, -- end of [1]
												[2] = 
												{
													["CLSID"] = "{FD90A1DC-9147-49FA-BF56-CB83EF0BD32B}",
												}, -- end of [2]
												[3] = 
												{
													["CLSID"] = "{FD90A1DC-9147-49FA-BF56-CB83EF0BD32B}",
												}, -- end of [3]
												[4] = 
												{
													["CLSID"] = "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}",
												}, -- end of [4]
											}, -- end of ["pylons"]
											["fuel"] = "1157",
											["flare"] = 30,
											["chaff"] = 30,
											["gun"] = 100,
										}, -- end of ["payload"]
										["y"] = 634249.46070276,
										["heading"] = 0.89052601785946,
										["callsign"] = 
										{
											[1] = 1,
											[2] = 1,
											["name"] = "Enfield12",
											[3] = 2,
										}, -- end of ["callsign"]
									}, -- end of [2]
								}, -- end of ["units"]
								["y"] = 634249.46070276,
								["x"] = -324174.81816897,
								["name"] = "Rotary-1",
								["communication"] = true,
								["start_time"] = 0,
								["frequency"] = 127.5,
							}

end)()
local name = "Issue3-Runtime-ExactME"
assert(Group.getByName(name) == nil, "case name already in use")
assert(Group.getByName("Rotary-1") == nil, "reference aircraft unexpectedly present")
local base = assert(Airbase.getByName("Issue3-Recheck-RuntimeFARP"))
assert(base:getCoalition() == coalition.side.BLUE)
assert(#base:getParking(true) == 4, "runtime FARP is not empty")
local source = original.route.points[1]
local origin = base:getPosition().p
local dx, dy = origin.x - source.x, origin.z - source.y
original.name, original.groupId = name, nil
original.x, original.y = original.x + dx, original.y + dy
for _, point in ipairs(original.route.points) do
  point.x, point.y = point.x + dx, point.y + dy
end
original.route.points[1].helipadId = base:getID()
original.route.points[1].linkUnit = base:getID()
for index, unit in ipairs(original.units) do
  unit.name, unit.unitId = name .. "-" .. index, nil
  unit.x, unit.y = unit.x + dx, unit.y + dy
end
_G.__issue3_results = _G.__issue3_results or {}
local result = { name = name, submitted = timer.getTime(), baseId = base:getID(), spec = original, samples = {}, events = {} }
_G.__issue3_results[name] = result
local function log(message) env.info("[issue3 " .. name .. "] " .. message) end
log("submitted=" .. result.submitted .. " base=" .. result.baseId .. " free=" .. #base:getParking(true))
local function sample(delay)
  local group = Group.getByName(name)
  local row = { delay = delay, at = timer.getTime(), group = group and group:isExist() or false, units = {} }
  for _, unitName in ipairs({name .. "-1", name .. "-2"}) do
    local unit = Unit.getByName(unitName)
    local state = { name = unitName, present = unit ~= nil }
    if unit then
      state.exists, state.active, state.life, state.air = unit:isExist(), unit:isActive(), unit:getLife(), unit:inAir()
      local p = unit:getPoint()
      state.x, state.y, state.z = p.x, p.y, p.z
    end
    row.units[#row.units + 1] = state
  end
  result.samples[#result.samples + 1] = row
  local text = { "sample=" .. delay, "time=" .. row.at, "group=" .. tostring(row.group) }
  for _, unit in ipairs(row.units) do
    text[#text + 1] = unit.name .. ":present=" .. tostring(unit.present)
      .. ",active=" .. tostring(unit.active) .. ",life=" .. tostring(unit.life)
      .. ",air=" .. tostring(unit.air) .. ",xz=" .. tostring(unit.x) .. "," .. tostring(unit.z)
  end
  log(table.concat(text, " "))
end
local handler = { onEvent = function(_, event)
  if event.id ~= world.event.S_EVENT_BIRTH and event.id ~= world.event.S_EVENT_TAKEOFF
      and event.id ~= world.event.S_EVENT_CRASH and event.id ~= world.event.S_EVENT_DEAD then return end
  local ok, unitName = pcall(function() return event.initiator and event.initiator:getName() end)
  if ok and (unitName == name .. "-1" or unitName == name .. "-2") then
    result.events[#result.events + 1] = { at = timer.getTime(), id = event.id, unit = unitName }
    log("event=" .. event.id .. " unit=" .. unitName .. " time=" .. timer.getTime())
  end
end }
world.addEventHandler(handler)
result.handler = handler
local ok, handle = pcall(coalition.addGroup, 2, Group.Category.HELICOPTER, original)
result.apiOk, result.apiReturned = ok, ok and handle ~= nil
result.apiError = ok and nil or tostring(handle)
log("api_ok=" .. tostring(result.apiOk) .. " returned=" .. tostring(result.apiReturned)
  .. " error=" .. tostring(result.apiError))
sample(0)
for _, seconds in ipairs({1, 5, 30, 120}) do
  timer.scheduleFunction(function()
    local observed, reason = pcall(sample, seconds)
    if not observed then log("sample_error=" .. tostring(reason)) end
    if seconds == 120 then
      world.removeEventHandler(handler)
      result.handler = nil
      log("observer_released")
    end
  end, nil, result.submitted + seconds)
end
return name .. ":time=" .. result.submitted .. ":base=" .. result.baseId .. ":api=" .. tostring(result.apiOk) .. ":returned=" .. tostring(result.apiReturned)


