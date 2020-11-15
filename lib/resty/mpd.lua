-- luacheck: globals ngx
local tcp
local unix
local socket_lib

-- base library
-- all compiled by LuaJIT
local type = type
local ipairs = ipairs
local tonumber = tonumber
local setmetatable = setmetatable
local error = error

-- string library
local match = string.match -- not compiled by LuaJIT
local sub = string.sub -- compiled by LuaJIT
local gsub = string.gsub -- not compiled by LuaJIT
local find = string.find -- only fixed searches compiled
local len = string.len -- compiled by LuaJIT
-- todo: replace string ops with things compiled by LuaJIT

-- table library
local remove = table.remove -- compiled in 2.1, only when popping in 2.0
local insert = table.insert -- compiled when pushing (true in this library)

-- math library
local huge = math.huge -- constant
local floor = math.floor

-- wrapper for a few different socket modules
local mpd_socket = {}
mpd_socket.nginx = {
  _name = 'ngx'
}
mpd_socket.cqueues = {
  _name = 'cqueues'
}
mpd_socket.socket = {
  _name = 'socket'
}
mpd_socket.nginx.tcp = {}
mpd_socket.nginx.unix = {}
mpd_socket.cqueues.tcp = {}
mpd_socket.cqueues.unix = {}
mpd_socket.socket.tcp = {}
mpd_socket.socket.unix = {}

setmetatable(mpd_socket.nginx,        { __index = mpd_socket })
setmetatable(mpd_socket.cqueues,      { __index = mpd_socket })
setmetatable(mpd_socket.socket,       { __index = mpd_socket })

setmetatable(mpd_socket.nginx.tcp,    { __index = mpd_socket.nginx })
setmetatable(mpd_socket.nginx.unix,   { __index = mpd_socket.nginx })

setmetatable(mpd_socket.cqueues.tcp,  { __index = mpd_socket.cqueues })
setmetatable(mpd_socket.cqueues.unix, { __index = mpd_socket.cqueues })

setmetatable(mpd_socket.socket.tcp,   { __index = mpd_socket.socket })
setmetatable(mpd_socket.socket.unix,  { __index = mpd_socket.socket })

mpd_socket.receive = function(self,amount)
  local data, err = self._socket:receive(amount)
  return data, err
end

mpd_socket.send = function(self,data)
  return self._socket:send(data)
end

mpd_socket.close = function(self)
  return self._socket:close()
end

mpd_socket.nginx.settimeout = function(self,timeout)
  return self._socket:settimeout(timeout)
end

mpd_socket.nginx.tcp.connect = function(self)
  return self._socket:connect(self._host,self._port)
end

mpd_socket.nginx.unix.connect = function(self)
  return self._socket:connect('unix:' .. self._path)
end

mpd_socket.cqueues.settimeout = function(self,timeout)
  if type(timeout) == 'number' then
    self._timeout = timeout / 1000
  else
    self._timeout = timeout
  end
  return true
end

mpd_socket.cqueues.connect = function(self)
  return self._socket:connect(self._timeout)
end

mpd_socket.cqueues.receive = function(self,amount)
  local data, err = self._socket:read(amount)
  return data, err
end

mpd_socket.cqueues.send = function(self,data)
  return self._socket:write(data)
end

mpd_socket.socket.settimeout = function(self,timeout)
  if type(timeout) == 'number' then
    self._socket:settimeout(floor(timeout / 1000))
  else
    self._socket:settimeout(timeout)
  end
  return true
end

mpd_socket.socket.tcp.connect = function(self)
  return self._socket:connect(self._host,self._port)
end

mpd_socket.socket.unix.connect = function(self)
  return self._socket:connect(self._path)
end

local function create_socket_funcs_nginx()
  return mpd_socket.nginx, function(host,port)
    local t = {
      _host = host,
      _port = port,
      _socket = ngx.socket.tcp()
    }
    setmetatable(t,{__index = mpd_socket.nginx.tcp})
    return t
  end, function(path)
    local t = {
      _path = path,
      _socket = ngx.socket.tcp()
    }
    setmetatable(t,{__index = mpd_socket.nginx.unix})
    return t
  end
end

