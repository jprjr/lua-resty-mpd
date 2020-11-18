local mpd = {
  _VERSION = '5.0.1'
}

local backend = require'resty.mpd.backend'
local commands = require'resty.mpd.commands'
local stack = require'resty.mpd.stack'

mpd._backend = backend()

local client = setmetatable({},{__index = commands})
local client_mt = { __index = client }

local function parse_version(str)
  local parts = {}
  for part in string.gmatch(str,'%d+') do
    table.insert(parts,tonumber(part))
  end

  return setmetatable({},{
    __index = function(_,k)
      if type(k) == 'string' then
        if k:match('^ma') then
          return parts[1]
        elseif k:match('^mi') then
          return parts[2]
        elseif k:match('^p') then
          return parts[3]
        else
          return nil
        end
      elseif type(k) == 'number' then
        return parts[k]
      end
      return nil
    end,
    __tostring = function()
      return table.concat(parts,'.')
    end,
  })
end

function client:backend(name)
  -- if we're connected already then just return the active backend
  if self.socket then return self._backend end

  self._backend = backend(name or self._backend.name)
  return self._backend
end

function client:settimeout(t)
  local ok, err
  self._timeout = t
  if self.socket then
    ok, err = self.socket:settimeout(self._timeout)
    if not err then ok = true end
  end
  return ok, err
end

function client:connect(host,port)
  local socket, ok, err, line, version

  socket = self._backend.socket.new()
  if self._timeout then
    ok, err = socket:settimeout(self._timeout)
    if not ok then return nil, err end
  end

  if not port then -- this may have been called with the single 'tcp://adsfadf'
    local url = host
    local proto = string.match(url,'^(%a+):')
    if not proto then
      if string.match(url,'^[A-Za-z0-9.-]+:?') then
        proto = 'tcp'
      else
        proto = 'unix'
      end
    end
    if proto == 'tcp' then
      url = string.gsub(url,'^tcp://','')
      host = string.match(url,'^([^:]+)')
      url = string.gsub(url,'^[^:]+','')
      port = string.match(url,'^:?(%d+)')
      port = tonumber(port) or 6600
    else
      host = string.gsub(url,'^unix:','')
    end
  end

  ok, err = socket:connect(host,port)
  if not ok then
    return nil, err
  end

  line, err = socket:receive('*l')
  if err then
    socket:close()
    return nil, err
  end

  version = line:match('^OK MPD%s([^\n]+)')
  if not version then
    socket:close()
    return nil, 'unable to determine MPD server version'
  end

  self.server_version = parse_version(version)

  self.socket = socket

  return true
end

function mpd.new()
  local self = {
    _backend = mpd._backend,
    stack = stack.new(),
  }
  setmetatable(self,client_mt)

  return self
end

function mpd:backend(name)
  mpd._backend = backend(name)
  return mpd._backend
end

return setmetatable(mpd,{__call = mpd.new})
