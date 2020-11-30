-- luacheck: globals ngx
local ngx_sem = require'ngx.semaphore'
local unpack = unpack or table.unpack

local socket    = {}
local condition = {}

function condition.new()
  local sem, err = ngx_sem.new()
  if not sem then
    error(err)
  end

  local self = {
    sema = sem,
  }

  setmetatable(self,{ __index = condition})
  return self
end

function condition:signal()
  if self.sema:count() < 0 then
    return self.sema:post(1)
  end
  return true
end

function condition:wait()
  local ok, err
  while true do
    ok, err = self.sema:wait(5)
    if ok then return ok end
    if err and err ~= 'timeout' then return nil, err end
  end
end

function socket.new()
  local self = {}
  self.condvar = condition.new()
  self.timeout = 2147483647

  return setmetatable(self,{__index = socket})
end

function socket:connect(host,port)
  local args, ok
  local s, err = ngx.socket.tcp()
  if err then return nil, err end

  if self.timeout then
    s:settimeout(self.timeout)
  end

  if host and port then
    args = { host, port }
  elseif host then
    args = { 'unix:' .. host }
  else
    return error('unable to parse ' .. host)
  end

  ok, err = s:connect(unpack(args))
  if ok then
    self.socket = s
  end
  return ok, err
end

function socket:receive(a)
  return self.socket:receive(a)
end

function socket:send(a)
  return self.socket:send(a)
end

function socket:close()
  return self.socket:close()
end

function socket:settimeout(timeout)
  if timeout == nil then
    -- openresty does not allow setting timeout
    -- to infinite like luasocket and cqueues,
    -- so we'll use the largest value (2^31 - 1)
    -- see https://github.com/openresty/lua-nginx-module/issues/1141
    timeout = 2147483647
  end
  if not self.socket then
    self.timeout = timeout
    return true
  end
  return self.socket:settimeout(timeout)
end

function socket:signal()
  return self.condvar:signal()
end

function socket:tryreceive(param,f)
  local data, err, ok, res1, cb_err, _
  local socket_ready = false
  local condvar_ready = false

  local lt, rt, st

  rt = ngx.thread.spawn(function()
    data, err = self:receive(param)
    if data or err ~= 'socket:timeout' then
      -- we're done trying to read either way
      socket_ready = true
    end
    return true
  end)

  st = ngx.thread.spawn(function()
    self.condvar:wait()
    condvar_ready = true
    return true
  end)

  ok, res1 = ngx.thread.wait(rt,st)
  if not ok then
    return error(res1)
  end

  -- if the condition variable was flagged or
  -- if we got a timeout, we want to fire the
  -- callback
  if condvar_ready or not socket_ready then
    _,cb_err = f()
    if cb_err then
      ngx.thread.kill(rt)
      ngx.thread.kill(st)
      return nil, cb_err
    end
  end

  if coroutine.status(rt) == 'running' then
    -- we were woken up by the condition variable, just
    -- need to wait on the receive thread to finish
    lt = rt
  else
    -- receive is done, wake the condvar to end the thread
    self.condvar:signal()
    lt = st
  end

  ok, res1 = ngx.thread.wait(lt)
  if not ok then return error(res1) end

  -- socket_ready remains false if we timed out, meaning
  -- we sent the noidle and should try reading again
  -- we'll also set the errflag to socket:timeout to
  -- bubble it up.
  if not socket_ready then
    data, err = self:receive(param)
    if not err then
      err = 'socket:timeout'
    end
  end

  return data, err
end


return {
  name      = 'nginx',
  socket    = socket,
  condition = condition,
}