local function create_socket_funcs_cqueues()
  local cqueues_lib = require'cqueues.socket'
  return mpd_socket.cqueues, function(host,port)
    local t = {
      _host = host,
      _port = port,
      _socket = cqueues_lib.connect({
        host = host,
        port =port
      })
    }
    t._socket:setmode('b-p','bla')
    setmetatable(t,{__index = mpd_socket.cqueues.tcp})
    return t
  end, function(path)
    local t = {
      _path = path,
      _socket = cqueues_lib.connect({
        path = path
      })
    }
    t._socket:setmode('b-p','bla')
    setmetatable(t,{__index = mpd_socket.cqueues.unix})
    return t
  end
end

local function create_socket_funcs_socket()
  local luasocket_lib = require'socket'
  local unix_socket_lib = require'socket.unix'
  return mpd_socket.socket, function(host,port)
    local t = {
      _host = host,
      _port = port,
      _socket = luasocket_lib.tcp(),
    }
    setmetatable(t,{__index = mpd_socket.socket.tcp})
    return t
  end, function(path)
    local t = {
      _path = path,
      _socket = unix_socket_lib()
    }
    setmetatable(t,{__index = mpd_socket.socket.unix})
    return t
  end
end

local function create_socket_funcs()
  if ngx then
    return create_socket_funcs_nginx()
  end

  if pcall(require,'cqueues.socket') then
    return create_socket_funcs_cqueues()
  end

  if pcall(require,'socket') then
    return create_socket_funcs_socket()
  end

  return error('unable to find socket library')
end

local function use_socket_lib(lib)
  if lib == 'ngx' then
    return create_socket_funcs_nginx()
  end

  if lib == 'cqueues' then
    return create_socket_funcs_cqueues()
  end

  if lib == 'socket' then
    return create_socket_funcs_socket()
  end
  return error('unknown socket library: ' .. lib)
end

socket_lib, tcp, unix = create_socket_funcs()

local replay_gain_modes = {
    off = true,
    track = true,
    album = true,
    auto = true,
}

local sticker_cmds = {
    get = 3,
    set = 4,
    delete = 3,
    list = 2,
    find = 3,
}

local function get_lines(self, ...)
    local ok
    local binary = 0
    local res = {}
    local i = 0
    local split
    local splits = {...}

    if #splits > 0 then
        split = {}
        for _,v in ipairs({...}) do
            split[v] = true
        end
    end

    while(true) do
        local data, err
        repeat
            data, err = self.conn:receive(binary > 0 and binary or '*l')
        until data or (err and ( (err ~= 'timeout') or (err == 'timeout' and not self.timeout_continue)))

        if err then
            return nil, { msg = err }
        end

        if binary > 0 then
            res['binary'] = res['binary'] .. data
            binary = binary - len(data)
            if binary == 0 then
              res['binary'] = sub(res['binary'],1,len(res['binary']) - 1)
            end
        else
            if match(data,'^OK') then
                ok = true
                break
            end
            local errnum, linenum, cmd, msg = match(data,'^ACK %[([^@]+)@([^%]]+)%] %{([^%}]*)%} (.+)$')
            if errnum then
                ok = false
                res = {
                    errnum = tonumber(errnum),
                    linenum = tonumber(linenum) + 1,
                    cmd = cmd,
                    msg = msg
                }
                break
            end

            local col = find(data,':')

            if col then
                local key, val, t
                key = sub(data,1,col-1):lower():gsub('^%s+',''):gsub('%s+$','')
                val = sub(data,col+1):gsub('^%s+',''):gsub('%s+$','')
                t = tonumber(val)
                if t then
                    val = t
                end
                if split then
                    if split[key] == true then
                        i = i + 1
                        res[i] = {}
                    end
                    res[i][key] = val
                else
                    res[key] = val
                end
                if key == 'binary' then
                  binary = val + 1
                  res['binary'] = ''
                end
            end
        end
    end

    return ok, res
end

local function send_and_get(self, cmd, ...)
    local ok, res
    ok, res = self.conn:send(cmd .. '\n')

    if not ok then
        return nil, { msg = res }
    end

    ok, res = get_lines(self, ...)

    if not ok then
        return nil, res
    end
    return true, res
