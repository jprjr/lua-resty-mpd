--[[

module for loading backends, backends should provide
a table with two keys - "condition" and "socket",
they should have the following signatures:

all function should return:
truthy/false, err

The 'err' must be a string, it will be caught
and prefixed with the text 'socket:' or 'condition:'
to indicate where the error came from once it bubbles
up to the user.

condition.new()
condition:signal()
condition:wait()

socket.new()
socket:connect(host,port)
socket:close()
socket:receive(specifier)
socket:send(data)
socket:settimeout(timeout in millis)

socket:tryreceive(param) -- interruptable by socket:signal()
socket:signal() -- interrupt a tryreceive if active
]]

local function prefix_err(t,f)
  return function(...)
    local data, err = f(...)
    if err then
      err = t .. err
    end
    return data, err
  end
end

local prefix_exceptions = {
  ['tryreceive'] = true
}

-- all backend socket functions should return data, err
-- this captures the err value and prefixes it with 'socket:'
local function backend_wrap(lib)
  local proxy = {
    name = lib.name
  }
  for _,t in ipairs({'socket','condition'}) do
    proxy[t] = {}
    local s = t .. ':'
    for k,v in pairs(lib[t]) do
      -- exceptions, tryreceive ultimately returns receive()
      -- no need to proxy
      if prefix_exceptions[k] then
        proxy[t][k] = v
      elseif(type(v) == 'function') then
        proxy[t][k] = prefix_err(s,v)
      else
        error('lib returned a non-function')
      end
    end
    -- override the 'new' function to use our proxy as a metatable
    proxy[t]['new'] = function()
      local sock = lib[t].new()
      return setmetatable(sock,{__index = proxy[t]})
    end
  end

  return proxy
end

-- local table to hold loaded backends
local backends = {}

-- holds the name of the default backend, uses
-- the last loaded library.
--
-- Example: if a system has both luasocket and cqeueus,
-- the default is cqueues since that was loaded after
-- luasocket.
local last_backend = nil

for _,l in ipairs({'luasocket','cqueues','nginx'}) do
  local ok, lib = pcall(require,'resty.mpd.backend.'..l)
  if ok then
    backends[l] = backend_wrap(lib)
    last_backend = l
  end
end

-- throw an error if no backends were loaded
if last_backend == nil then
  return error('failed to load backend implementations')
end

-- compatibility with lua-resty-mpd
backends['ngx']    = backends['nginx']
backends['socket'] = backends['luasocket']

-- interface for requesting backends

local function backend_get(self,name)
  local ts = type(self)
  local tn = type(name)

  if ts == 'table' then -- called as backend:get
    if tn ~= 'string' then -- called as backend:get() or backend:get(not-a-string)
      name = last_backend
    end -- else was called as backend:get(name),
        -- check down below if name is valid
  elseif ts == 'nil' then -- called as backend()
    name = last_backend
  end

  -- other cases
  --   type(self) == 'function' - still use name

  if not (name and backends[name]) then
    name = last_backend
  end

  return backends[name]
end

return setmetatable({
  get = backend_get,
}, {
  __call = backend_get
})
