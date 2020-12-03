local resty_mpd_packages = {}
local function require_resty_mpd_stack()
  local stack = {}
  stack.__index = stack
  
  function stack.new()
    local self = {
      first = 1,
      last = 0,
      data = {}
    }
    setmetatable(self,stack)
    return self
  end
  
  function stack:length()
    return self.last - self.first + 1
  end
  
  -- insert at beginning
  function stack:unshift(d)
    self.first = self.first - 1
    self.data[self.first] = d
  end
  
  -- remove from beginning
  function stack:shift()
    local index = self.first
    local d = self.data[index]
    self.data[index] = nil
    self.first = self.first + 1
    return d
  end
  
  -- insert at end
  function stack:push(d)
    self.last = self.last + 1
    self.data[self.last] = d
  end
  
  -- remove from end
  function stack:pop()
    local index = self.last
    local d = self.data[index]
    self.data[index] = nil
    self.last = self.last - 1
    return d
  end
  
  -- returns the front of the stack without removing it
  function stack:front()
    if self:length() == 0 then
      return nil
    end
    return self.data[self.first]
  end
  
  -- returns the end of the stack without removing it
  function stack:rear()
    if self:length() == 0 then
      return nil
    end
    return self.data[self.last]
  end
  
  return stack
end

local function require_resty_mpd_backend_cqueues()
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
  
    if not err and not condvar_ready then
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
  
  
  
end

local function require_resty_mpd_backend_luasocket()
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
end

local function require_resty_mpd_backend_nginx()
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
end

local function require_resty_mpd_backend()
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
  local ok, lib = resty_mpd_packages['resty_mpd_backend_' .. l], resty_mpd_packages['resty_mpd_backend_' .. l]

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
end

