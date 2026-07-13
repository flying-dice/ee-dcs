--[==[
    ee-dcs theatre exporter — ONE self-contained DCS GUI hook.

    Writes web/src/theatres/<Theatre>.geojson: a GeoJSON FeatureCollection with the TERRAIN
    feature (map-extent polygon + proj4 projection + anchors) plus one AIRBASE point per
    airfield (numeric airdromeId) and one PARKING point per spot (Term_Index / Term_Type /
    world x,z) — the single file the web generator consumes.

    The two halves live in different DCS Lua environments, and neither has both:
      • bounds + projection → the GUI/hooks env (terrain.GetTerrainConfig / convert*)
      • airbases + parking  → the mission env (world.getAirbases / Airbase.getParking)
    This runs as a HOOK (the GUI env, which also has io/lfs), computes the TERRAIN feature
    locally, and pulls the airbases from the running mission with net.dostring_in — which
    works in a STOCK, sanitized mission env because world/Airbase/coord are never sanitized.
    So it needs NO changes to MissionScripting.lua.

    INSTALL: copy this file into your DCS write dir's Hooks folder, e.g.
      C:\Users\<you>\Saved Games\DCS.openbeta\Scripts\Hooks\theatre-dump.lua
    Restart DCS, then load a mission on each terrain. A few seconds in, an in-mission alert
    names the file it wrote. By default it writes into the DCS working dir
    (Saved Games\DCS.openbeta\<Theatre>.geojson) — copy that into web/src/theatres/. (Set
    OUT_DIR below to write straight into your repo instead.)

    NO FALLBACK: if the hooks env can't read the terrain API, nothing is written (never
    partial/approximate bounds). Embeds the DCS Fiddle JSON encoder/decoder (rxi/json, MIT).

    MIT licence — https://opensource.org/licenses/MIT
]==]

-- Where to write <Theatre>.geojson. Empty = the DCS working dir (lfs.writedir(), i.e.
-- Saved Games\DCS.openbeta\) — no setup needed; copy the file it prints into
-- web/src/theatres/. Set an absolute path (with trailing slash) to write there directly.
local OUT_DIR = ""
local DUMP_DELAY = 4 -- seconds after mission start before exporting (lets airbases populate)

