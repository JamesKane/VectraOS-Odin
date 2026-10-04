-- tests/user/luatest.lua: Lua 5.5 in the POSIX userland (M4 step 5a,
-- ADR-0015), run by /boot/bin/lua under svcd (tests/qemu/lua.ndb). The
-- language, the standard libraries, and what they ask of the C library:
-- files in /tmp, the environment, time, the arguments, require.

local checks, failed = 0, 0
local function check(ok, what)
  checks = checks + 1
  if not ok then
    failed = failed + 1
    print("luatest: FAILED " .. what)
  end
end

print("luatest: " .. _VERSION)
check(_VERSION == "Lua 5.5", "version")

-- The arguments, as svcd gave them.
check(arg[0] == "/boot/tests/luatest.lua" and arg[1] == "one" and arg[2] == "two words" and #arg == 2,
  "arguments")

-- Numbers: integers and floats, kept apart.
check(math.type(7 // 2) == "integer" and 7 // 2 == 3 and 7 / 2 == 3.5, "integer division")
check(math.maxinteger + 1 == math.mininteger, "integer wrap")
check(string.format("%.3f %d %x %g", math.pi, 42, 255, 1e300) == "3.142 42 ff 1e+300", "format")
check(tostring(0.5) == "0.5" and 0.1 + 0.2 ~= 0.3 and math.abs(0.1 + 0.2 - 0.3) < 1e-15, "floats") -- 5.5: tostring round-trips
check(math.floor(-3.5) == -4 and math.tointeger(3.0) == 3 and math.sqrt(16) == 4.0, "math")

-- Strings and patterns.
local s = "The quick brown fox"
check(s:upper() == "THE QUICK BROWN FOX" and s:sub(5, 9) == "quick" and #s == 19, "string basics")
local words = {}
for w in s:gmatch("%a+") do words[#words + 1] = w end
check(#words == 4 and words[4] == "fox", "gmatch")
check(s:gsub("o", "0") == "The quick br0wn f0x" and select(2, s:gsub("o", "0")) == 2, "gsub")
check(("key = value"):match("^(%w+)%s*=%s*(%w+)$") == "key", "match")
check(string.pack(">I4", 0x01020304) == "\1\2\3\4" and string.unpack("<i2", "\255\255") == -1, "pack")

-- UTF-8 (ADR-0013): é is two bytes and one character.
local cafe = "café"
check(#cafe == 5 and utf8.len(cafe) == 4 and utf8.char(0xe9) == "é" and utf8.codepoint(cafe, 4) == 0xe9,
  "utf8")
check(utf8.len("\xff") == nil, "utf8 invalid")

-- Tables, sorting, closures, varargs, goto.
local t = {5, 3, 8, 1}
table.sort(t)
check(table.concat(t, ",") == "1,3,5,8", "sort")
table.sort(t, function(a, b) return a > b end)
check(t[1] == 8 and t[4] == 1, "sort with a comparison")
local function counter()
  local n = 0
  return function() n = n + 1; return n end
end
local c1, c2 = counter(), counter()
c1(); c1()
check(c1() == 3 and c2() == 1, "closures")
local function count(...) return select("#", ...) end
check(count(1, nil, 3) == 3 and table.unpack({1, 2, 3}, 2) == 2, "varargs")
local n = 0
::again::
n = n + 1
if n < 3 then goto again end
check(n == 3, "goto")
local mt = {__index = function(_, k) return k .. "!" end, __add = function() return 42 end}
local obj = setmetatable({}, mt)
check(obj.hi == "hi!" and obj + obj == 42, "metatables")

-- Errors and coroutines.
local ok, err = pcall(error, {code = 7})
check(not ok and err.code == 7, "pcall")
ok, err = pcall(function() local x = nil; return x.y end)
check(not ok and err:find("attempt to index") ~= nil, "a runtime error")
local co = coroutine.wrap(function(a)
  local b = coroutine.yield(a + 1)
  return b * 2
end)
check(co(1) == 2 and co(10) == 20, "coroutines")
check(load("return 1 + 1")() == 2 and load("syntax error here") == nil, "load")

-- Files, in the POSIX namespace's /tmp.
local path = "/tmp/luatest.txt"
local f = assert(io.open(path, "w"))
f:write("line one\n", "line two\n", 3, "\n")
f:close()
local lines = {}
for l in io.lines(path) do lines[#lines + 1] = l end
check(#lines == 3 and lines[2] == "line two" and lines[3] == "3", "io.lines")
f = assert(io.open(path, "a+"))
f:write("appended\n")
f:seek("set", 0)
local all = f:read("a")
f:close()
check(all == "line one\nline two\n3\nappended\n", "append and read back")
f = assert(io.open(path, "rb"))
check(f:read("n") == nil and f:read("l") == "line one" and f:seek("end") == #all, "read formats and seek")
f:close()
check(os.rename(path, path .. ".2") and io.open(path) == nil, "rename")
check(os.remove(path .. ".2") and select(2, os.remove(path .. ".2")):find("No such file") ~= nil, "remove")
local tmp = os.tmpname()
check(type(tmp) == "string" and os.remove(tmp), "tmpname")

-- A module, found by require on package.path.
f = assert(io.open("/tmp/luamod.lua", "w"))
f:write("local M = {}\nfunction M.twice(x) return 2 * x end\nreturn M\n")
f:close()
package.path = "/tmp/?.lua"
local mod = require("luamod")
check(mod.twice(21) == 42 and package.loaded.luamod == mod, "require")
os.remove("/tmp/luamod.lua")

-- The environment and time.
check(os.getenv("GREETING") == "hello" and os.getenv("NO_SUCH_VARIABLE") == nil, "getenv")
local now = os.time()
-- No wall clock yet (docs/milestones.md's known gaps): time counts from boot.
check(now >= 0 and os.date("!%Y", 0) == "1970" and os.time({year = 2000, month = 1, day = 1, hour = 0}) ~= nil,
  "time")
check(type(os.clock()) == "number" and os.difftime(now + 5, now) == 5.0, "clock")
local r = math.random(1, 6)
check(r >= 1 and r <= 6, "random")
collectgarbage()
check(collectgarbage("count") > 0, "the collector")

print(string.format("luatest: %d checks, %d failed", checks, failed))
os.exit(failed == 0)
