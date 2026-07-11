--[[
    Return a GeoJSON Feature object describing the currently-loaded DCS theatre,
    including a proj4 Transverse-Mercator projection string derived FROM DCS itself
    (so it is self-consistent with the game's own warped terrain, not assumed WGS84).

    Repo about the tmerc projection:  https://github.com/JonathanTurnock/dcs-projections
    Central-meridian resource:        https://gisgeography.com/central-meridian/
    UTM-zone validator:               https://mangomap.com/robertyoung/maps/69585/what-utm-zone-am-i-in-

    MIT licence — https://opensource.org/licenses/MIT

    USAGE
      Paste this block into DCS Fiddle and select the GUI environment.
      A terrain MUST be loaded (mission editor open on a map, or a mission running).
      The returned Feature is what the EECH map-generator bakes in as a selectable
      overlay (bounds polygon) + the proj4 string it projects lat/lon → DCS metres with.
]]--

local function getUtm(lon)
    local utm = {}
    if lon >= 0 then
        utm.startLon = lon - (lon % 6)
        utm.endLon = utm.startLon + 6
        utm.centralMeridian = utm.startLon + 3
        utm.zone = 30 + (utm.endLon / 6)
    else
        utm.startLon = lon + ((lon * -1) % 6)
        utm.endLon = utm.startLon - 6
        utm.centralMeridian = utm.startLon - 3
        utm.zone = 30 + (utm.startLon / 6)
    end
    return utm
end

local NE_bound = terrain.GetTerrainConfig("NE_bound")
local SW_bound = terrain.GetTerrainConfig("SW_bound")

-- Corners: NE_bound/SW_bound are {x_km, ?, z_km}. Metres = km*1000.
local nw_lat, nw_lon = terrain.convertMetersToLatLon(NE_bound[1] * 1000, SW_bound[3] * 1000)
local ne_lat, ne_lon = terrain.convertMetersToLatLon(NE_bound[1] * 1000, NE_bound[3] * 1000)
local se_lat, se_lon = terrain.convertMetersToLatLon(SW_bound[1] * 1000, NE_bound[3] * 1000)
local sw_lat, sw_lon = terrain.convertMetersToLatLon(SW_bound[1] * 1000, SW_bound[3] * 1000)

local geometry = {
    type = "Polygon",
    coordinates = { {
        { nw_lon, nw_lat },
        { sw_lon, sw_lat },
        { se_lon, se_lat },
        { ne_lon, ne_lat },
        { nw_lon, nw_lat },
    } },
}

local properties = {
    type = "TERRAIN",
    id = terrain.GetTerrainConfig("id"),
    name = terrain.GetTerrainConfig("name"),
}

-- Map centre (DCS origin 0,0) → lat/lon; the central meridian comes from its UTM zone.
local lat, lon = terrain.convertMetersToLatLon(0, 0)
properties.center = { lat = lat, lon = lon }

local utm = getUtm(lon)
local scale = 0.9996

-- The false origin: DCS metres at (lat=0, lon=centralMeridian). x=north, z=east.
-- Feeding a lat/lon through the resulting proj string reproduces DCS's own
-- convertLatLonToMeters, so projected zones land exactly where DCS puts them.
local x, z = terrain.convertLatLonToMeters(0, utm.centralMeridian)

local proj = "+proj=tmerc +lat_0=0 +lon_0=" .. utm.centralMeridian
    .. " +k_0=" .. scale
    .. " +x_0=" .. z
    .. " +y_0=" .. x
    .. " +towgs84=0,0,0,0,0,0,0 +units=m +vunits=m +ellps=WGS84 +no_defs +axis=neu"

properties.hemisphere = lat > 0 and "n" or "s"
properties.utm = utm
properties.projection = { scale = scale, offset = { x = x, y = 0, z = z }, proj = proj }

-- Self-validation anchors: a 3x3 grid of lat/lon across the map interior with the
-- DCS-native metres (x=north, z=east). The web tool's proj4 string must reproduce
-- these — ground truth for the projection, and internally self-consistent (both come
-- from DCS's own convert*, so they carry the terrain's warp rather than assuming WGS84).
local lats = { math.min(nw_lat, ne_lat), lat, math.max(sw_lat, se_lat) }
local lons = { math.max(nw_lon, sw_lon), lon, math.min(ne_lon, se_lon) }
local anchors = {}
for _, la in ipairs(lats) do
    for _, lo in ipairs(lons) do
        local ax, az = terrain.convertLatLonToMeters(la, lo)
        anchors[#anchors + 1] = { lat = la, lon = lo, x = ax, z = az }
    end
end
properties.anchors = anchors

return { type = "Feature", geometry = geometry, properties = properties }