------------------------------------------------------------------------------------------
-- JSON (encode/decode) — from the DCS Fiddle server (rxi/json style). Encodes tables with
-- mixed key types as objects, using "_N" for integer keys so DCS unit tables round-trip.
------------------------------------------------------------------------------------------
local json = {}
do
  local encode

  local escape_char_map = {
    ["\\"] = "\\", ["\""] = "\"", ["\b"] = "b", ["\f"] = "f", ["\n"] = "n", ["\r"] = "r", ["\t"] = "t",
  }
  local escape_char_map_inv = { ["/"] = "/" }
  for k, v in pairs(escape_char_map) do escape_char_map_inv[v] = k end

  local function escape_char(c)
    return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
  end

  local function encode_nil() return "null" end

  local function is_table_array(val)
    if rawget(val, 1) ~= nil or next(val) == nil then
      local keys = {}
      for k in pairs(val) do
        if type(k) == "number" then table.insert(keys, k) else return false end
      end
      table.sort(keys)
      for i, k in ipairs(keys) do if i ~= k then return false end end
      return true
    else
      return false
    end
  end

  local function encode_table(val, stack)
    local res = {}
    stack = stack or {}
    if stack[val] then error("circular reference") end
    stack[val] = true
    if is_table_array(val) then
      for _, v in ipairs(val) do table.insert(res, encode(v, stack)) end
      stack[val] = nil
      return "[" .. table.concat(res, ",") .. "]"
    else
      for k, v in pairs(val) do
        if type(k) ~= "string" then
          table.insert(res, encode("_" .. k, stack) .. ":" .. encode(v, stack))
        else
          table.insert(res, encode(k, stack) .. ":" .. encode(v, stack))
        end
      end
      stack[val] = nil
      return "{" .. table.concat(res, ",") .. "}"
    end
  end

  local function encode_string(val)
    return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
  end

  local function encode_number(val)
    if val ~= val or val <= -math.huge or val >= math.huge then
      error("unexpected number value '" .. tostring(val) .. "'")
    end
    return string.format("%.14g", val)
  end

  local type_func_map = {
    ["nil"] = encode_nil, ["table"] = encode_table, ["string"] = encode_string,
    ["number"] = encode_number, ["boolean"] = tostring,
  }

  encode = function(val, stack)
    local t = type(val)
    local f = type_func_map[t]
    if f then return f(val, stack) end
    error("unexpected type '" .. t .. "'")
  end

  function json.encode(val) return (encode(val)) end

  -- decode --------------------------------------------------------------------------------
  local parse

  local function create_set(...)
    local res = {}
    for i = 1, select("#", ...) do res[select(i, ...)] = true end
    return res
  end

  local space_chars = create_set(" ", "\t", "\r", "\n")
  local delim_chars = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
  local escape_chars = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
  local literals = create_set("true", "false", "null")
  local literal_map = { ["true"] = true, ["false"] = false, ["null"] = nil }

  local function next_char(str, idx, set, negate)
    for i = idx, #str do if set[str:sub(i, i)] ~= negate then return i end end
    return #str + 1
  end

  local function decode_error(str, idx, msg)
    local line_count, col_count = 1, 1
    for i = 1, idx - 1 do
      col_count = col_count + 1
      if str:sub(i, i) == "\n" then line_count = line_count + 1; col_count = 1 end
    end
    error(string.format("%s at line %d col %d", msg, line_count, col_count))
  end

  local function codepoint_to_utf8(n)
    local f = math.floor
    if n <= 0x7f then
      return string.char(n)
    elseif n <= 0x7ff then
      return string.char(f(n / 64) + 192, n % 64 + 128)
    elseif n <= 0xffff then
      return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
    elseif n <= 0x10ffff then
      return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128, f(n % 4096 / 64) + 128, n % 64 + 128)
    end
    error(string.format("invalid unicode codepoint '%x'", n))
  end

  local function parse_unicode_escape(s)
    local n1 = tonumber(s:sub(1, 4), 16)
    local n2 = tonumber(s:sub(7, 10), 16)
    if n2 then
      return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
    else
      return codepoint_to_utf8(n1)
    end
  end

  local function parse_string(str, i)
    local res, j, k = "", i + 1, i + 1
    while j <= #str do
      local x = str:byte(j)
      if x < 32 then
        decode_error(str, j, "control character in string")
      elseif x == 92 then -- '\'
        res = res .. str:sub(k, j - 1)
        j = j + 1
        local c = str:sub(j, j)
        if c == "u" then
          local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
            or str:match("^%x%x%x%x", j + 1)
            or decode_error(str, j - 1, "invalid unicode escape in string")
          res = res .. parse_unicode_escape(hex)
          j = j + #hex
        else
          if not escape_chars[c] then decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string") end
          res = res .. escape_char_map_inv[c]
        end
        k = j + 1
      elseif x == 34 then -- '"'
        res = res .. str:sub(k, j - 1)
        return res, j + 1
      end
      j = j + 1
    end
    decode_error(str, i, "expected closing quote for string")
  end

  local function parse_number(str, i)
    local x = next_char(str, i, delim_chars)
    local s = str:sub(i, x - 1)
    local n = tonumber(s)
    if not n then decode_error(str, i, "invalid number '" .. s .. "'") end
    return n, x
  end

  local function parse_literal(str, i)
    local x = next_char(str, i, delim_chars)
    local word = str:sub(i, x - 1)
    if not literals[word] then decode_error(str, i, "invalid literal '" .. word .. "'") end
    return literal_map[word], x
  end

  local function parse_array(str, i)
    local res, n = {}, 1
    i = i + 1
    while 1 do
      local x
      i = next_char(str, i, space_chars, true)
      if str:sub(i, i) == "]" then i = i + 1; break end
      x, i = parse(str, i)
      res[n] = x
      n = n + 1
      i = next_char(str, i, space_chars, true)
      local chr = str:sub(i, i)
      i = i + 1
      if chr == "]" then break end
      if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
    end
    return res, i
  end

  local function set_table(res, key, val)
    if string.sub(key, 1, 1) == "_" then
      local numKey = tonumber(string.sub(key, 2))
      if numKey then res[numKey] = val else res[key] = val end
    else
      res[key] = val
    end
  end

  local function parse_object(str, i)
    local res = {}
    i = i + 1
    while 1 do
      local key, val
      i = next_char(str, i, space_chars, true)
      if str:sub(i, i) == "}" then i = i + 1; break end
      if str:sub(i, i) ~= '"' then decode_error(str, i, "expected string for key") end
      key, i = parse(str, i)
      i = next_char(str, i, space_chars, true)
      if str:sub(i, i) ~= ":" then decode_error(str, i, "expected ':' after key") end
      i = next_char(str, i + 1, space_chars, true)
      val, i = parse(str, i)
      set_table(res, key, val)
      i = next_char(str, i, space_chars, true)
      local chr = str:sub(i, i)
      i = i + 1
      if chr == "}" then break end
      if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
    end
    return res, i
  end

  local char_func_map = {
    ['"'] = parse_string, ["0"] = parse_number, ["1"] = parse_number, ["2"] = parse_number,
    ["3"] = parse_number, ["4"] = parse_number, ["5"] = parse_number, ["6"] = parse_number,
    ["7"] = parse_number, ["8"] = parse_number, ["9"] = parse_number, ["-"] = parse_number,
    ["t"] = parse_literal, ["f"] = parse_literal, ["n"] = parse_literal,
    ["["] = parse_array, ["{"] = parse_object,
  }

  parse = function(str, idx)
    local chr = str:sub(idx, idx)
    local f = char_func_map[chr]
    if f then return f(str, idx) end
    decode_error(str, idx, "unexpected character '" .. chr .. "'")
  end

  function json.decode(str)
    if type(str) ~= "string" then error("expected argument of type string, got " .. type(str)) end
    local res, idx = parse(str, next_char(str, 1, space_chars, true))
    idx = next_char(str, idx, space_chars, true)
    if idx <= #str then decode_error(str, idx, "trailing garbage") end
    return res
  end
