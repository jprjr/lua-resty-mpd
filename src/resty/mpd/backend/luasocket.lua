local tcp = require'socket'.tcp
local unix = require'socket.unix'
local unpack = unpack or table.unpack

local function nyi()
  return error('not implemented')
end

local socket    = {}
local condition = {}

function condition.new()
  return setmetatable({},{__index = condition})
end

condition.signal = nyi
condition.wait   = nyi

function socket.new()
  return setmetatable({condvar = condition.new()},{__index = socket})
end

function socket:connect(host,port)
  local s, args
  local ok, err

  if host and port then
    s = tcp()
    args = { host, port }
  elseif host then
    s = unix()
    args = { host }
  else
    return error('unable to parse url')
  end

  if self.timeout then
    s:settimeout(self.timeout)
  end

  ok, err = s:connect(unpack(args))

  if ok then
    self.socket = s
  end

  return ok, err
end

function socket:receive(a)
  local data, err = self.socket:receive(a)
  return data, err
end

function socket:send(a)
  local data, err = self.socket:send(a)
  return data, err
end

function socket:close()
  return self.socket:close()
end

function socket:settimeout(timeout)
  if type(timeout) == 'number' then
    timeout = timeout / 1000
  end
  if not self.socket then
    self.timeout = timeout
    return true
  end
  return self.socket:settimeout(timeout)
end

-- this will throw an error since condition variables
-- aren't implemented on this backend
function socket:signal()
  return self.condvar:signal()
end

function socket:tryreceive(a,f)
  local _,cb_err
  local timeoutflag = false

  local data,err = self:receive(a)
  if err and err == 'socket:timeout' then
    timeoutflag = true
    _,cb_err = f()
    if cb_err then return nil, cb_err end
    data, err = self:receive(a)
  end
  if not err and timeoutflag then
    err = 'socket:timeout'
  end
  return data, err
end

return {
  name      = 'luasocket',
  socket    = socket,
  condition = condition,
}