end

local function texty(val)
    -- escapes backslashes and quotes in URIs and such, adds quotes
    return '"' .. gsub(val,'([\\"])','\\%1') .. '"'
end

local function slidey(state, min, max)
    local st

    if not min then
        min = huge * -1
    end

    if not max then
        max = huge
    end

    local stt = type(state)
    if stt == 'boolean' then
        st = state and max or min
    elseif stt == 'nil' then
        st = 0
    else
        st = tonumber(state)
    end

    if st == nil or st < min or st > max then
        return nil
    end

    return st
end

local _M = {
    _VERSION = '4.0.0',
}
_M.__index = _M


function _M.global_socket_lib(name)
    if name ~= nil then
        socket_lib, tcp, unix = use_socket_lib(name)
    end
    return socket_lib._name
end

function _M:socket_lib(name)
    if name ~= nil then
        self._socket_lib, self._tcp, self._unix = use_socket_lib(name)
    end
    return self._socket_lib._name
end

function _M.new(opts)
    local self = {
        idling = false,
        timeout_continue = false,
    }
    opts = type(opts) == 'table' and opts or {
        timeout_continue = false
    }
    self.timeout_continue = opts.timeout_continue

    self._tcp = tcp
    self._unix = unix
    self._socket_lib = socket_lib

    setmetatable(self,_M)
    return self
end

function _M:connect(url)
    local proto = match(url,'^(%a+):')

    if proto then
        self.proto = proto
    elseif match(url,'^[A-Za-z0-9.-]+:?') then
        self.proto = 'tcp'
    else
        self.proto = 'unix'
    end

    if self.proto == 'tcp' then
        url = gsub(url,'^tcp://','')
        local host = match(url,'^([^:]+)')
        url = gsub(url,'^[^:]+','')
        local port = match(url,'^:?(%d+)')
        self.host = host
        self.port = tonumber(port) or 6600
    else
        local path = gsub(url,'^unix:','')

        self.proto = 'unix'
        self.path = path
    end

    return self:connected()
end

function _M:begin(conn)
    local data, err, p
    data, err, p = conn:receive('*l')
    if err then
        return nil, { msg = err }
    end

    if p then
        data = data .. p
    end

    if match(data,'^OK MPD') then
        self.conn = conn
        return true
    end
    conn:close()

    return nil, { msg = 'Connected to something but it\'s not MPD' }
end

function _M:connected()
    local conn
    if self.conn then
        return true
    end
    local _,err

    if self.proto == 'tcp' then
        conn, err = self._tcp(self.host,self.port)
        if err then return nil, { msg = err } end
    else
        conn, err = self._unix(self.path)
        if err then return nil, { msg = err } end
    end

    _,err = conn:connect()
    if err then
        return nil, { msg = err }
    end

    conn:settimeout(10000)

    _, err = self:begin(conn)
    if err then
      return err
    end

    conn:settimeout(nil)

    return true
end

function _M:ready_to_send()
    local ok, res
    ok, res = self:connected()
    if not ok then return nil, res end

    if self.idling then
      return nil, { msg = 'idling' }
    end

    return true
end

function _M:idle(...)
    local ok, res
    ok, res = self:ready_to_send()
    if not ok then return nil, res end

    local subs = {...}
    local s = ''
    for _,v in ipairs(subs) do
        s = s .. ' ' .. v
    end

    self.idling = true
    ok, res = send_and_get(self,'idle'..s,'changed')
    self.idling = false

    if not ok then
      return nil, res
    end

    local ret = {}
    for _,v in ipairs(res) do
      insert(ret,v.changed)
    end

    return ret

end

function _M:noidle()
    local ok, res
    ok, res = self:connected()
    if not ok then return nil, res end
    if not self.idling then return nil, { msg = 'not corrently idle' } end

    ok, res = self.conn:send('noidle\n')
    if not ok then
      return nil, { msg = res }
    end

    return ok ,res
end