end

------------------------------------------------------------------------------------------
-- logging
------------------------------------------------------------------------------------------
local function __info(m)
  m = "[ee-dcs] " .. m
  if log and log.write then log.write("ee-dcs", log.INFO, m)
  elseif log and log.info then log.info(m) end
end
local function __error(m)
  m = "[ee-dcs] " .. m
  if log and log.write then log.write("ee-dcs", log.ERROR, m)
  elseif log and log.error then log.error(m) end
end

-- Only meaningful as a GUI hook (DCS present). If somehow loaded elsewhere, do nothing.
if DCS == nil then return end

------------------------------------------------------------------------------------------
-- TERRAIN feature — from DCS's terrain API (hooks/GUI env). No fallback if it's absent.
------------------------------------------------------------------------------------------
local function getUtm(lon)
  local u = {}
  if lon >= 0 then
    u.startLon = lon - (lon % 6); u.endLon = u.startLon + 6
    u.centralMeridian = u.startLon + 3; u.zone = 30 + (u.endLon / 6)
  else
    u.startLon = lon + ((lon * -1) % 6); u.endLon = u.startLon - 6
    u.centralMeridian = u.startLon - 3; u.zone = 30 + (u.startLon / 6)
  end
  return u
end

local function buildTerrainFeature()
  if not (terrain and terrain.GetTerrainConfig and terrain.convertMetersToLatLon and terrain.convertLatLonToMeters) then
    error("hooks env exposes no terrain.GetTerrainConfig/convert*")
  end
  local NE = terrain.GetTerrainConfig("NE_bound")
  local SW = terrain.GetTerrainConfig("SW_bound")
  if type(NE) ~= "table" or type(SW) ~= "table" then error("no NE_bound/SW_bound") end
  local nw_lat, nw_lon = terrain.convertMetersToLatLon(NE[1] * 1000, SW[3] * 1000)
  local ne_lat, ne_lon = terrain.convertMetersToLatLon(NE[1] * 1000, NE[3] * 1000)
  local se_lat, se_lon = terrain.convertMetersToLatLon(SW[1] * 1000, NE[3] * 1000)
  local sw_lat, sw_lon = terrain.convertMetersToLatLon(SW[1] * 1000, SW[3] * 1000)
  local geometry = { type = "Polygon", coordinates = { {
    { nw_lon, nw_lat }, { sw_lon, sw_lat }, { se_lon, se_lat }, { ne_lon, ne_lat }, { nw_lon, nw_lat },
  } } }
  local clat, clon = terrain.convertMetersToLatLon(0, 0)
  local utm = getUtm(clon)
  local scale = 0.9996
  local x, z = terrain.convertLatLonToMeters(0, utm.centralMeridian)
  local proj = "+proj=tmerc +lat_0=0 +lon_0=" .. utm.centralMeridian
    .. " +k_0=" .. scale .. " +x_0=" .. z .. " +y_0=" .. x
    .. " +towgs84=0,0,0,0,0,0,0 +units=m +vunits=m +ellps=WGS84 +no_defs +axis=neu"
  local lats = { math.min(nw_lat, ne_lat), clat, math.max(sw_lat, se_lat) }
  local lons = { math.max(nw_lon, sw_lon), clon, math.min(ne_lon, se_lon) }
  local anchors = {}
  for _, la in ipairs(lats) do
    for _, lo in ipairs(lons) do
      local ax, az = terrain.convertLatLonToMeters(la, lo)
      anchors[#anchors + 1] = { lat = la, lon = lo, x = ax, z = az }
    end
  end
  return {
    type = "Feature", geometry = geometry,
    properties = {
      type = "TERRAIN", id = terrain.GetTerrainConfig("id"), name = terrain.GetTerrainConfig("name"),
      center = { lat = clat, lon = clon }, hemisphere = (clat > 0) and "n" or "s",
      utm = utm, projection = { scale = scale, offset = { x = x, y = 0, z = z }, proj = proj }, anchors = anchors,
    },
  }
end

------------------------------------------------------------------------------------------
-- AIRBASE + PARKING — pulled from the running mission env via net.dostring_in.
-- The snippet uses only world/Airbase/coord (never sanitized) and returns a delimited
-- blob: records split by \30, fields by \31, so airfield names can't collide with them.
------------------------------------------------------------------------------------------
local MISSION_SNIPPET = [==[
  local FS, RS = string.char(31), string.char(30)
  local L = {}
  for _, a in pairs(world.getAirbases()) do
    local p = a:getPoint()
    local lat, lon, alt = coord.LOtoLL(p)
    local d = a:getDesc()
    L[#L+1] = table.concat({ 'AB', a:getID(), d.displayName, d.category, lat, lon, alt, p.x, p.z }, FS)
    local ok, sp = pcall(function() return a:getParking() end)
    if ok and sp then
      for _, k in pairs(sp) do
        local v = k.vTerminalPos
        local kl, ko, ka = coord.LOtoLL(v)
        L[#L+1] = table.concat({ 'PK', a:getID(), k.Term_Index, k.Term_Type, (k.TO_AC and 1 or 0), kl, ko, ka, v.x, v.z }, FS)
      end
    end
  end
  return table.concat(L, RS)
]==]

local CATS = { [0] = "AIRDROME", [1] = "HELIPAD", [2] = "SHIP" }

local function fetchAirbases()
  local FS, RS = string.char(31), string.char(30)
  local blob = net.dostring_in("mission", MISSION_SNIPPET) or ""
  local features = {}
  for rec in (blob .. RS):gmatch("(.-)" .. RS) do
    if rec ~= "" then
      local f = {}
      for fld in (rec .. FS):gmatch("(.-)" .. FS) do f[#f + 1] = fld end
      if f[1] == "AB" then
        features[#features + 1] = {
          type = "Feature", geometry = { type = "Point", coordinates = { tonumber(f[6]), tonumber(f[5]), tonumber(f[7]) } },
          properties = { type = "AIRBASE", name = f[3], category = CATS[tonumber(f[4])] or "AIRDROME",
            airdromeId = tonumber(f[2]), x = tonumber(f[8]), z = tonumber(f[9]) },
        }
      elseif f[1] == "PK" then
        features[#features + 1] = {
          type = "Feature", geometry = { type = "Point", coordinates = { tonumber(f[7]), tonumber(f[6]), tonumber(f[8]) } },
          properties = { type = "PARKING", airdromeId = tonumber(f[2]), Term_Index = tonumber(f[3]),
            Term_Type = tonumber(f[4]), TO_AC = (f[5] == "1"), x = tonumber(f[9]), z = tonumber(f[10]) },
        }
      end
    end
  end
  return features
end

------------------------------------------------------------------------------------------
-- export: build TERRAIN, pull airbases, write <OUT_DIR><Theatre>.geojson
------------------------------------------------------------------------------------------
local function runExport()
  local tf = buildTerrainFeature() -- raises (no fallback) if the terrain API is missing
  local id = tf.properties.id or "unknown"
  local features = { tf }
  local airbases = fetchAirbases()
  for _, f in ipairs(airbases) do features[#features + 1] = f end
  local fc = {
    type = "FeatureCollection",
    properties = { terrain = id, source = "theatre-dump (hook)" },
    features = features,
  }
  local dir = (OUT_DIR ~= nil and OUT_DIR ~= "") and OUT_DIR or lfs.writedir()
  local out = dir .. id .. ".geojson"
  local fh, e = io.open(out, "w")
  if not fh then __error("cannot open " .. out .. ": " .. tostring(e)); return end
  fh:write(json.encode(fc)); fh:close()

  __info("theatre export -> " .. out .. "  (TERRAIN + " .. #airbases .. " airbase/parking features)")
  -- Alert inside the mission (trigger.action lives in the mission env). Built by
  -- concatenation so the mission code's [==[ ]==] aren't nested long brackets in this source.
  local msg = "[ee-dcs] theatre GeoJSON saved: " .. out:gsub("\\", "/")
    .. "  (TERRAIN + " .. #airbases .. " airbase/parking features)"
  pcall(net.dostring_in, "mission", "trigger.action.outText([==[" .. msg .. "]==], 30, true)")
end

------------------------------------------------------------------------------------------
-- hook: run once per terrain, a few seconds after the sim starts
------------------------------------------------------------------------------------------
local exported = {}
local cb = {}
function cb.onSimulationFrame()
  local t = (DCS.getModelTime and DCS.getModelTime()) or 0
  if t < DUMP_DELAY then return end
  local okId, id = pcall(function() return terrain and terrain.GetTerrainConfig and terrain.GetTerrainConfig("id") end)
  if not okId or not id or exported[id] then return end
  exported[id] = true
  local ok, err = pcall(runExport)
  if not ok then __error("export failed for " .. tostring(id) .. ": " .. tostring(err)) end
end
DCS.setUserCallbacks(cb)
__info("export hook loaded")
