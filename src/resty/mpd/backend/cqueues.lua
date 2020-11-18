local cqueues = require'cqueues'
local errno   = require'cqueues.errno'
local cs = require'cqueues.socket'
local cv = require'cqueues.condition'

local function wrap_error(self,f,...)
  -- if you try to call send on a closed socket in
  -- cqueues an error is throw
  -- so when we call close we just remove self.socket,
  -- so now send/receive/etc can just return 'closed'
  -- instead of throwing.
  if not self then
    return nil,'closed'
  end

  local res, err = self[f](self,...)
  if type(err) == 'number' then
    if err == errno.ETIMEDOUT then
      err = 'timeout'
    else
      err = errno.strerror(err)
    end
  end
  return res, err
end

local socket    = {}
local condition = {}

function condition.new()
  local self = {
    cv = cv.new()
  }
  setmetatable(self,{ __index = condition })
  return self
end

function condition:signal()
  return self.cv:signal(1)
end

function condition:wait()
  return self.cv:wait()
end

function socket.new()
  local self = { }
  self.condvar = cv.new()

  return setmetatable(self,{ __index = socket })
end

function socket:connect(host,port)
  local ok, err, sock
  local s

  if host and port then
    s, err = cs.connect({
      host = host,
      port = port
    })
  else
    s, err = cs.connect({
      path = host
    })
  end

  if err then -- not sure if this can even happen?
    if type(err) == 'number' then
      err = errno.strerror(err)
    end
    return nil, err
  end

  s:setmode('b','b')
  if self.timeout then
    s:settimeout(self.timeout)
  end

  ok, sock = pcall(s.connect,s)
  if not ok then
    return nil, sock
  end

  self.socket = s
  return true, nil
end

function socket:receive(a)
  local data, err = wrap_error(self.socket,'read',a)
  return data, err
end

function socket:send(a)
  local data, err = wrap_error(self.socket,'write',a)
  return data, err
end

function socket:close()
  local ok,err = wrap_error(self.socket,'close')
  self.socket = nil
  return ok,err
end

function socket:settimeout(timeout)
  if type(timeout) == 'number' then
    timeout = timeout / 1000
  end

  if not self.socket then
    self.timeout = timeout
    return true
  end

  return wrap_error(self.socket,'settimeout',timeout)
end

function socket:signal()
  self.condvar:signal(1)
end

function socket:tryreceive(param,f)
  local _, cb_err
  local data, err

  local socket_ready = false
  local condvar_ready = false

  -- remove the old timeout and restore it after poll
  local timeout = self.socket:timeout()
  self.socket:settimeout()

  local socket_obj = {
    pollfd = function()
      return self.socket:pollfd()
    end,
    events = function()
      return 'r'
    end,
  }

  local ready = { cqueues.poll(socket_obj,self.condvar,timeout) }

  self.socket:settimeout(timeout)

  for i=1,#ready do
    if ready[i] == socket_obj then
      socket_ready = true
    elseif ready[i] == self.condvar then
      condvar_ready = true
    end
  end

  -- if condvar and socket ready are both false,
  -- we had a timeout, meaning we want to fire
  -- our callback anyway to call noidle
  if condvar_ready or not socket_ready then
    _, cb_err = f()
    if cb_err then
      return nil, cb_err
    end
  end

  data, err = self:receive(param)

  if not err and not socket_ready then
    -- this means we called receive because of
    -- a timeout, so set the err flag
    err = 'socket:timeout'
  end

  return data, err

end

return {
  name      = 'cqueues',
  socket    = socket,
  condition = condition,
}