-- 0PARM
for _,v in ipairs({'clearerror','next','previous','stop','clear','ping','kill'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v)

        if not ok then return nil, res end
        return true
    end
    if v == 'next' then
        _M['_next'] = _M['next']
    end
end

-- 0PARM
for _,v in ipairs({'outputs'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v,'outputid')

        if not ok then return nil, res end
        return res
    end
end

-- 0PARM
for _,v in ipairs({'decoders'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v,'plugin')

        if not ok then return nil, res end
        return res
    end
end

-- 0PARM
for _,v in ipairs({'listplaylists'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v,'playlist')

        if not ok then return nil, res end
        return res
    end
end

-- 0PARM
for _,v in ipairs({'listmounts'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v,'mount')

        if not ok then return nil, res end
        return res
    end
end

-- 0PARM
for _,v in ipairs({'listneighbors'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v,'neighbor')

        if not ok then return nil, res end
        return res
    end
end

-- 0PARM
for _,v in ipairs({'channels','readmessages'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v,'channel')

        if not ok then return nil, res end
        return res
    end
end

-- 0PARM
for _,v in ipairs({'commands','notcommands'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v,'command')

        if not ok then return nil, res end
        local l = {}
        for i=1,#res,1 do
            insert(l,res[i].command)
        end
        return l
    end
end

-- 0PARM
for _,v in ipairs({'tagtypes'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v,'tagtype')

        if not ok then return nil, res end
        local l = {}
        for i=1,#res,1 do
            l[res[i].tagtype:lower()] = true
        end
        return l
    end
end

-- 0PARM
for _,v in ipairs({'urlhandlers'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v,'handler')

        if not ok then return nil, res end
        local l = {}
        for i=1,#res,1 do
            l[res[i].handler:lower()] = true
            l[res[i].handler:lower():gsub('%:%/%/$','')] = true
        end
        return l
    end
end

-- 0PARM
for _,v in ipairs({'listpartitions'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v,'partition')

        if not ok then return nil, res end
        return res
    end
end

-- 0PARM
for _,v in ipairs({'config','currentsong','status','stats', 'replay_gain_status','getvol'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self,v)

        if not ok then return nil, res end
        return res
    end
end

-- 1PARM >0 optional
for _,v in ipairs({'play','playid'}) do
    _M[v] = function(self,state)
        local cmd = v
        if state then
            state = slidey(state,0)
            v = v .. ' ' .. state
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd)
        if not ok then return nil, res end
        return ok
    end
end

-- 1PARM > 0
for _,v in ipairs({'crossfade','disableoutput','enableoutput','toggleoutput'}) do
    _M[v] = function(self,state)
        state = slidey(state,0)

        if state == nil then
            return nil, { msg = 'state should be between 0 and infinity' }
        end
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. state)
        if not ok then return nil, res end
        return state
    end
end

-- 1PARM < 0
for _,v in ipairs({'mixrampdelay'}) do
    _M[v] = function(self,state)
        state = slidey(state,0)

        if state == nil then
            state = 'nan'
        end
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. state)
        if not ok then return nil, res end
        return state
    end
end

-- 2PARM , not nil, not nil
for _,v in ipairs({'playlistadd','rename','sendmessage'}) do
    _M[v] = function(self,name,uri)
        if not name or not uri or len(name) <= 0 or len(uri) <= 0 then
            return nil, { msg = 'missing parameters' }
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. texty(name) .. ' ' .. texty(uri))
        if not ok then return nil, res end
        return ok
    end
end

-- 2PARM , not nil, not nil
for _,v in ipairs({'mount'}) do
    _M[v] = function(self,path,uri)
        if not path or not uri or len(path) <= 0 or len(uri) <= 0 then
            return nil, { msg = 'missing parameters' }
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. texty(path) .. ' ' .. texty(uri))
        if not ok then return nil, res end
        return ok
    end
end

-- 1PARM , not nil
for _,v in ipairs({'add','playlistclear','rm','save','password','unmount','subscribe','unsubscribe','partition','newpartition','delpartition','moveoutput'}) do
    _M[v] = function(self,state)

        if state == nil or len(state) <= 0 then
            return nil, { msg = 'missing parameters' }
        end
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. texty(state))
        if not ok then return nil, res end
        return ok
    end
end

-- 1PARM , not nil
for _,v in ipairs({'listplaylist','listplaylistinfo','readcomments'}) do
    _M[v] = function(self,name)
        if name == nil then
            return nil, { msg = 'missing parameter' }
        end
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. texty(name), 'file')
        if not ok then return nil, res end
        return res
    end
end

-- 1PARM , optional
for _,v in ipairs({'listfiles','listall','listallinfo','lsinfo','update','rescan'}) do
    _M[v] = function(self,uri)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        if uri then
            if v == 'rescan' or v == 'update' then
              ok, res = send_and_get(self, v .. ' ' .. texty(uri))
            else
              ok, res = send_and_get(self, v .. ' ' .. texty(uri), 'file','directory','playlist')
            end
        else
            if v == 'rescan' or v == 'update' then
                ok, res = send_and_get(self, v)
            else
                ok, res = send_and_get(self, v, 'file','directory')
            end
        end
        if not ok then return nil, res end
        return res
    end
end

-- 1PARM , not nil , > 0 (optional)
for _,v in ipairs({'addid'}) do
    _M[v] = function(self,param1, param2)

        if param1 == nil then
            return nil, { msg = 'parameter URI required' }
        end

        local cmd = v .. ' ' .. texty(param1)
        if param2 then
            cmd = cmd .. ' ' .. slidey(param2,0)
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd)
        if not ok then return nil, res end
        return ok
    end
end

-- 2 PARM > 0
for _,v in ipairs({'seek','seekid'}) do
    _M[v] = function(self,parm1, parm2)
        parm1 = slidey(parm1,0)
        parm2 = slidey(parm2,0)

        if parm1 == nil or parm2 == nil then
            return nil, { msg = 'two parameters > 0 are required' }
        end
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. parm1 .. ' ' .. parm2)
        if not ok then return nil, res end
        return ok
    end
end

-- 1PARM, -inf < x < inf
for _,v in ipairs({'seekcur'}) do
    _M[v] = function(self,state)
        state = slidey(state)

        if state == nil then
            return nil, { msg = 'state should be between -infinity and infinity' }
        end
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. state)
        if not ok then return nil, res end
        return ok
    end
end

-- 1PARM, -inf < x < 0
for _,v in ipairs({'mixrampdb'}) do
    _M[v] = function(self,state)
        state = slidey(state,nil,0)

        if state == nil then
            return nil, { msg = 'state should be between -infinity and 0' }
        end
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. state)
        if not ok then return nil, res end
        return state
    end
end

-- 1PARM, 0/1
for _,v in ipairs({'consume','random','repeat','random','single','pause'}) do
    _M[v] = function(self,state)
        state = slidey(state,0,1)

        if state == nil then
            return nil, { msg = 'state should be something truthy or falsey'}
        end
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. state)
        if not ok then return nil, res end
        return state
    end
    if v == 'repeat' then
        _M['_repeat'] = _M['repeat']
    end
