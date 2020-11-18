#!/usr/bin/env lua

local args = {...}
local packages = {}
local order = {}

local outfile = table.remove(args,1)
local output = io.open(outfile,'wb')
if not output then
  print('error opening output file')
  os.exit(1)
end

output:write('local resty_mpd_packages = {}\n')

for i,v in ipairs(args) do
  local package = v:gsub('^src/','')
  package = package:gsub('%.lua$','')
  package = package:gsub('/','.')
  local var = package:gsub('%.','_')

  if not packages[var] then
    table.insert(order,var)
    local f = 'local function require_' .. var .. '()\n'
    for line in io.lines(v) do
      if line:match('require') then
        local req = line:match("require%(?'?([^']+)")
        local reqvar = req:gsub('%.','_')
        if packages[reqvar] then
          line = line:gsub('require.+','resty_mpd_packages.' .. reqvar)
        end
      end

      if var == 'resty_mpd_backend' and line:match('pcall') then
        line = "local ok, lib = resty_mpd_packages['resty_mpd_backend_' .. l], resty_mpd_packages['resty_mpd_backend_' .. l]\n"
      end

      f = f .. '  ' .. line .. '\n'
    end
    f = f .. 'end\n\n'
    packages[var] = f
  end

  output:write(packages[var])
end

output:write('local function resty_mpd_load()\n')
output:write('  local ok, package\n')

for i,v in ipairs(order) do
  output:write('  ok, package = pcall(require_' .. v .. ')\n')
  output:write('  if ok then\n')
  output:write('    resty_mpd_packages.' .. v .. ' = package\n')
  output:write('  end\n')
end
output:write('  return resty_mpd_packages.' .. order[#order] .. '\n')
output:write('end\n\n')
output:write('return resty_mpd_load()\n')

output:close()
