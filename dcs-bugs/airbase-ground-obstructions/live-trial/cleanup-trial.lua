local ____trialGeneration = assert(_DMT_GEN, "campaign generation missing")
--[[ Generated with https://github.com/TypeScriptToLua/TypeScriptToLua ]]

local ____modules = {}
local ____moduleCache = {}
local ____originalRequire = require
local function require(file, ...)
    if ____moduleCache[file] then
        return ____moduleCache[file].value
    end
    if ____modules[file] then
        local module = ____modules[file]
        local value = nil
        if (select("#", ...) > 0) then value = module(...) else value = module(file) end
        ____moduleCache[file] = { value = value }
        return value
    else
        if ____originalRequire then
            return ____originalRequire(file)
        else
            error("module '" .. file .. "' not found")
        end
    end
end
____modules = {
["lualib_bundle"] = function(...) 
local function __TS__StringIncludes(self, searchString, position)
    if not position then
        position = 1
    else
        position = position + 1
    end
    local index = string.find(self, searchString, position, true)
    return index ~= nil
end

local __TS__Match = string.match

local function __TS__SourceMapTraceBack(fileName, sourceMap)
    _G.__TS__sourcemap = _G.__TS__sourcemap or ({})
    _G.__TS__sourcemap[fileName] = sourceMap
    if _G.__TS__originalTraceback == nil then
        local originalTraceback = debug.traceback
        _G.__TS__originalTraceback = originalTraceback
        debug.traceback = function(thread, message, level)
            local trace
            if thread == nil and message == nil and level == nil then
                trace = originalTraceback()
            elseif __TS__StringIncludes(_VERSION, "Lua 5.0") then
                trace = originalTraceback((("[Level " .. tostring(level)) .. "] ") .. tostring(message))
            else
                trace = originalTraceback(thread, message, level)
            end
            if type(trace) ~= "string" then
                return trace
            end
            local function replacer(____, file, srcFile, line)
                local fileSourceMap = _G.__TS__sourcemap[file]
                if fileSourceMap ~= nil and fileSourceMap[line] ~= nil then
                    local data = fileSourceMap[line]
                    if type(data) == "number" then
                        return (srcFile .. ":") .. tostring(data)
                    end
                    return (data.file .. ":") .. tostring(data.line)
                end
                return (file .. ":") .. line
            end
            local result = string.gsub(
                trace,
                "([^%s<]+)%.lua:(%d+)",
                function(file, line) return replacer(nil, file .. ".lua", file .. ".ts", line) end
            )
            local function stringReplacer(____, file, line)
                local fileSourceMap = _G.__TS__sourcemap[file]
                if fileSourceMap ~= nil and fileSourceMap[line] ~= nil then
                    local chunkName = (__TS__Match(file, "%[string \"([^\"]+)\"%]"))
                    local sourceName = string.gsub(chunkName, ".lua$", ".ts")
                    local data = fileSourceMap[line]
                    if type(data) == "number" then
                        return (sourceName .. ":") .. tostring(data)
                    end
                    return (data.file .. ":") .. tostring(data.line)
                end
                return (file .. ":") .. line
            end
            result = string.gsub(
                result,
                "(%[string \"[^\"]+\"%]):(%d+)",
                function(file, line) return stringReplacer(nil, file, line) end
            )
            return result
        end
    end
end

local function __TS__ObjectValues(obj)
    local result = {}
    local len = 0
    for key in pairs(obj) do
        len = len + 1
        result[len] = obj[key]
    end
    return result
end

local function __TS__ObjectEntries(obj)
    local result = {}
    local len = 0
    for key in pairs(obj) do
        len = len + 1
        result[len] = {key, obj[key]}
    end
    return result
end

local function __TS__ObjectKeys(obj)
    local result = {}
    local len = 0
    for key in pairs(obj) do
        len = len + 1
        result[len] = key
    end
    return result
end

local function __TS__ArrayForEach(self, callbackFn, thisArg)
    for i = 1, #self do
        callbackFn(thisArg, self[i], i - 1, self)
    end
end

local function __TS__New(target, ...)
    local instance = setmetatable({}, target.prototype)
    instance:____constructor(...)
    return instance
end

local function __TS__Class(self)
    local c = {prototype = {}}
    c.prototype.__index = c.prototype
    c.prototype.constructor = c
    return c
end

local function __TS__ClassExtends(target, base)
    target.____super = base
    local staticMetatable = setmetatable({__index = base}, base)
    setmetatable(target, staticMetatable)
    local baseMetatable = getmetatable(base)
    if baseMetatable then
        if type(baseMetatable.__index) == "function" then
            staticMetatable.__index = baseMetatable.__index
        end
        if type(baseMetatable.__newindex) == "function" then
            staticMetatable.__newindex = baseMetatable.__newindex
        end
    end
    setmetatable(target.prototype, base.prototype)
    if type(base.prototype.__index) == "function" then
        target.prototype.__index = base.prototype.__index
    end
    if type(base.prototype.__newindex) == "function" then
        target.prototype.__newindex = base.prototype.__newindex
    end
    if type(base.prototype.__tostring) == "function" then
        target.prototype.__tostring = base.prototype.__tostring
    end
end

local Error, RangeError, ReferenceError, SyntaxError, TypeError, URIError
do
    local function getErrorStack(self, constructor)
        if debug == nil then
            return nil
        end
        local level = 1
        while true do
            local info = debug.getinfo(level, "f")
            level = level + 1
            if not info then
                level = 1
                break
            elseif info.func == constructor then
                break
            end
        end
        if __TS__StringIncludes(_VERSION, "Lua 5.0") then
            return debug.traceback(("[Level " .. tostring(level)) .. "]")
        elseif _VERSION == "Lua 5.1" then
            return string.sub(
                debug.traceback("", level),
                2
            )
        else
            return debug.traceback(nil, level)
        end
    end
    local function wrapErrorToString(self, getDescription)
        return function(self)
            local description = getDescription(self)
            local caller = debug.getinfo(3, "f")
            local isClassicLua = __TS__StringIncludes(_VERSION, "Lua 5.0")
            if isClassicLua or caller and caller.func ~= error then
                return description
            else
                return (description .. "\n") .. tostring(self.stack)
            end
        end
    end
    local function initErrorClass(self, Type, name)
        Type.name = name
        return setmetatable(
            Type,
            {__call = function(____, _self, message) return __TS__New(Type, message) end}
        )
    end
    local ____initErrorClass_1 = initErrorClass
    local ____class_0 = __TS__Class()
    ____class_0.name = ""
    function ____class_0.prototype.____constructor(self, message)
        if message == nil then
            message = ""
        end
        self.message = message
        self.name = "Error"
        self.stack = getErrorStack(nil, __TS__New)
        local metatable = getmetatable(self)
        if metatable and not metatable.__errorToStringPatched then
            metatable.__errorToStringPatched = true
            metatable.__tostring = wrapErrorToString(nil, metatable.__tostring)
        end
    end
    function ____class_0.prototype.__tostring(self)
        return self.message ~= "" and (self.name .. ": ") .. self.message or self.name
    end
    Error = ____initErrorClass_1(nil, ____class_0, "Error")
    local function createErrorClass(self, name)
        local ____initErrorClass_3 = initErrorClass
        local ____class_2 = __TS__Class()
        ____class_2.name = ____class_2.name
        __TS__ClassExtends(____class_2, Error)
        function ____class_2.prototype.____constructor(self, ...)
            ____class_2.____super.prototype.____constructor(self, ...)
            self.name = name
        end
        return ____initErrorClass_3(nil, ____class_2, name)
    end
    RangeError = createErrorClass(nil, "RangeError")
    ReferenceError = createErrorClass(nil, "ReferenceError")
    SyntaxError = createErrorClass(nil, "SyntaxError")
    TypeError = createErrorClass(nil, "TypeError")
    URIError = createErrorClass(nil, "URIError")
end

local function __TS__ObjectGetOwnPropertyDescriptors(object)
    local metatable = getmetatable(object)
    if not metatable then
        return {}
    end
    return rawget(metatable, "_descriptors") or ({})
end

local function __TS__Delete(target, key)
    local descriptors = __TS__ObjectGetOwnPropertyDescriptors(target)
    local descriptor = descriptors[key]
    if descriptor then
        if not descriptor.configurable then
            error(
                __TS__New(
                    TypeError,
                    ((("Cannot delete property " .. tostring(key)) .. " of ") .. tostring(target)) .. "."
                ),
                0
            )
        end
        descriptors[key] = nil
        return true
    end
    target[key] = nil
    return true
end

local function __TS__ArrayMap(self, callbackfn, thisArg)
    local result = {}
    for i = 1, #self do
        result[i] = callbackfn(thisArg, self[i], i - 1, self)
    end
    return result
end

local function __TS__ObjectAssign(target, ...)
    local sources = {...}
    for i = 1, #sources do
        local source = sources[i]
        if type(source) == "table" then
            for key in pairs(source) do
                target[key] = source[key]
            end
        end
    end
    return target
end

local function __TS__ArrayFilter(self, callbackfn, thisArg)
    local result = {}
    local len = 0
    for i = 1, #self do
        if callbackfn(thisArg, self[i], i - 1, self) then
            len = len + 1
            result[len] = self[i]
        end
    end
    return result
end

local function __TS__ArrayIncludes(self, searchElement, fromIndex)
    if fromIndex == nil then
        fromIndex = 0
    end
    local len = #self
    local k = fromIndex
    if fromIndex < 0 then
        k = len + fromIndex
    end
    if k < 0 then
        k = 0
    end
    for i = k + 1, len do
        if self[i] == searchElement then
            return true
        end
    end
    return false
end

local function __TS__ArraySort(self, compareFn)
    if compareFn ~= nil then
        table.sort(
            self,
            function(a, b) return compareFn(nil, a, b) < 0 end
        )
    else
        table.sort(self)
    end
    return self
end

local function __TS__CountVarargs(...)
    return select("#", ...)
end

local function __TS__ArraySplice(self, ...)
    local args = {...}
    local len = #self
    local actualArgumentCount = __TS__CountVarargs(...)
    local start = args[1]
    local deleteCount = args[2]
    if start < 0 then
        start = len + start
        if start < 0 then
            start = 0
        end
    elseif start > len then
        start = len
    end
    local itemCount = actualArgumentCount - 2
    if itemCount < 0 then
        itemCount = 0
    end
    local actualDeleteCount
    if actualArgumentCount == 0 then
        actualDeleteCount = 0
    elseif actualArgumentCount == 1 then
        actualDeleteCount = len - start
    else
        actualDeleteCount = deleteCount or 0
        if actualDeleteCount < 0 then
            actualDeleteCount = 0
        end
        if actualDeleteCount > len - start then
            actualDeleteCount = len - start
        end
    end
    local out = {}
    for k = 1, actualDeleteCount do
        local from = start + k
        if self[from] ~= nil then
            out[k] = self[from]
        end
    end
    if itemCount < actualDeleteCount then
        for k = start + 1, len - actualDeleteCount do
            local from = k + actualDeleteCount
            local to = k + itemCount
            if self[from] then
                self[to] = self[from]
            else
                self[to] = nil
            end
        end
        for k = len - actualDeleteCount + itemCount + 1, len do
            self[k] = nil
        end
    elseif itemCount > actualDeleteCount then
        for k = len - actualDeleteCount, start + 1, -1 do
            local from = k + actualDeleteCount
            local to = k + itemCount
            if self[from] then
                self[to] = self[from]
            else
                self[to] = nil
            end
        end
    end
    local j = start + 1
    for i = 3, actualArgumentCount do
        self[j] = args[i]
        j = j + 1
    end
    for k = #self, len - actualDeleteCount + itemCount + 1, -1 do
        self[k] = nil
    end
    return out
end

local function __TS__ArraySlice(self, first, last)
    local len = #self
    first = first or 0
    if first < 0 then
        first = len + first
        if first < 0 then
            first = 0
        end
    else
        if first > len then
            first = len
        end
    end
    last = last or len
    if last < 0 then
        last = len + last
        if last < 0 then
            last = 0
        end
    else
        if last > len then
            last = len
        end
    end
    local out = {}
    first = first + 1
    last = last + 1
    local n = 1
    while first < last do
        out[n] = self[first]
        first = first + 1
        n = n + 1
    end
    return out
end

local function __TS__ArraySome(self, callbackfn, thisArg)
    for i = 1, #self do
        if callbackfn(thisArg, self[i], i - 1, self) then
            return true
        end
    end
    return false
end

local function __TS__SparseArrayNew(...)
    local sparseArray = {...}
    sparseArray.sparseLength = __TS__CountVarargs(...)
    return sparseArray
end

local function __TS__SparseArrayPush(sparseArray, ...)
    local args = {...}
    local argsLen = __TS__CountVarargs(...)
    local listLen = sparseArray.sparseLength
    for i = 1, argsLen do
        sparseArray[listLen + i] = args[i]
    end
    sparseArray.sparseLength = listLen + argsLen
end

local function __TS__SparseArraySpread(sparseArray)
    local _unpack = unpack or table.unpack
    return _unpack(sparseArray, 1, sparseArray.sparseLength)
end

local function __TS__ArrayPush(self, ...)
    local items = {...}
    local len = #self
    for i = 1, #items do
        len = len + 1
        self[len] = items[i]
    end
    return len
end

local function __TS__NumberIsNaN(value)
    return value ~= value
end

local function __TS__StringStartsWith(self, searchString, position)
    if position == nil or position < 0 then
        position = 0
    end
    return string.sub(self, position + 1, #searchString + position) == searchString
end

local function __TS__ArrayUnshift(self, ...)
    local items = {...}
    local numItemsToInsert = #items
    if numItemsToInsert == 0 then
        return #self
    end
    for i = #self, 1, -1 do
        self[i + numItemsToInsert] = self[i]
    end
    for i = 1, numItemsToInsert do
        self[i] = items[i]
    end
    return #self
end

local __TS__Symbol, Symbol
do
    local symbolMetatable = {__tostring = function(self)
        return ("Symbol(" .. (self.description or "")) .. ")"
    end}
    function __TS__Symbol(description)
        return setmetatable({description = description}, symbolMetatable)
    end
    Symbol = {
        asyncDispose = __TS__Symbol("Symbol.asyncDispose"),
        dispose = __TS__Symbol("Symbol.dispose"),
        iterator = __TS__Symbol("Symbol.iterator"),
        hasInstance = __TS__Symbol("Symbol.hasInstance"),
        species = __TS__Symbol("Symbol.species"),
        toStringTag = __TS__Symbol("Symbol.toStringTag")
    }
end

local __TS__Iterator
do
    local function iteratorGeneratorStep(self)
        local co = self.____coroutine
        local status, value = coroutine.resume(co)
        if not status then
            error(value, 0)
        end
        if coroutine.status(co) == "dead" then
            return
        end
        return true, value
    end
    local function iteratorIteratorStep(self)
        local result = self:next()
        if result.done then
            return
        end
        return true, result.value
    end
    local function iteratorStringStep(self, index)
        index = index + 1
        if index > #self then
            return
        end
        return index, string.sub(self, index, index)
    end
    function __TS__Iterator(iterable)
        if type(iterable) == "string" then
            return iteratorStringStep, iterable, 0
        elseif iterable.____coroutine ~= nil then
            return iteratorGeneratorStep, iterable
        elseif iterable[Symbol.iterator] then
            local iterator = iterable[Symbol.iterator](iterable)
            return iteratorIteratorStep, iterator
        else
            return ipairs(iterable)
        end
    end
end

local Map
do
    Map = __TS__Class()
    Map.name = "Map"
    function Map.prototype.____constructor(self, entries)
        self[Symbol.toStringTag] = "Map"
        self.items = {}
        self.size = 0
        self.nextKey = {}
        self.previousKey = {}
        if entries == nil then
            return
        end
        local iterable = entries
        if iterable[Symbol.iterator] then
            local iterator = iterable[Symbol.iterator](iterable)
            while true do
                local result = iterator:next()
                if result.done then
                    break
                end
                local value = result.value
                self:set(value[1], value[2])
            end
        else
            local array = entries
            for ____, kvp in ipairs(array) do
                self:set(kvp[1], kvp[2])
            end
        end
    end
    function Map.prototype.clear(self)
        self.items = {}
        self.nextKey = {}
        self.previousKey = {}
        self.firstKey = nil
        self.lastKey = nil
        self.size = 0
    end
    function Map.prototype.delete(self, key)
        local contains = self:has(key)
        if contains then
            self.size = self.size - 1
            local next = self.nextKey[key]
            local previous = self.previousKey[key]
            if next ~= nil and previous ~= nil then
                self.nextKey[previous] = next
                self.previousKey[next] = previous
            elseif next ~= nil then
                self.firstKey = next
                self.previousKey[next] = nil
            elseif previous ~= nil then
                self.lastKey = previous
                self.nextKey[previous] = nil
            else
                self.firstKey = nil
                self.lastKey = nil
            end
            self.nextKey[key] = nil
            self.previousKey[key] = nil
        end
        self.items[key] = nil
        return contains
    end
    function Map.prototype.forEach(self, callback)
        for ____, key in __TS__Iterator(self:keys()) do
            callback(nil, self.items[key], key, self)
        end
    end
    function Map.prototype.get(self, key)
        return self.items[key]
    end
    function Map.prototype.has(self, key)
        return self.nextKey[key] ~= nil or self.lastKey == key
    end
    function Map.prototype.set(self, key, value)
        local isNewValue = not self:has(key)
        if isNewValue then
            self.size = self.size + 1
        end
        self.items[key] = value
        if self.firstKey == nil then
            self.firstKey = key
            self.lastKey = key
        elseif isNewValue then
            self.nextKey[self.lastKey] = key
            self.previousKey[key] = self.lastKey
            self.lastKey = key
        end
        return self
    end
    Map.prototype[Symbol.iterator] = function(self)
        return self:entries()
    end
    function Map.prototype.entries(self)
        local function getFirstKey()
            return self.firstKey
        end
        local items = self.items
        local nextKey = self.nextKey
        local key
        local started = false
        return {
            [Symbol.iterator] = function(self)
                return self
            end,
            next = function(self)
                if not started then
                    started = true
                    key = getFirstKey(nil)
                else
                    key = nextKey[key]
                end
                return {done = not key, value = {key, items[key]}}
            end
        }
    end
    function Map.prototype.keys(self)
        local function getFirstKey()
            return self.firstKey
        end
        local nextKey = self.nextKey
        local key
        local started = false
        return {
            [Symbol.iterator] = function(self)
                return self
            end,
            next = function(self)
                if not started then
                    started = true
                    key = getFirstKey(nil)
                else
                    key = nextKey[key]
                end
                return {done = not key, value = key}
            end
        }
    end
    function Map.prototype.values(self)
        local function getFirstKey()
            return self.firstKey
        end
        local items = self.items
        local nextKey = self.nextKey
        local key
        local started = false
        return {
            [Symbol.iterator] = function(self)
                return self
            end,
            next = function(self)
                if not started then
                    started = true
                    key = getFirstKey(nil)
                else
                    key = nextKey[key]
                end
                return {done = not key, value = items[key]}
            end
        }
    end
    Map[Symbol.species] = Map
end

local function __TS__ArrayJoin(self, separator)
    if separator == nil then
        separator = ","
    end
    local parts = {}
    for i = 1, #self do
        parts[i] = tostring(self[i])
    end
    return table.concat(parts, separator)
end

return {
  __TS__SourceMapTraceBack = __TS__SourceMapTraceBack,
  __TS__ObjectValues = __TS__ObjectValues,
  __TS__ObjectEntries = __TS__ObjectEntries,
  __TS__ObjectKeys = __TS__ObjectKeys,
  __TS__ArrayForEach = __TS__ArrayForEach,
  __TS__Delete = __TS__Delete,
  __TS__ArrayMap = __TS__ArrayMap,
  __TS__ObjectAssign = __TS__ObjectAssign,
  __TS__ArrayFilter = __TS__ArrayFilter,
  __TS__ArrayIncludes = __TS__ArrayIncludes,
  __TS__ArraySort = __TS__ArraySort,
  __TS__ArraySplice = __TS__ArraySplice,
  __TS__ArraySlice = __TS__ArraySlice,
  __TS__StringIncludes = __TS__StringIncludes,
  __TS__ArraySome = __TS__ArraySome,
  __TS__SparseArrayNew = __TS__SparseArrayNew,
  __TS__SparseArrayPush = __TS__SparseArrayPush,
  __TS__SparseArraySpread = __TS__SparseArraySpread,
  __TS__ArrayPush = __TS__ArrayPush,
  __TS__NumberIsNaN = __TS__NumberIsNaN,
  __TS__StringStartsWith = __TS__StringStartsWith,
  __TS__ArrayUnshift = __TS__ArrayUnshift,
  Map = Map,
  __TS__New = __TS__New,
  __TS__ArrayJoin = __TS__ArrayJoin
}
 end,
["sides"] = function(...) 
local ____lualib = require("lualib_bundle")
local __TS__SourceMapTraceBack = ____lualib.__TS__SourceMapTraceBack
local ____exports = {}
--- Value of `coalition.side.RED`. See PROVENANCE above.
local RED_VALUE = 1
--- Value of `coalition.side.BLUE`. See PROVENANCE above.
local BLUE_VALUE = 2
--- Value of `coalition.side.NEUTRAL`. See PROVENANCE above.
local NEUTRAL_VALUE = 0
____exports.RED = coalition.side.RED
____exports.BLUE = coalition.side.BLUE
____exports.NEUTRAL = coalition.side.NEUTRAL
--- Fails loudly if the engine's side numbers are not what {@link Side} claims.
-- 
-- This is what makes the casts above a validated boundary rather than a blind
-- assertion. Runs at module load, so it runs before any campaign code can use
-- a side value.
local function assertSideValue(name, engine, expected)
    if engine == expected then
        return
    end
    error(((((("ee-dcs: coalition.side." .. name) .. " is ") .. tostring(engine)) .. ", but the campaign's") .. (" Side type is built on " .. tostring(expected)) .. ". The DCS coalition numbering has") .. " changed; src/sides.ts must be updated before the campaign can run.")
end
assertSideValue("RED", coalition.side.RED, RED_VALUE)
assertSideValue("BLUE", coalition.side.BLUE, BLUE_VALUE)
assertSideValue("NEUTRAL", coalition.side.NEUTRAL, NEUTRAL_VALUE)
return ____exports
 end,
["campaign_state"] = function(...) 
local ____lualib = require("lualib_bundle")
local __TS__Delete = ____lualib.__TS__Delete
local __TS__ObjectValues = ____lualib.__TS__ObjectValues
local __TS__ObjectEntries = ____lualib.__TS__ObjectEntries
local __TS__SourceMapTraceBack = ____lualib.__TS__SourceMapTraceBack
local ____exports = {}
local ____sides = require("sides")
local BLUE = ____sides.BLUE
local RED = ____sides.RED
function ____exports.stat_sortie(side)
    local ____exports_S_stats_side_5, ____sorties_6 = ____exports.S.stats[side], "sorties"
    ____exports_S_stats_side_5[____sorties_6] = ____exports_S_stats_side_5[____sorties_6] + 1
end
____exports.MINIMUM_EFFICIENCY = 0.3
____exports.HEALTH_NEUTRALISED = ____exports.MINIMUM_EFFICIENCY
____exports.HEALTH_DESTROYED = 0
____exports.OBJECTIVES_PER_SIDE = 5
local FIRST_DYNAMIC_ENTITY_ID = 2000
local MIN_LIVE_UNIT_LIFE = 1
local PERCENT_SCALE = 100
local PERCENT_ROUNDING_OFFSET = 0.5
local BALANCED_FORCE_PERCENT = 50
local STRIKE_NEUTRALISED_MARGIN = 0.8
local STRIKE_SUCCESS_RATING = 0.25
local STRIKE_PARTIAL_RATING = 0.1
assert(_DMT_GEN == ____trialGeneration, "generation changed during trial load")
____exports.GENERATION = _DMT_GEN
if _DMT_DEBUG == nil then
    _DMT_DEBUG = true
end
function ____exports.dbg(tag, fmt, ...)
    local args = {...}
    if not _DMT_DEBUG then
        return
    end
    local rendered
    do
        local function ____catch(_error)
            rendered = "FMT-ERR " .. fmt
        end
        local ____try, ____hasReturned = pcall(function()
            rendered = string.format(
                fmt,
                unpack(args)
            )
        end)
        if not ____try then
            ____catch(____hasReturned)
        end
    end
    env.info((("[dmt:" .. tag) .. "] ") .. rendered)
end
local function freshStats()
    return {
        kills = {},
        losses = {},
        sorties = 0,
        tasks_created = 0,
        tasks_completed = 0,
        tasks_partial = 0,
        tasks_failed = 0
    }
end
____exports.S = {
    start_time = 0,
    game_over = false,
    base_health = {},
    base_owner = {},
    base_pos = {},
    base_efficiency = {},
    base_kind = {},
    objectives = {},
    strength = {[BLUE] = PERCENT_SCALE, [RED] = PERCENT_SCALE},
    ground_groups = {[BLUE] = {}, [RED] = {}},
    arty_groups = {[BLUE] = {}, [RED] = {}},
    counter_battery = {},
    base_ledger = {},
    base_inflight = {},
    group_launch_base = {},
    force_current = {},
    base_idle_groups = {},
    active_tasks = {},
    board_tasks = {},
    board_failed = 0,
    farp_active = {},
    stats = {
        [BLUE] = freshStats(),
        [RED] = freshStats()
    },
    pending_captures = {},
    imap = {raw = {}, nrm = {}},
    fow = {},
    keysites = {},
    pilots = {},
    spawn_queue = {},
    _spawn_seq = 0,
    _spawn_drain_reported = false,
    patrol_groups = {},
    regen_queue = {},
    production = {},
    base_ammo = {},
    base_fuel = {},
    base_warehouse = {},
    base_assign_toggle = {},
    base_last_strike = {},
    base_ad_groups = {},
    base_fp_groups = {},
    sec_groups = {[BLUE] = {}, [RED] = {}},
    keysite_assist_timer = {},
    supply_delivered = {},
    supply_heavy_flag = false,
    _completed = {},
    _recycled = {},
    _board_diag = {}
}
____exports.SIDE_NAME = {[BLUE] = "BLUE", [RED] = "RED"}
____exports.ENEMY = {[BLUE] = RED, [RED] = BLUE}
local sequence = FIRST_DYNAMIC_ENTITY_ID
function ____exports.next_id()
    sequence = sequence + 1
    return sequence
end
function ____exports.register_task(gname, info)
    ____exports.S.active_tasks[gname] = info
    ____exports.stat_sortie(info.side)
end
function ____exports.get_task(gname)
    return ____exports.S.active_tasks[gname]
end
function ____exports.set_task_end_hook(hook)
    ____exports.task_end_hook = hook
end
function ____exports.clear_task(gname)
    __TS__Delete(____exports.S.active_tasks, gname)
    if ____exports.task_end_hook then
        do
            pcall(function()
                ____exports.task_end_hook(gname)
            end)
        end
    end
end
function ____exports.has_task_against(task_type, target_base, side)
    for ____, task in ipairs(__TS__ObjectValues(____exports.S.active_tasks)) do
        if task.task_type == task_type and task.target_base == target_base and task.side == side then
            return true
        end
    end
    return false
end
function ____exports.count_current_hardware(side)
    local count = 0
    for ____, group in ipairs(coalition.getGroups(side) or ({})) do
        do
            local __continue20
            repeat
                if not group or not group:isExist() then
                    __continue20 = true
                    break
                end
                for ____, unit in ipairs(group:getUnits() or ({})) do
                    if unit and unit:isExist() and unit:getLife() > MIN_LIVE_UNIT_LIFE then
                        count = count + 1
                    end
                end
                __continue20 = true
            until true
            if not __continue20 then
                break
            end
        end
    end
    return count
end
function ____exports.recalc_strength()
    local blue = ____exports.count_current_hardware(BLUE)
    local red = ____exports.count_current_hardware(RED)
    ____exports.S.force_current[BLUE] = blue
    ____exports.S.force_current[RED] = red
    local total = blue + red
    ____exports.S.strength[BLUE] = total > 0 and math.floor(blue / total * PERCENT_SCALE + PERCENT_ROUNDING_OFFSET) or BALANCED_FORCE_PERCENT
    ____exports.S.strength[RED] = total > 0 and math.floor(red / total * PERCENT_SCALE + PERCENT_ROUNDING_OFFSET) or BALANCED_FORCE_PERCENT
end
function ____exports.base_is_active(name)
    return ____exports.S.base_kind[name] ~= "farp" or ____exports.S.farp_active[name] == true
end
____exports.STAT_CATEGORIES = {
    "air",
    "heli",
    "ground",
    "ship",
    "structure",
    "other"
}
function ____exports.unit_category(obj)
    if not obj then
        return "other"
    end
    do
        local ____try, ____hasReturned, ____returnValue = pcall(function()
            local ____temp_0
            if obj.getGroup ~= nil then
                ____temp_0 = obj:getGroup()
            else
                ____temp_0 = nil
            end
            local group = ____temp_0
            local category = group and group:getCategory()
            if category == Group.Category.AIRPLANE then
                return true, "air"
            end
            if category == Group.Category.HELICOPTER then
                return true, "heli"
            end
            if category == Group.Category.GROUND then
                return true, "ground"
            end
            if category == Group.Category.SHIP then
                return true, "ship"
            end
        end)
        if ____try and ____hasReturned then
            return ____returnValue
        end
    end
    do
        local ____try, ____hasReturned, ____returnValue = pcall(function()
            local ____opt_3 = obj:getDesc()
            local attributes = ____opt_3 and ____opt_3.attributes or ({})
            if attributes.Helicopters then
                return true, "heli"
            end
            if attributes.Air or attributes.Planes then
                return true, "air"
            end
            if attributes.Ships then
                return true, "ship"
            end
            if attributes["Ground Units"] or attributes.Vehicles then
                return true, "ground"
            end
            if attributes.Buildings or attributes.Fortifications then
                return true, "structure"
            end
        end)
        if ____try and ____hasReturned then
            return ____returnValue
        end
    end
    do
        local ____try, ____hasReturned, ____returnValue = pcall(function()
            if obj:getCategory() == Object.Category.STATIC then
                return true, "structure"
            end
        end)
        if ____try and ____hasReturned then
            return ____returnValue
        end
    end
    return "other"
end
function ____exports.stat_kill(killer_side, victim_side, category)
    if category == nil then
        category = "other"
    end
    if killer_side ~= nil and ____exports.S.stats[killer_side] ~= nil then
        ____exports.S.stats[killer_side].kills[category] = (____exports.S.stats[killer_side].kills[category] or 0) + 1
    end
    if victim_side ~= nil and ____exports.S.stats[victim_side] ~= nil then
        ____exports.S.stats[victim_side].losses[category] = (____exports.S.stats[victim_side].losses[category] or 0) + 1
    end
end
function ____exports.stat_task_created(side)
    local ____exports_S_stats_side_7, ____tasks_created_8 = ____exports.S.stats[side], "tasks_created"
    ____exports_S_stats_side_7[____tasks_created_8] = ____exports_S_stats_side_7[____tasks_created_8] + 1
end
function ____exports.stat_task_result(side, result)
    local stats = ____exports.S.stats[side]
    if result == "failure" then
        stats.tasks_failed = stats.tasks_failed + 1
    elseif result == "partial" then
        stats.tasks_partial = stats.tasks_partial + 1
    else
        stats.tasks_completed = stats.tasks_completed + 1
    end
end
local function statTotal(values)
    local total = 0
    for ____, value in ipairs(__TS__ObjectValues(values)) do
        total = total + value
    end
    return total
end
function ____exports.stats_summary_line()
    local b = ____exports.S.stats[BLUE]
    local r = ____exports.S.stats[RED]
    return string.format(
        "STATS kills B=%d R=%d | losses B=%d R=%d | tasks(ok/part/fail) B=%d/%d/%d R=%d/%d/%d | sorties B=%d R=%d",
        statTotal(b.kills),
        statTotal(r.kills),
        statTotal(b.losses),
        statTotal(r.losses),
        b.tasks_completed,
        b.tasks_partial,
        b.tasks_failed,
        r.tasks_completed,
        r.tasks_partial,
        r.tasks_failed,
        b.sorties,
        r.sorties
    )
end
function ____exports.stats_text()
    local function byCategory(values)
        local parts = {}
        for ____, category in ipairs(____exports.STAT_CATEGORIES) do
            if (values[category] or 0) > 0 then
                parts[#parts + 1] = (category .. ":") .. tostring(values[category])
            end
        end
        return #parts > 0 and table.concat(parts, " ") or "none"
    end
    local function block(side)
        local value = ____exports.S.stats[side]
        return string.format(
            "%s\n  kills %d (%s)\n  losses %d (%s)\n  sorties %d\n  tasks: created %d, done %d, partial %d, failed %d",
            ____exports.SIDE_NAME[side],
            statTotal(value.kills),
            byCategory(value.kills),
            statTotal(value.losses),
            byCategory(value.losses),
            value.sorties,
            value.tasks_created,
            value.tasks_completed,
            value.tasks_partial,
            value.tasks_failed
        )
    end
    return (("=== CAMPAIGN STATS ===\n" .. block(BLUE)) .. "\n") .. block(RED)
end
function ____exports.assess_task(task, terminated)
    local successEnd = terminated == "route_complete"
    if (task and task.task_type) == "ground_strike" then
        local base = task.target_base
        local ____base_13
        if base then
            local ____opt_11 = ____exports.S.keysites[base]
            ____base_13 = ____opt_11 and ____opt_11.health
        else
            ____base_13 = nil
        end
        local installationHealth = ____base_13
        local efficiencyAfter = base and (____exports.S.base_health[base] or installationHealth or 1) or 1
        if base and (not ____exports.base_is_active(base) or efficiencyAfter < ____exports.MINIMUM_EFFICIENCY * STRIKE_NEUTRALISED_MARGIN) then
            return "success", 1
        end
        local rating = math.max(
            0,
            math.min(1, (task.eff_before or 1) - efficiencyAfter)
        )
        if rating >= STRIKE_SUCCESS_RATING then
            return "success", rating
        end
        if rating >= STRIKE_PARTIAL_RATING or successEnd then
            return "partial", rating
        end
        return "failure", rating
    end
    if (task and task.task_type) == "recon" or (task and task.task_type) == "bda" then
        if successEnd then
            return "success", 1
        end
        return "failure", 0
    end
    if successEnd then
        return "success", 1
    end
    return "failure", 0
end
function ____exports.wp_xy(world_pos)
    return world_pos.x, world_pos.z
end
function ____exports.dist2d(ax, az, bx, bz)
    local dx = ax - bx
    local dz = az - bz
    return math.sqrt(dx * dx + dz * dz)
end
function ____exports.heading_to(ax, az, bx, bz)
    return math.atan2(bz - az, bx - ax)
end
function ____exports.group_is_alive(group)
    if not group or not group:isExist() then
        return false
    end
    for ____, unit in ipairs(group:getUnits() or ({})) do
        if unit and unit:isExist() then
            return true
        end
    end
    return false
end
local SNAP_RADII_METRES = {
    200,
    500,
    1000,
    2000,
    4000
}
local SNAP_BEARING_COUNT = 8
local function surfaceAt(x, z)
    do
        local function ____catch(_error)
            return true, nil
        end
        local ____try, ____hasReturned, ____returnValue = pcall(function()
            return true, land.getSurfaceType({x = x, y = z})
        end)
        if not ____try then
            ____hasReturned, ____returnValue = ____catch(____hasReturned)
        end
        if ____hasReturned then
            return ____returnValue
        end
    end
end
local function isDry(surface)
    return surface == land.SurfaceType.LAND or surface == land.SurfaceType.ROAD or surface == land.SurfaceType.RUNWAY
end
function ____exports.snap_land(x, z, fx, fz)
    if fx == nil then
        fx = x
    end
    if fz == nil then
        fz = z
    end
    local surface = surfaceAt(x, z)
    if isDry(surface) then
        return {x = x, z = z}
    end
    for ____, radius in ipairs(SNAP_RADII_METRES) do
        for bearing = 0, SNAP_BEARING_COUNT - 1 do
            local angle = bearing * (math.pi * 2 / SNAP_BEARING_COUNT)
            local px = x + math.cos(angle) * radius
            local pz = z + math.sin(angle) * radius
            if isDry(surfaceAt(px, pz)) then
                ____exports.dbg(
                    "snap",
                    "moved (%.0f,%.0f) surf=%s -> land (%.0f,%.0f) r=%dm",
                    x,
                    z,
                    tostring(surface),
                    px,
                    pz,
                    radius
                )
                return {x = px, z = pz}
            end
        end
    end
    ____exports.dbg(
        "snap",
        "NO land within %dm of (%.0f,%.0f) surf=%s -> fallback (%.0f,%.0f)",
        SNAP_RADII_METRES[#SNAP_RADII_METRES],
        x,
        z,
        tostring(surface),
        fx,
        fz
    )
    return {x = fx, z = fz}
end
____exports.ESCORT_CRITICAL = 6
____exports.ESCORT_THRESHOLD = {
    ground_strike = 3,
    oca_strike = 3,
    sead = 5,
    troop_insertion = 3,
    supply = 6
}
local ESCORT_SECTOR_STEP_METRES = 25000
local ESCORT_THREAT_COMPONENT_CAP = 5
local ESCORT_CRITICAL_FLIGHT_COUNT = 2
local ESCORT_STANDARD_FLIGHT_COUNT = 1
function ____exports.route_difficulty(side, from_pos, to_pos)
    if not from_pos or not to_pos then
        return 0, 0, 0
    end
    local imap = require("imap")
    local dx = to_pos.x - from_pos.x
    local dz = to_pos.z - from_pos.z
    local count = math.max(
        1,
        math.floor(math.sqrt(dx * dx + dz * dz) / ESCORT_SECTOR_STEP_METRES)
    )
    local seen = {}
    local airThreats = 0
    local enemySectors = 0
    for i = 0, count do
        local fraction = i / count
        local px = from_pos.x + dx * fraction
        local pz = from_pos.z + dz * fraction
        local best
        local bestDistance = math.huge
        for ____, ____value in ipairs(__TS__ObjectEntries(____exports.S.base_pos)) do
            local name = ____value[1]
            local pos = ____value[2]
            do
                local __continue91
                repeat
                    if ____exports.S.base_owner[name] == nil then
                        __continue91 = true
                        break
                    end
                    local ex = px - pos.x
                    local ez = pz - pos.z
                    local distance = ex * ex + ez * ez
                    if distance < bestDistance then
                        bestDistance = distance
                        best = name
                    end
                    __continue91 = true
                until true
                if not __continue91 then
                    break
                end
            end
        end
        if best and not seen[best] then
            seen[best] = true
            local pos = ____exports.S.base_pos[best]
            if imap.get(side, imap.AIR_DEFENCE, pos) > 0 then
                airThreats = airThreats + 1
            end
            if ____exports.S.base_owner[best] ~= side then
                enemySectors = enemySectors + 1
            end
        end
    end
    local difficulty = math.min(airThreats, ESCORT_THREAT_COMPONENT_CAP) + math.min(enemySectors, ESCORT_THREAT_COMPONENT_CAP)
    return difficulty, airThreats, enemySectors
end
function ____exports.escort_count(task_type, side, from_pos, to_pos, log_fn)
    if log_fn == nil then
        log_fn = function() return nil end
    end
    local threshold = ____exports.ESCORT_THRESHOLD[task_type]
    if threshold == nil then
        return 0
    end
    local difficulty, airThreats, enemySectors = ____exports.route_difficulty(side, from_pos, to_pos)
    local count = difficulty >= ____exports.ESCORT_CRITICAL and ESCORT_CRITICAL_FLIGHT_COUNT or (difficulty >= threshold and ESCORT_STANDARD_FLIGHT_COUNT or 0)
    log_fn(string.format(
        "escort assess %s %s: difficulty=%d (air=%d enemy=%d) threshold=%d -> %d",
        ____exports.SIDE_NAME[side],
        task_type,
        difficulty,
        airThreats,
        enemySectors,
        threshold,
        count
    ))
    return count
end
return ____exports
 end,
["airbase_clearance"] = function(...) 
local ____lualib = require("lualib_bundle")
local __TS__SourceMapTraceBack = ____lualib.__TS__SourceMapTraceBack
local ____exports = {}
local cs = require("campaign_state")
local EDGE_BUFFER_METRES = 200
local NO_GEOMETRY_RADIUS_METRES = 2500
local MAX_ATTEMPTS = 12
local cachedGeneration = -1
local cachedExtents = {}
local lastKnownAirfields = {}
local warnedFailures = {}
local function finite(value)
    return value < math.huge and value > -math.huge
end
local function cache(name, area)
    cachedExtents[name] = area
    return area
end
local function resetForGeneration()
    if cachedGeneration == cs.GENERATION then
        return
    end
    cachedGeneration = cs.GENERATION
    cachedExtents = {}
    lastKnownAirfields = {}
    warnedFailures = {}
end
local function warnOnce(key)
    if warnedFailures[key] then
        return
    end
    warnedFailures[key] = true
    env.info(("[airbase_clearance] airbase geometry read failed: " .. key) .. "; retaining known bounds")
end
local function airfields()
    resetForGeneration()
    local result = {}
    local seen = {}
    for ____, side in ipairs({0, 1, 2}) do
        do
            local __continue9
            repeat
                local listOk, bases = pcall(function() return coalition.getAirbases(side) end)
                if not listOk or not bases then
                    warnOnce("coalition " .. tostring(side))
                    __continue9 = true
                    break
                end
                do
                    local index = 0
                    while index < #bases do
                        do
                            local __continue13
                            repeat
                                local base = bases[index + 1]
                                local nameOk, name = pcall(function() return base:getName() end)
                                if not nameOk or not name then
                                    warnOnce((("coalition " .. tostring(side)) .. " airbase ") .. tostring(index + 1))
                                    __continue13 = true
                                    break
                                end
                                local readOk, data = pcall(function()
                                    local ____opt_0 = base:getDesc()
                                    return {
                                        category = ____opt_0 and ____opt_0.category,
                                        position = base:getPosition().p
                                    }
                                end)
                                if not readOk or not data then
                                    warnOnce(name)
                                    __continue13 = true
                                    break
                                end
                                if data.category ~= Airbase.Category.AIRDROME then
                                    __continue13 = true
                                    break
                                end
                                local p = data.position
                                if not finite(p.x) or not finite(p.z) then
                                    warnOnce(name)
                                    __continue13 = true
                                    break
                                end
                                if seen[name] then
                                    __continue13 = true
                                    break
                                end
                                seen[name] = true
                                local centre = {x = p.x, z = p.z}
                                lastKnownAirfields[name] = centre
                                result[#result + 1] = {name = name, centre = centre}
                                __continue13 = true
                            until true
                            if not __continue13 then
                                break
                            end
                        end
                        index = index + 1
                    end
                end
                __continue9 = true
            until true
            if not __continue9 then
                break
            end
        end
    end
    for name, centre in pairs(lastKnownAirfields) do
        if not seen[name] then
            result[#result + 1] = {name = name, centre = centre}
        end
    end
    return result
end
local function extent(name, centre)
    resetForGeneration()
    local cached = cachedExtents[name]
    if cached ~= nil then
        return cached
    end
    local fallback = {x = centre.x, z = centre.z, radius = NO_GEOMETRY_RADIUS_METRES}
    local lookupOk, base = pcall(function() return Airbase.getByName(name) end)
    if not lookupOk then
        warnOnce(name)
    end
    if not lookupOk or base == nil then
        return cache(name, fallback)
    end
    local methodsOk, hasGeometryMethods = pcall(function() return base.getRunways ~= nil and base.getParking ~= nil end)
    if not methodsOk then
        warnOnce(name)
    end
    if not methodsOk or not hasGeometryMethods then
        return cache(name, fallback)
    end
    local runwaysOk, runways = pcall(function() return base:getRunways() end)
    local parkingOk, parking = pcall(function() return base:getParking() end)
    if not runwaysOk or not parkingOk then
        warnOnce(name)
    end
    if not runwaysOk or not parkingOk or not runways or not parking or #runways == 0 then
        return cache(name, fallback)
    end
    local radius = 0
    for ____, runway in ipairs(runways) do
        local p = runway.position
        if not p or not finite(p.x) or not finite(p.z) or not finite(runway.length) or not finite(runway.width) or runway.length <= 0 or runway.width <= 0 then
            return cache(name, fallback)
        end
        radius = math.max(
            radius,
            cs.dist2d(centre.x, centre.z, p.x, p.z) + runway.length + runway.width / 2
        )
    end
    for ____, spot in ipairs(parking) do
        local p = spot.vTerminalPos
        if not p or not finite(p.x) or not finite(p.z) then
            return cache(name, fallback)
        end
        radius = math.max(
            radius,
            cs.dist2d(centre.x, centre.z, p.x, p.z)
        )
    end
    return cache(
        name,
        {
            x = centre.x,
            z = centre.z,
            radius = math.max(radius + EDGE_BUFFER_METRES, NO_GEOMETRY_RADIUS_METRES)
        }
    )
end
function ____exports.is_clear(x, z, margin)
    if margin == nil then
        margin = 0
    end
    if not finite(x) or not finite(z) then
        return false
    end
    for ____, ____value in ipairs(airfields()) do
        local name = ____value.name
        local centre = ____value.centre
        local area = extent(name, centre)
        if cs.dist2d(x, z, area.x, area.z) <= area.radius + margin then
            return false
        end
    end
    return true
end
function ____exports.find_clear(base, initial, margin, label)
    if ____exports.is_clear(initial.x, initial.z, margin) then
        return initial
    end
    local safeRadius = NO_GEOMETRY_RADIUS_METRES + EDGE_BUFFER_METRES + margin
    for ____, ____value in ipairs(airfields()) do
        local name = ____value.name
        local centre = ____value.centre
        local area = extent(name, centre)
        if cs.dist2d(initial.x, initial.z, area.x, area.z) <= area.radius + margin then
            safeRadius = math.max(
                safeRadius,
                area.radius + margin + cs.dist2d(base.x, base.z, area.x, area.z) + EDGE_BUFFER_METRES
            )
        end
    end
    do
        local attempt = 0
        while attempt < MAX_ATTEMPTS do
            local angle = attempt * 2 * math.pi / MAX_ATTEMPTS
            local radius = safeRadius + attempt * EDGE_BUFFER_METRES
            local candidate = cs.snap_land(
                base.x + math.cos(angle) * radius,
                base.z + math.sin(angle) * radius,
                base.x,
                base.z
            )
            if ____exports.is_clear(candidate.x, candidate.z, margin) and land.getSurfaceType({x = candidate.x, y = candidate.z}) ~= land.SurfaceType.WATER then
                return candidate
            end
            attempt = attempt + 1
        end
    end
    env.info(string.format("[airbase_clearance] %s SKIP: no safe ground position after %d attempts", label, MAX_ATTEMPTS))
    return nil
end
return ____exports
 end,
["airbase_cleanup"] = function(...) 
local ____lualib = require("lualib_bundle")
local __TS__Delete = ____lualib.__TS__Delete
local __TS__SourceMapTraceBack = ____lualib.__TS__SourceMapTraceBack
local ____exports = {}
local clearance = require("airbase_clearance")
local cs = require("campaign_state")
local ____sides = require("sides")
local BLUE = ____sides.BLUE
local RED = ____sides.RED
local PERIOD_SECONDS = 30
local ROUTE_SPEED_METRES_PER_SECOND = 4
local ROUTE_MARGIN_METRES = 200
local RETRY_SECONDS = 120
local PROGRESS_METRES = 50
local trackedGeneration = -1
local ordered = {}
local failed = {}
function ____exports.sweep(logFn)
    if logFn == nil then
        logFn = env.info
    end
    if trackedGeneration ~= cs.GENERATION then
        trackedGeneration = cs.GENERATION
        ordered = {}
        failed = {}
    end
    local detected = 0
    local routed = 0
    local cleared = 0
    local failures = 0
    local seen = {}
    for ____, side in ipairs({0, BLUE, RED}) do
        do
            local __continue4
            repeat
                local readOk, groups = pcall(function() return coalition.getGroups(side, Group.Category.GROUND) end)
                if not readOk or not groups then
                    __continue4 = true
                    break
                end
                for ____, group in ipairs(groups) do
                    do
                        local __continue7
                        repeat
                            local nameOk, name = pcall(function() return group:getName() end)
                            if not nameOk or not name then
                                __continue7 = true
                                break
                            end
                            seen[name] = true
                            local unitsOk, units = pcall(function() return group:getUnits() end)
                            if not unitsOk or not units or #units == 0 then
                                __continue7 = true
                                break
                            end
                            local blocked = false
                            local inside
                            local lead
                            local player = false
                            for ____, unit in ipairs(units) do
                                local readUnit, data = pcall(function() return {
                                    point = unit:getPoint(),
                                    player = unit:getPlayerName()
                                } end)
                                if not readUnit or not data then
                                    blocked = true
                                    break
                                end
                                if data.player ~= nil then
                                    player = true
                                end
                                if lead == nil then
                                    lead = {x = data.point.x, z = data.point.z}
                                end
                                local clearOk, clear = pcall(function() return clearance.is_clear(data.point.x, data.point.z) end)
                                if not clearOk then
                                    blocked = true
                                    break
                                end
                                if not clear then
                                    inside = {x = data.point.x, z = data.point.z}
                                end
                            end
                            if player or blocked or not lead then
                                __continue7 = true
                                break
                            end
                            if not inside then
                                if ordered[name] then
                                    __TS__Delete(ordered, name)
                                    cleared = cleared + 1
                                    logFn("[airbase_clearance] cleared " .. name)
                                end
                                __TS__Delete(failed, name)
                                __continue7 = true
                                break
                            end
                            detected = detected + 1
                            local prior = ordered[name]
                            if prior and cs.dist2d(lead.x, lead.z, prior.x, prior.z) >= PROGRESS_METRES then
                                prior.x = lead.x
                                prior.z = lead.z
                                prior.at = timer.getTime()
                            end
                            if prior and timer.getTime() - prior.at < RETRY_SECONDS then
                                __continue7 = true
                                break
                            end
                            if failed[name] ~= nil and timer.getTime() - failed[name] < RETRY_SECONDS then
                                __continue7 = true
                                break
                            end
                            if prior ~= nil then
                                logFn(("[airbase_clearance] stalled " .. name) .. ": retrying evacuation")
                            end
                            local targetOk, target = pcall(function() return clearance.find_clear(inside, inside, ROUTE_MARGIN_METRES, name) end)
                            if not targetOk or not target then
                                failed[name] = timer.getTime()
                                failures = failures + 1
                                logFn(("[airbase_clearance] failed " .. name) .. ": no safe route destination")
                                __continue7 = true
                                break
                            end
                            local taskOk = pcall(function() return group:getController():setTask({
                                id = "Mission",
                                params = {route = {points = {
                                    {
                                        type = "Turning Point",
                                        action = "Off Road",
                                        x = lead.x,
                                        y = lead.z,
                                        alt = land.getHeight({x = lead.x, y = lead.z}),
                                        alt_type = "BARO",
                                        speed = ROUTE_SPEED_METRES_PER_SECOND,
                                        ETA = 0,
                                        ETA_locked = false
                                    },
                                    {
                                        type = "Turning Point",
                                        action = "Off Road",
                                        x = target.x,
                                        y = target.z,
                                        alt = land.getHeight({x = target.x, y = target.z}),
                                        alt_type = "BARO",
                                        speed = ROUTE_SPEED_METRES_PER_SECOND,
                                        ETA = 0,
                                        ETA_locked = false
                                    }
                                }}}
                            }) end)
                            if taskOk then
                                ordered[name] = {
                                    x = lead.x,
                                    z = lead.z,
                                    at = timer.getTime()
                                }
                                __TS__Delete(failed, name)
                                routed = routed + 1
                                logFn(string.format("[airbase_clearance] routed %s to %.0f,%.0f", name, target.x, target.z))
                            else
                                failed[name] = timer.getTime()
                                failures = failures + 1
                                logFn(("[airbase_clearance] failed " .. name) .. ": route task rejected")
                            end
                            __continue7 = true
                        until true
                        if not __continue7 then
                            break
                        end
                    end
                end
                __continue4 = true
            until true
            if not __continue4 then
                break
            end
        end
    end
    for name in pairs(ordered) do
        if not seen[name] then
            __TS__Delete(ordered, name)
        end
    end
    for name in pairs(failed) do
        if not seen[name] then
            __TS__Delete(failed, name)
        end
    end
    if routed > 0 or cleared > 0 or failures > 0 then
        logFn(string.format(
            "[airbase_clearance] sweep detected=%d routed=%d cleared=%d failed=%d",
            detected,
            routed,
            cleared,
            failures
        ))
    end
end
function ____exports.schedule(logFn)
    if logFn == nil then
        logFn = env.info
    end
    local generation = _DMT_GEN
    timer.scheduleFunction(
        function(_, t)
            if _DMT_GEN ~= generation then
                return nil
            end
            local ok = pcall(function() return ____exports.sweep(logFn) end)
            if not ok then
                logFn("[airbase_clearance] sweep failed; retrying next interval")
            end
            return t + PERIOD_SECONDS
        end,
        nil,
        timer.getTime() + PERIOD_SECONDS
    )
end
return ____exports
 end,
}
assert(_DMT_GEN == ____trialGeneration, "generation changed before trial schedule")
assert(_G.__airbase_clearance_trial_scheduled == nil, "cleanup trial already scheduled")
local cleanup = require("airbase_cleanup")
assert(_DMT_GEN == ____trialGeneration, "generation changed while loading cleanup")
_G.__airbase_clearance_trial_scheduled = { generation = ____trialGeneration, at = timer.getTime() }
cleanup.schedule(function(message) env.info("[cleanup_live_trial] " .. message) end)
return { generation = _DMT_GEN, scheduled_at = _G.__airbase_clearance_trial_scheduled.at }