end

-- 1PARM, 0 < x <= 100
for _,v in ipairs({'setvol'}) do
    _M[v] = function(self, state)
        state = slidey(state,0,100)

        if state == nil then
            return nil, { msg = 'state should be between 0 and 100'}
        end
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. state)
        if not ok then return nil, res end
        return state
    end
end

-- 3PARM, >0, >0 (optional), >0 (optional) [force colon]
for _,v in ipairs({'rangeid'}) do
    _M[v] = function(self, id, start, _end)
        if not id then
            return nil, { msg = 'missing required parameter' }
        end

        id = slidey(id,0)

        local cmd = v .. ' ' .. id .. ' '

        if start then
            start = slidey(start,0)
            cmd = cmd .. start
        end
        cmd = cmd .. ':'

        if _end then
            _end = slidey(_end,0)
            cmd = cmd .. _end
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd)
        if not ok then return nil, res end
        return ok
    end
end

-- 3PARM, >0, >0 (optional), >0 (optional)
for _,v in ipairs({'plchanges','plchangesposid'}) do
    _M[v] = function(self, version, start, _end)
        if not version then
            return nil, { msg = 'missing required parameter' }
        end

        version = slidey(version,0)

        local cmd = v .. ' ' .. version

        if start then
            start = slidey(start,0)
            cmd = cmd .. ' ' .. start
            if _end then
                _end = slidey(start,0)
                cmd = cmd .. ':' .. _end
            end
        end

        local splitparm
        if v == 'plchangesposid' then
            splitparm = 'cpos'
        elseif v == 'plchanges' then
            splitparm = 'file'
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd, splitparm)
        if not ok then return nil, res end
        return res
    end