local function require_resty_mpd_commands()
  -- implements MPD commands
  local stack_lib = resty_mpd_packages.resty_mpd_stack
  local unpack = unpack or table.unpack
  local commands = {}
  commands.__index = commands
  
  -- captures: errnum, linenum, cmd, msg
  local MPD_ERROR_PATTERN = '^ACK %[([^@]+)@([^%]]+)%] %{([^%}]*)%} ([^\n]+)'
  
  local replay_gain_modes = {
    off = true,
    track = true,
    album = true,
    auto = true
  }
  
  local function visit_table(tab,f)
    -- visits every key in a table recursively and calls f(key,val)
    if type(tab) ~= 'table' then return end
    for k,v in pairs(tab) do
      f(k,v)
      if type(v) == 'table' then
        visit_table(v,f)
      end
    end
  end
  
  local function qnext(self)
    self.stack:shift()
    local n = self.stack:front()
    if n then
      n:signal()
    end
  end
  
  
  local function cond_wrapper(f)
    return function(self,...)
      local cond = self._backend.condition.new()
  
      self.stack:push(cond)
      if self.stack:front() ~= cond then
        self.socket:signal()
        cond:wait()
      end
  
      -- in case we got disconnected before getting queued
      if not self.socket then
        return nil, 'socket:not connected'
      end
  
      local ret, err = f(self,...)
  
      qnext(self)
      return ret, err
    end
  end
  
  -- discards response and just returns pass/fail
  local function bool_wrapper(f)
    return function(...)
      local err = select(2,f(...))
      return err == nil,err
    end
  end
  
  local function escape_string(str)
    return '"' .. string.gsub(str,'([\\"])','\\%1') .. '"'
  end
  
  local end_params = {
    f = function(a)
      if type(a) ~= nil then error('extra parameter') end
    end,
    required = false,
  }
  
  local optional_string = {
    f = function(str)
      if type(str) == 'string' then return escape_string(str) end
    end,
    required = false
  }
  
  local mandatory_string = {
    f = function(str)
      if type(str) ~= 'string' then error('missing string parameter') end
      return escape_string(str)
    end,
    required = true
  }
  
  local mandatory_boolean = {
    f = function(val)
      if type(val) ~= 'boolean' then error('missing boolean parameter') end
      return val and 1 or 0
    end,
    required = true
  }
  
  local function optional_num(min,max)
    if not min then min = math.huge * -1 end
    if not max then max = math.huge end
    return {
      f = function(val)
        if type(val) ~= 'number' then return nil end
        if val < min or val > max then return error('value out of range') end
        return val
      end,
      required = false
    }
  end
  
  local function mandatory_num(min,max)
    if not min then min = math.huge * -1 end
    if not max then max = math.huge end
    return {
      f = function(val)
        if type(val) ~= 'number' then return error('missing integer parameter') end
        if val < min or val > max then return error('value out of range') end
        return val
      end,
      required = true
    }
  end
  
  
  local function build_filter_args(args,rs)
    local j = 1
    local splits = {}
    local t = false
    if j > #rs then return end
  
    -- up to and including MPD 0.20.0 filters looked like this
    --   find ARTIST "The Strokes" ALBUM "This Is It"
    -- since MPD 0.21.0 you can optionally use a new syntax
    --   find "((ARTIST == 'The Strokes') AND (ALBUM == 'This Is It'))"
    -- we'll check for a parenthesis to see if using the new vs old syntax
    if string.sub(rs[j],1,1) == '(' then
      table.insert(args,mandatory_string.f(rs[j]))
      j = j + 1
    end
  
    -- read remaining pairs and window parameters
    while j <= #rs do
      if rs[j] == 'window' then
        table.insert(args,mandatory_string.f('window'))
        table.insert(args,rs[j+1] .. ':' .. rs[j+2])
        j = j + 3
      else
        table.insert(args,mandatory_string.f(rs[j]))
        table.insert(args,mandatory_string.f(rs[j+1]))
        if string.lower(rs[j]) == 'group' then
          splits[string.lower(rs[j+1])] = {}
          t = true
        end
        j = j + 2
      end
    end
  
    if t then -- this means we had at least 1 group option
      table.insert(args,splits)
    end
  
    return args
  end
  
  
  local function validate_params(...)
    local validators = {...}
    local f = table.remove(validators)
    assert(type(f) == 'function')
  
    local total = 0
    local min = 0
    local max = math.huge
    for _,v in ipairs(validators) do
      if v == end_params then max = total end
      if v.required == true then
        min = min + 1
      end
      total = total + 1
    end
  
    return function(self,...)
      local args = {...}
      local newargs = { self }
  
      if #args < min then
        return error('missing required arguments')
      end
      if #args > max then
        return error('too many parameters')
      end
      for i,a in ipairs(args) do
        if validators[i] then
          local p = validators[i].f(a)
          if p then
            table.insert(newargs,p)
          end
        else
          table.insert(newargs,a)
        end
      end
      return f(unpack(newargs))
    end
  end
  
  local function send_and_read(self,...)
    local data, err
    local binary = 0
    local response = {}
    local tokens = {}
    local splits = nil
    local i = 0
    local holds = {}
  
    for _,a in ipairs({...}) do
      if type(a) == 'table' then
        splits = a
      else
        table.insert(tokens,a)
      end
    end
  
    -- splits can be a table or array, convert the array kind
    -- into a table
    if splits then
      if #splits > 0 then
        local newsplits = {}
        for _,k in ipairs(splits) do
          newsplits[k] = {}
        end
        splits = newsplits
      end
  
      -- determine if any split options have holds
      for q,t in pairs(splits) do
        visit_table(t,function(k)
          holds[k] = ''
        end)
        splits[q] = true
      end
    end
  
    data, err = self.socket:send(table.concat(tokens,' ') .. '\n')
    if not data then return nil, err end
  
    while true do
  
      data, err = self.socket:receive(binary > 0 and binary or '*l')
      if not data then return nil, err end
  
      if binary > 0 then
        response['binary'] = string.sub(data,1,string.len(data)-1)
        binary = 0
      else
        if string.match(data,'^OK') then
          return response
        end
  
        local errnum, _, _, msg = string.match(data,MPD_ERROR_PATTERN)
        if errnum then
          return nil, string.format('mpd:%s(%s)',errnum, msg)
        end
  
        local col = string.find(data,':')
        if col then
          local key = string.sub(data,1,col-1):lower():gsub('^%s+',''):gsub('%s+$','')
          local val = string.sub(data,col+1):gsub('^%s+',''):gsub('%s+$','')
          local t = tonumber(val)
          if t then
            val = t
          end
          if splits then
            if splits[key] == true then
              i = i + 1
              response[i] = {}
              for k,v in pairs(holds) do
                response[i][k] = v
              end
            end
            if holds[key] ~= nil then
              holds[key] = val
            else
              response[i][key] = val
            end
          else
            response[key] = val
          end
  
          if key == 'binary' then
            binary = val + 1
          end
        end
      end
    end
  end
  
  local function generic_send(cmd,s)
    return function(self,...)
      local args = {...}
      if s then
        table.insert(args, { s })
      end
      return send_and_read(self,cmd,unpack(args))
    end
  end
  
  function commands:close()
    if not self.socket then
      return nil,'socket:not connected'
    end
    local cond = self._backend.condition.new()
    local stack = stack_lib.new()
  
    -- save any old condition variables to signal
    while self.stack:length() > 1 do
      stack:push(self.stack:pop())
    end
  
    -- now we're next!
    self.stack:push(cond)
  
    while stack:length() > 0 do
      self.stack:push(stack:pop())
    end
  
    if self.stack:front() ~= cond then
      self.socket:signal()
      cond:wait()
    end
  
    local ok, err = self.socket:close()
    self.socket = nil
  
    qnext(self)
    return ok, err
  end
  
  
  function commands:idle()
    -- some duplication -- idle is the only command
    -- that can be interrupted, need to watch for
    -- our object's condvar
  
    local cond = self._backend.condition.new()
    local response = {}
    local line, err
    local errnum, msg, _
  
    self.stack:push(cond)
    if self.stack:front() ~= cond then
      cond:wait()
    end
  
    -- in case we got disconnected before getting queued
    if not self.socket then
      return nil, 'socket:not connected'
    end
  
    -- while we were waiting something else may have gotten queued,
    -- go ahead and just run the next thing
    if self.stack:length() > 1 then
      qnext(self)
      return {}
    end
  
    _, err = self.socket:send('idle\n')
    if err then
      -- this means we've been disconnected,
      -- advance the queue and return the error
      qnext(self)
      return nil, err
    end
  
    line, err = self.socket:tryreceive('*l',function()
      -- we were interrupted by our condvar or got a timeout
      return self.socket:send('noidle\n')
    end)
  
    while line do
      if line:match('^OK') then break end
      errnum, _, _, msg = string.match(line,MPD_ERROR_PATTERN)
      if errnum then
        err = string.format('mpd:%s(%s)',errnum, msg)
        break
      end
      local col = string.find(line,':')
      if col then
        line = string.sub(line,col+1):gsub('^%s',''):gsub('%s+$','')
        table.insert(response,line)
      end
      line,err = self.socket:receive('*l')
    end
  
    qnext(self)
    return response, err
  end
  
  -- 0 parameter commands that just return true or false
  for _,k in ipairs({'clearerror','next','previous','stop','clear','ping','kill'}) do
    commands[k] = validate_params(end_params,bool_wrapper(cond_wrapper(generic_send(k))))
  end
  
  -- 0 parameter commands that return a table
  for _,k in ipairs({'config','currentsong','status','stats','replay_gain_status','getvol','playlist'}) do
    commands[k] = validate_params(end_params,cond_wrapper(generic_send(k)))
  end
  
  -- 0 parameter commands that split on a field
  for k,v in pairs({
    noidle   = 'changed',
    outputs  = 'outputid',
    decoders = 'plugin',
    listplaylists = 'playlist',
    listmounts = 'mount',
    listneighbors = 'neighbor',
    channels = 'channel',
    readmessages = 'channel',
    commands = 'command',
    notcommands = 'command',
    tagtypes = 'tagtype',
    urlhandlers = 'handler',
    listpartitions = 'partition'}) do
    commands[k] = validate_params(
      end_params,
      cond_wrapper(
      generic_send(k,v)))
  end
  
  -- remaining params are marked as follows
  -- (kind)(restrictions)(is-optional)
  --
  -- kind is:
  --   bool
  --   string
  --   int
  --   float
  --
  -- restrictions
  --   >=0
  --   <0
  --   0<=x<=(max)
  --
  -- optional is represented by a question mark
  --
  -- example, setvol requires a value between 0 and 100 so it would show
  --   int0<=x<=100
  --
  -- seek requires a songpos (integer) and time (float) parameter, it would show
  --   int>=0 float>=0
  
  -- int>=0?
  -- @return boolean
  for _,k in ipairs({ 'play', 'playid' }) do
    commands[k] = validate_params(
      optional_num(0),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- int>=0
  -- @return boolean
  for _,k in ipairs({ 'crossfade','disableoutput','enableoutput','toggleoutput' }) do
    commands[k] = validate_params(
      mandatory_num(0),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- string string
  -- @return boolean
  for _,k in ipairs({ 'playlistadd','rename','sendmessage','mount'}) do
    commands[k] = validate_params(
      mandatory_string,
      mandatory_string,
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- string
  -- @return boolean
  for _,k in ipairs({
    'add','playlistclear','rm','save','password','unmount','subscribe',
    'unsubscribe','partition','newpartition','delpartition','moveoutput'}) do
    commands[k] = validate_params(
      mandatory_string,
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- string
  -- @return table
  for _,k in ipairs({'listplaylist','listplaylistinfo','readcomments','getfingerprint'}) do
    commands[k] = validate_params(
      mandatory_string,
      end_params,
      cond_wrapper(
      generic_send(k)))
  end
  
  -- string?
  -- @return table
  for _,k in ipairs({'listfiles','listall','listallinfo','lsinfo'}) do
    commands[k] = validate_params(
      optional_string,
      end_params,
      cond_wrapper(
      generic_send(k)))
  end
  
  -- string?
  -- @return table
  for _,k in ipairs({'update','rescan'}) do
    commands[k] = validate_params(
      optional_string,
      end_params,
      cond_wrapper(
      generic_send(k)))
  end
  
  -- string int>=0?
  -- @return boolean
  for _,k in ipairs({'addid'}) do
    commands[k] = validate_params(
      mandatory_string,
      optional_num(0),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- int>=0 float>=0
  -- @return boolean
  for _,k in ipairs({'seek','seekid'}) do
    commands[k] = validate_params(
      mandatory_num(0),
      mandatory_num(0),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- float
  -- @return boolean
  for _,k in ipairs({'seekcur'}) do
    commands[k] = validate_params(
      mandatory_num(),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- int<0
  -- @return boolean
  for _,k in ipairs({'mixrampdb'}) do
    commands[k] = validate_params(
      mandatory_num(nil,0),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- boolean
  -- @return boolean
  for _,k in ipairs({'consume','random','repeat','random','single','pause'}) do
    commands[k] = validate_params(
    mandatory_boolean,
    end_params,bool_wrapper(
    cond_wrapper(
    generic_send(k))))
  end
  
  -- int0=<x<=100
  -- @return boolean
  for _,k in ipairs({'setvol'}) do
    commands[k] = validate_params(
      mandatory_num(0,100),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- int>=0 float>=0? float>=0?
  -- @return boolean
  for _,k in ipairs({'rangeid'}) do
    commands[k] = validate_params(
      mandatory_num(0),
      optional_num(0),
      optional_num(0),
      bool_wrapper(
      cond_wrapper(
      function(self,id,s,e)
        if not s then
          s = ''
        end
        if not e then
          e = ''
        end
        return send_and_read(self,k,id,s .. ':' .. e)
      end)))
  end
  
  -- int>=0 int>=0? int>=0?
  -- @return table
  for _,k in ipairs({'plchanges','plchangesposid'}) do
    commands[k] = validate_params(
      mandatory_num(0),
      optional_num(0),
      optional_num(0),
      cond_wrapper(
      function(self,version,s,e)
          if e then
            s = tostring(s) .. ':' .. tostring(e)
          end
          return send_and_read(self,k,version,s, { k == 'plchanges' and 'file' or 'cpos' })
       end))
  end
  
  -- int0<=x<=255 int>=0 int>=0 (repeat int>=0 int>=0)...
  -- @return boolean
  for _,k in ipairs({'prio'}) do
    commands[k] = validate_params(
      mandatory_num(0,255),
      bool_wrapper(
      cond_wrapper(
      function(self,prio,...)
        local rs = {...}
        if #rs <= 0 or #rs % 2 ~= 0 then
          return error(k .. ' requires pairs of start:end values')
        end
  
        local validator = mandatory_num(0)
  
        local args = { self, k, prio }
  
        for j=1,#rs,2 do
          table.insert(args,tostring(validator.f(rs[j])) .. ':' .. tostring(validator.f(rs[j+1])))
        end
  
        return send_and_read(unpack(args))
      end)))
  end
  
  -- this group is pretty complex
  -- @return table
  for _,k in ipairs({'find','search','findadd','searchadd'}) do
    commands[k] = cond_wrapper(function(self,...)
      local rs = {...}
      local args = { self, k }
      build_filter_args(args,rs)
  
      table.insert(args,{'file'})
  
      return send_and_read(unpack(args))
    end)
  end
  
  -- @return table
  for _,k in ipairs({'count'}) do
    commands[k] = cond_wrapper(function(self,...)
      local rs = {...}
      local args = { self, k }
      build_filter_args(args,rs)
  
      return send_and_read(unpack(args))
    end)
  end
  
  -- @return boolean
  for _,k in ipairs({'findadd','searchadd'}) do
    commands[k] = cond_wrapper(function(self,...)
      local rs = {...}
      local args = { self, k }
      build_filter_args(args,rs)
  
      local _,err = send_and_read(unpack(args))
      return err == nil, err
    end)
  end
  
  -- not using mandatory_string since it autoquotes
  -- @return boolean
  for _,k in ipairs({'searchaddpl'}) do
    commands[k] = cond_wrapper(function(self,playlist,...)
      local args = { self, k, mandatory_string.f(playlist) }
      local rs = {...}
      build_filter_args(args,rs)
  
      local _,err = send_and_read(unpack(args))
      return err == nil, err
    end)
  end
  
  -- @return table
  for _,k in ipairs({'list'}) do
    commands[k] = cond_wrapper(function(self,typ,...)
      local args = { self, k, mandatory_string.f(typ) }
      local rs = {...}
      build_filter_args(args,rs)
  
      if type(args[#args]) ~= 'table' then
        table.insert(args,{})
      end
      args[#args] = {
        [typ] = args[#args]
      }
  
      return send_and_read(unpack(args))
    end)
  end
  
  -- int0<=x<=255, int>0 (int>0...)?
  -- @return boolean
  for _,k in ipairs({'prioid'}) do
    commands[k] = validate_params(
      mandatory_num(0,255),
      mandatory_num(0),
      cond_wrapper(
      function(self,prio,id,...)
        local args = { self, k, prio, id }
        for _,v in ipairs({...}) do
          table.insert(args,mandatory_num(0).f(v))
        end
  
        local _,err = send_and_read(unpack(args))
        return err == nil, err
      end))
  end
  
  -- string int>0 int>0
  -- @return boolean
  for _,k in ipairs({'playlistmove'}) do
    commands[k] = validate_params(
      mandatory_string,
      mandatory_num(0),
      mandatory_num(0),
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- string int>0? int>0?
  -- @return boolean
  for _,k in ipairs({'load'}) do
    commands[k] = validate_params(
      mandatory_string,
      optional_num(0),
      optional_num(0),
      bool_wrapper(
      cond_wrapper(
      function(self,name,s,e)
        if s and not e then
          return error('load requires an end position if using start')
        end
        if s then
          s = tostring(s) .. ':' .. tostring(e)
        end
        return send_and_read(self,k,name,s)
      end)
    ))
  end
  
  --[[
  MPD returns sticker values as:
  sticker: sticker_name=value
  
  So for example, if a file has a sticker named "test" with the value "12345",
  the response from MPD is:
  sticker: test=12345
  
  In all sticker responses, I add 'key' and 'value' fields to save you
  a step, the original 'sticker' field will always be the original
  response from the server
  
  So then in lua, your table will look like
  {
    sticker = 'test=12345',
    key = 'test',
    value = '12345',
  }
  
  ]]
  
  local sticker_subcommands = {
    -- string string string
    -- @return table (object)
    ['get'] = validate_params(
      mandatory_string,
      mandatory_string,
      mandatory_string,
      cond_wrapper(function(self,typ,uri,name)
        local res, err = send_and_read(self,'sticker','get',typ,uri,name)
        if err then return nil, err end
        local eq = string.find(res.sticker,'=')
        return {
          sticker = res.sticker,
          key     = string.sub(res.sticker,1,eq-1),
          value   = string.sub(res.sticker,eq+1)
        }
      end)),
  
    -- string string string string
    -- @return boolean
    ['set'] = validate_params(
      mandatory_string,
      mandatory_string,
      mandatory_string,
      mandatory_string,
      cond_wrapper(
      bool_wrapper(
      function(self,typ,uri,name,value)
        return send_and_read(self,'sticker','set',typ,uri,name,value)
      end))),
  
    -- string string string?
    -- @return boolean
    ['delete'] = validate_params(
      mandatory_string,
      mandatory_string,
      optional_string,
      bool_wrapper(
      cond_wrapper(
      function(self,typ,uri,name)
        return send_and_read(self,'sticker','delete',typ,uri,name)
      end))),
  
    -- string string
    -- @return table (array)
    ['list'] = validate_params(
      mandatory_string,
      mandatory_string,
      cond_wrapper(function(self,typ,uri)
        local res, err = send_and_read(self,'sticker','list',typ,uri,{'sticker'})
        if err then return res, err end
  
        local o = {}
        for _,v in ipairs(res) do
          local eq = string.find(v.sticker,'=')
          table.insert(o, {
            sticker = v.sticker,
            key     = string.sub(v.sticker,1,eq-1),
            value   = string.sub(v.sticker,eq+1)
          })
        end
        return o
      end)),
  
    -- sticker string string string (string string)?
    -- @return table (array)
    ['find'] = validate_params(
      mandatory_string,
      mandatory_string,
      mandatory_string,
      cond_wrapper(function(self,typ,uri,name,eq,val)
        local args = {
          self,
          'sticker',
          'find',
          typ,
          uri,
          name
        }
  
        if eq and val then
          val = mandatory_string.f(val)
          table.insert(args,eq)
          table.insert(args,val)
        end
  
        table.insert(args, {'file'})
        local res, err = send_and_read(unpack(args))
        if err then return res, err end
  
        for _,v in ipairs(res) do
          eq = string.find(v.sticker,'=')
          v.key = string.sub(v.sticker,1,eq-1)
          v.value = string.sub(v.sticker,eq+1)
        end
  
        return res
      end)),
  }
  
  -- string (then a bunch more strings, see subcommands above)
  -- @return varies based on subcommand
  commands['sticker'] = function(self,cmd,...)
    if not (cmd or sticker_subcommands[cmd]) then
      return error('invalid sticker command')
    end
    return sticker_subcommands[cmd](self,...)
  end
  
  
  -- int>0 int>0 int>0?
  -- @return boolean
  for _,k in ipairs({'move'}) do
    commands[k] = validate_params(
      mandatory_num(0),
      mandatory_num(0),
      optional_num(0),
      bool_wrapper(
      cond_wrapper(
      function(self,s,e,t)
        -- can be {from} {to} or
        --        {start:end} {to}
        -- 2 ints = {from} {to}
        -- 3 ints = {start:end} {to}
        if not t then
          t = e
          e = nil
        end
  
        if e then
          s = tostring(s) .. ':' .. tostring(e)
        end
  
        return send_and_read(self,k,s,t)
      end)))
  end
  
  -- int>0 int
  -- @return boolean
  for _,k in ipairs({'moveid'}) do
    commands[k] = validate_params(
      mandatory_num(0),
      mandatory_num(),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- int>0 int>0?
  -- @return boolean
  for _,k in ipairs({'delete'}) do
    commands[k] = validate_params(
      mandatory_num(0),
      optional_num(0),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- int>0 string?
  -- @return boolean
  for _,k in ipairs({'cleartagid'}) do
    commands[k] = validate_params(
      mandatory_num(0),
      optional_string,
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- int>0 int>0
  -- @return boolean
  for _,k in ipairs({'swap','swapid'}) do
    commands[k] = validate_params(
      mandatory_num(0),
      mandatory_num(0),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- int>0?
  -- @return table
  for _,k in ipairs({'playlistid'}) do
    commands[k] = validate_params(
      optional_num(0),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- string int>0
  -- @return boolean
  for _,k in ipairs({'playlistdelete'}) do
    commands[k] = validate_params(
      mandatory_string,
      mandatory_num(0),
      end_params,
      bool_wrapper(
      cond_wrapper(
      generic_send(k))))
  end
  
  -- string int>0
  -- @return table
  for _,k in ipairs({'albumart','readpicture'}) do
    commands[k] = validate_params(
      mandatory_string,
      mandatory_num(0),
      end_params,
      cond_wrapper(
      generic_send(k)))
  end
  
  -- string string
  -- @return table
  for _,k in ipairs({'playlistfind','playlistsearch'}) do
    commands[k] = validate_params(
      mandatory_string,
      mandatory_string,
      end_params,
      cond_wrapper(
      generic_send(k)))
  end
  
  -- int>0? int>0?
  -- @return boolean
  for _,k in ipairs({'shuffle'}) do
    commands[k] = validate_params(
      optional_num(0),
      optional_num(0),
      end_params,
      bool_wrapper(
      cond_wrapper(
      function(self,s,e)
        if s and e then
          s = tostring(s) .. ':' .. tostring(e)
        end
        return send_and_read(self,k,s)
      end))
    )
  end
  
  -- int>0? int>0?
  -- @return table
  for _,k in ipairs({'playlistinfo'}) do
    commands[k] = validate_params(
      optional_num(0),
      optional_num(0),
      cond_wrapper(
      function(self,s,e)
        if s and e then
          s = tostring(s) .. ':' .. tostring(e)
        end
        return send_and_read(self,k,s, { 'file' })
      end)
    )
  end
  
  -- takes a seconds value or 'nan'
  -- @return boolean
  commands.mixrampdelay = bool_wrapper(
    cond_wrapper(
    function(self,sec)
      sec = optional_num(sec)
      if type(sec) ~= 'number' then
        sec = 'nan'
      end
      return send_and_read(self,'mixrampdelay',sec)
    end))
  
  -- string (from a list)
  -- @return boolean
  commands.replay_gain_mode = bool_wrapper(
    cond_wrapper(
    function(self,mode)
      if type(mode) ~= 'string' then
        return error('missing string parameter')
      end
  
      if not replay_gain_modes[mode] then
        return error('invalid replay gain mode')
      end
  
      return send_and_read(self,'replay_gain_mode',mode)
    end))
  
  
  return commands
end

local function require_resty_mpd()
  local mpd = {
    _VERSION = '5.0.4'
  }
  
  local backend = resty_mpd_packages.resty_mpd_backend
  local commands = resty_mpd_packages.resty_mpd_commands
  local stack = resty_mpd_packages.resty_mpd_stack
  
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
end

local function resty_mpd_load()
  local ok, package
  ok, package = pcall(require_resty_mpd_stack)
  if ok then
    resty_mpd_packages.resty_mpd_stack = package
  end
  ok, package = pcall(require_resty_mpd_backend_cqueues)
  if ok then
    resty_mpd_packages.resty_mpd_backend_cqueues = package
  end
  ok, package = pcall(require_resty_mpd_backend_luasocket)
  if ok then
    resty_mpd_packages.resty_mpd_backend_luasocket = package
  end
  ok, package = pcall(require_resty_mpd_backend_nginx)
  if ok then
    resty_mpd_packages.resty_mpd_backend_nginx = package
  end
  ok, package = pcall(require_resty_mpd_backend)
  if ok then
    resty_mpd_packages.resty_mpd_backend = package
  end
  ok, package = pcall(require_resty_mpd_commands)
  if ok then
    resty_mpd_packages.resty_mpd_commands = package
  end
  ok, package = pcall(require_resty_mpd)
  if ok then
    resty_mpd_packages.resty_mpd = package
  end
  return resty_mpd_packages.resty_mpd
end

return resty_mpd_load()