end

-- 2PARM+, 0 <= x <= 255, >0, >0
for _,v in ipairs({'prio'}) do
    _M[v] = function(self, prio, ...)
        local rs = {...}
        if not prio or #rs <= 0 then
            return nil, { msg = 'missing parameters' }
        end

        prio = slidey(prio,0,255)

        local cmd = v .. ' ' .. prio

        for j=1,#rs,2 do
            cmd = cmd .. ' ' .. slidey(rs[j],0) .. ':' .. slidey(rs[j+1],0)
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd)
        if not ok then return nil, res end
        return ok
    end
end

-- PARM PAIRS
for _,v in ipairs({'find','search'}) do
    _M[v] = function(self, ...)
        local rs = {...}
        if #rs <= 0 then
            return nil, { msg = 'missing parameters' }
        end

        local cmd = v

        for j=1,#rs,2 do
            local a = tonumber(rs[j])
            local b = tonumber(rs[j+1])
            if j+1 == #rs and a and b then
                cmd = cmd .. ' window ' .. a .. ':' .. b
            else
                cmd = cmd .. ' ' .. texty(rs[j]) .. ' ' .. texty(rs[j+1])
            end
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd, 'file')
        if not ok then return nil, res end
        return res
    end
end


for _,v in ipairs({'count'}) do
    _M[v] = function(self, ...)
        local rs = {...}
        if #rs <= 0 then
            return nil, { msg = 'missing parameters' }
        end

        local cmd = v
        local group = false

        for j=1,#rs,2 do
            if not rs[j+1] then
                group = rs[j]
                cmd = cmd .. ' group ' .. texty(rs[j])
            else
                cmd = cmd .. ' ' .. texty(rs[j]) .. ' ' .. texty(rs[j+1])
            end
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        if group ~= false then
            ok, res = send_and_get(self, cmd, group)
        else
            ok, res = send_and_get(self, cmd)
        end
        if not ok then return nil, res end
        return res
    end
end

for _,v in ipairs({'findadd','searchadd'}) do
    _M[v] = function(self, ...)
        local rs = {...}
        if #rs <= 0 then
            return nil, { msg = 'missing parameters' }
        end

        local cmd = v

        for j=1,#rs,2 do
            cmd = cmd .. ' ' .. texty(rs[j]) .. ' ' .. texty(rs[j+1])
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd)
        if not ok then return nil, res end
        return ok
    end
end

for _,v in ipairs({'list'}) do
    _M[v] = function(self, t, ...)
        local rs = {...}
        if not t then
            return nil, { msg = 'missing parameters' }
        end

        t = texty(t)

        local cmd = v .. ' ' .. t

        for j=1,#rs,2 do
            cmd = cmd .. ' ' .. texty(rs[j]) .. ' ' .. texty(rs[j+1])
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd, t:lower())
        if not ok then return nil, res end
        return res
    end
end

for _,v in ipairs({'searchaddpl'}) do
    _M[v] = function(self, t, ...)
        local rs = {...}
        if not t or #rs <= 0 then
            return nil, { msg = 'missing parameters' }
        end

        t = texty(t)

        local cmd = v .. ' ' .. t

        for j=1,#rs,2 do
            cmd = cmd .. ' ' .. texty(rs[j]) .. ' ' .. texty(rs[j+1])
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd, t:lower())
        if not ok then return nil, res end
        return res
    end
end

-- 2PARM+, 0 <= x <= 255, >0, ... >0
for _,v in ipairs({'prioid'}) do
    _M[v] = function(self, prio, ...)
        local ids = {...}
        if not prio or #ids <= 0 then
            return nil, { msg = 'missing parameters' }
        end

        prio = slidey(prio,0,255)

        local cmd = v .. ' ' .. prio

        for _,k in ipairs(ids) do
            cmd = cmd .. ' ' .. k
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd)
        if not ok then return nil, res end
        return ok
    end
end

-- 3PARM, string, >0, >0
for _,v in ipairs({'playlistmove'}) do
    _M[v] = function(self, name, from, to)
        if not name or not from or not to then
            return nil, { msg = 'missing parameters' }
        end
        from = slidey(from,0)
        to = slidey(to,0)

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. texty(name) .. ' ' .. from .. ' ' .. to)
        if not ok then return nil, res end
        return ok
    end
end


-- 3PARM, string, >0 (optional), >0 (optional)
for _,v in ipairs({'load'}) do
    _M[v] = function(self, name, start, _end)
        if not name then
            return nil, { msg = 'missing parameters' }
        end
        local cmd = v .. ' ' .. texty(name)

        if start then
            start = slidey(start,0)
            if not start or not _end then
                return nil, { msg = 'start should be a number' }
            end
             _end = slidey(_end,0)
            cmd = cmd .. ' ' .. start .. ':' .. _end
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd)
        if not ok then return nil, res end
        return ok
    end
end

-- 3PARM, string, string, string
function _M:sticker(...)
    local args = {...}
    local cmd = remove(args,1)

    if not sticker_cmds[cmd] or #args < sticker_cmds[cmd] then
        return nil, { msg = 'missing parameters' }
    end

    cmd = 'sticker ' .. cmd

    for _,v in ipairs(cmd) do
        if v == '>' or v == '<' or v == '=' then
            cmd = cmd .. ' ' .. v
        else
            cmd = cmd .. ' ' .. texty(v)
        end
    end
    local ok, res
    ok, res = self:ready_to_send()
    if not ok then return nil, res end

    ok, res = send_and_get(self, cmd)
    if not ok then return nil, res end
    return res
end

-- 3PARM, >0, string, string
for _,v in ipairs({'addtagid'}) do
    _M[v] = function(self, id, tag, val)
        if not id or not tag or not val then
            return nil, { msg = 'missing parameters' }
        end
        id = slidey(id,0)
        if not id then
            return nil, { msg = 'missing parameters' }
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. id .. ' ' .. texty(tag) .. ' ' .. texty(val))
        if not ok then return nil, res end
        return ok
    end
end

-- 3PARM, >0, >0, >0 (optional)
for _,v in ipairs({'move'}) do
    _M[v] = function(self, start, _end, to)
        if not to then
            to = _end
            _end = nil
        end

        start = slidey(start,0)
        to = slidey(to,0)
        if _end then
            _end = slidey(_end,0)
        end

        if not start or not to then
            return nil, { msg = 'missing required parameters' }
        end

        local cmd = 'move ' .. start
        if _end then
            cmd = cmd .. ':' .. _end
        end
        cmd = cmd .. ' ' .. to

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd)
        if not ok then return nil, res end
        return ok
    end
end

-- 2PARM, > 0 , <> 0
function _M:moveid(from, to)
    if not from or not to then
        return nil, { msg = 'required parameters: from, to' }
    end

    from = slidey(from,0)
    to = slidey(to)

    local ok, res
    ok, res = self:ready_to_send()
    if not ok then return nil, res end

    ok, res = send_and_get(self, 'moveid ' .. from .. ' ' .. to)
    if not ok then return nil, res end
    return ok
end

-- 2PARM, >0, >0 optional
function _M:_delete(start,stop)

    if start then
        start = slidey(start,0)
    else
        return nil, { msg = 'missing required pos/start parameter'}
    end

    if stop then
        stop = slidey(stop,0)
    end

    local cmd = 'delete'

    if start then
        cmd = cmd .. ' ' .. start
        if stop then
            cmd = cmd .. ':'..stop
        end
    end

    local ok, res
    ok, res = self:ready_to_send()
    if not ok then return nil, res end

    ok, res = send_and_get(self, cmd)
    if not ok then return nil, res end
    return ok
end

_M['delete'] = _M._delete

-- 2PARM, >0, string (optional)
for _,v in ipairs({'cleartagid'}) do
    _M[v] = function(self, id, tag)

        if not id or not tag then
            return nil, { msg = 'missing required parameters' }
        end

        id = slidey(id,0)
        if not id then
            return nil, { msg = 'missing required parameters' }
        end

        local cmd = v .. ' ' .. id
        if tag then
            cmd = cmd .. ' ' .. texty(tag)
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd)
        if not ok then return nil, res end
        return ok
    end
end


-- 2PARM, >0, >0
for _,v in ipairs({'swap','swapid'}) do
    _M[v] = function(self, pos1, pos2)

        if not pos1 or pos2 then
            return nil, { msg = 'missing required parameters' }
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. pos1 .. ' ' .. pos2)
        if not ok then return nil, res end
        return ok
    end
end

-- 1PARM, > 0 optional
function _M:playlistid(id)
    if id then
        id = slidey(id,0)
    end

    local cmd = 'playlistid'

    if id then
        cmd = cmd .. ' ' .. id
    end

    local ok, res
    ok, res = self:ready_to_send()
    if not ok then return nil, res end

    ok, res = send_and_get(self, cmd, 'file')
    if not ok then return nil, res end
    if id then
        return res[1]
    end
    return res
end

-- 2PARM, string, >0
for _,v in ipairs({'playlistdelete'}) do
    _M[v] = function(self, name, pos)
        if not name or not pos then
            return nil, { msg = 'missing name or position parameter' }
        end

        pos = slidey(pos,0)
        if not pos then
            return nil, { msg = 'missing name or position parameter' }
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. texty(name) .. ' ' .. pos)
        if not ok then return nil, res end
        return ok
    end
end

-- 2PARM, string, >0, returns data
for _,v in ipairs({'albumart','readpicture'}) do
    _M[v] = function(self, uri, off)
        if not uri then
            return nil, { msg = 'missing name parameter' }
        end

        if not off then
            return nil, { msg = 'missing offset parameter' }
        end

        off = slidey(off,0)
        if not off then
            return nil, { msg = 'offset parameter not number > 0' }
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' .. texty(uri) .. ' ' .. off)
        if not ok then return nil, res end
        return res
    end
end


-- 2PARM, string, string
for _,v in ipairs({'playlistfind','playlistsearch'}) do
    _M[v] = function(self, tag, needle)
        if not tag or not needle then
            return nil, { msg = 'missing tag and needle parameters' }
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, v .. ' ' ..texty(tag) .. ' ' .. texty(needle), 'file')
        if not ok then return nil, res end
        return res
    end
end

-- 2PARM, optional > 0 , optional > 0
for _,v in ipairs({'shuffle'}) do
    _M[v] = function(self, start, _end)
        local cmd = v
        if start then
            start = slidey(start,0)
            if not _end then
                return nil, { err = 'start given without end' }
            end
            _end = slidey(_end,0)
            cmd = cmd .. ' ' .. start ..':' .. _end
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd)
        if not ok then return nil, res end
        return ok
    end
end

-- 2PARM, optional > 0 , optional > 0
for _,v in ipairs({'playlistinfo'}) do
    _M[v] = function(self, start, _end)
        local cmd = v
        if start then
            start = slidey(start,0)
            if _end then
              _end = slidey(_end,0)
              cmd = cmd .. ' ' .. start ..':' .. _end
            else
              cmd = cmd .. ' ' .. start
            end
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd, 'file')
        if not ok then return nil, res end
        return res
    end
end

-- 1PARM, fromlist
function _M:replay_gain_mode(mode)
    if type(mode) == 'nil' then
        mode = 'off'
    end

    if not replay_gain_modes[mode] then
        return nil, { msg = 'mode should be off,track,album,auto' }
    end
    local ok, res
    ok, res = self:ready_to_send()
    if not ok then return nil, res end

    ok, res = send_and_get(self, 'replay_gain_mode ' .. mode)
    if not ok then return nil, res end
    return mode
end

-- 1PARM, string
for _,v in ipairs({'getfingerprint'}) do
    _M[v] = function(self, uri)
        local cmd = v
        if not uri then return nil, { msg = 'missing uri parameter' } end
        cmd = cmd .. ' ' .. texty(uri)

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self, cmd)
        if not ok then return nil, res end
        return res
    end
end

function _M:close()
    if self.conn then
        self.conn:close()
    end
end

return _M
