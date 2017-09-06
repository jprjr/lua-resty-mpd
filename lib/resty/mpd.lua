-- luacheck: globals ngx
local tcp
local unix
local type = type
local huge = math.huge
local tonumber = tonumber
local match = string.match
local sub = string.sub
local find = string.find
local setmetatable = setmetatable
local remove = table.remove
local ipairs = ipairs
local len = string.len

if ngx then
    tcp = ngx.socket.tcp
    unix = tcp
else
    tcp = require'socket'.tcp
    unix = require'socket.unix'
end

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

local function get_lines(conn, ...)
    local ok
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
        local data, err = conn:receive('*l')

        if err then
            return nil, { msg = err }
        end

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
        end
    end
    return ok, res
end

local function send_and_get(conn, cmd, ...)
    local ok, res
    ok, res = conn:send(cmd .. '\n')

    if not ok then
        return nil, { msg = res }
    end

    ok, res = get_lines(conn, ...)
    if not ok then
        return nil, res
    end
    return true, res
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
    _VERSION = '1.0.4',
}
_M.__index = _M

_M.new = function()
    local self = {
        idling = false,
    }

    setmetatable(self,_M)
    return self
end

function _M:connect(url)
    local proto = match(url,'^(%a+):')

    if proto == 'tcp' then
        local host, port = match(url,'tcp://([^:]+):(%d+)')

        self.proto = 'tcp'
        self.host = host
        self.port = port
    elseif proto == 'unix' then
        local path = match(url,'unix:(.+)')

        self.proto = 'unix'
        self.path = path
    end

    return self:connected()
end

function _M:connected()
    if self.conn then
        return true
    end
    local data,_,err,p

    if self.proto then
        if self.proto == 'tcp' then
            self.conn, err = tcp()
            if err then return nil, { msg = err } end

            _,err = self.conn:connect(self.host,self.port)
            if err then
                self.conn = nil
                return nil, { msg = err }
            end
        elseif self.proto == 'unix' then
            self.conn, err = unix()
            if err then return nil, { msg = err } end

            if ngx then
                _,err = self.conn:connect('unix:'..self.path)
            else
                _,err = self.conn:connect(self.path)
            end

            if err then
                self.conn = nil
                return nil, { msg = err }
            end
        elseif self.proto then
            return nil, { msg = self.proto .. ': unsupported protocol' }
        else
            return nil, { msg = 'protocol not specified' }
        end
    else
        return nil,'not connected'
    end

    self.conn:settimeout(90)

    data, err, p = self.conn:receive('*l')
    if err then
        self.conn = nil
        return nil, { msg = err }
    end

    self.conn:settimeout(nil)

    if p then
        data = data .. p
    end

    if match(data,'^OK MPD') then
        return true
    end
    self.conn = nil

    return nil, { msg = 'Connected to something but it\'s not MPD' }
end

function _M:ready_to_send()
    local ok, res
    ok, res = self:connected()
    if not ok then return nil, res end

    if self.idling then
        return nil, { msg = 'Waiting on idle command' }
    end

    return true
end

function _M:idle(...)
    local ok, res
    ok, res = self:connected()
    if not ok then return nil, res end

    local subs = {...}
    local s = ''
    for _,v in ipairs(subs) do
        s = s .. ' ' .. v
    end

    self.idling = true
    ok, res = send_and_get(self.conn,'idle'..s)
    self.idling = false

    if not ok then return nil, res end
    if res.changed then
        return res.changed
    end
    return 'interrupted'
end

function _M:noidle()
    local ok, res
    ok, res = self:connected()
    if not ok then return nil, res end

    if self.idling then
        self.conn:send('noidle\n')
    end
    return nil
end

-- 0PARM
for _,v in ipairs({'clearerror','next','previous','stop','clear','ping','kill'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self.conn,v)

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

        ok, res = send_and_get(self.conn,v,'outputid')

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

        ok, res = send_and_get(self.conn,v,'plugin')

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

        ok, res = send_and_get(self.conn,v,'playlist')

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

        ok, res = send_and_get(self.conn,v,'mount')

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

        ok, res = send_and_get(self.conn,v,'neighbor')

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

        ok, res = send_and_get(self.conn,v,'channel')

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

        ok, res = send_and_get(self.conn,v,'command')

        if not ok then return nil, res end
        local l = {}
        for i=1,#res,1 do
            l[res[i].command] = true
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

        ok, res = send_and_get(self.conn,v,'tagtype')

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

        ok, res = send_and_get(self.conn,v,'handler')

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
for _,v in ipairs({'config','currentsong','status','stats', 'replay_gain_status'}) do
    _M[v] = function(self)
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self.conn,v)

        if not ok then return nil, res end
        return res
    end
end

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

        ok, res = send_and_get(self.conn, cmd)
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

        ok, res = send_and_get(self.conn, v .. ' ' .. state)
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

        ok, res = send_and_get(self.conn, v .. ' ' .. state)
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

        ok, res = send_and_get(self.conn, v .. ' "' .. name .. '" "' .. uri .. '"')
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

        ok, res = send_and_get(self.conn, v .. ' "' .. path .. '" "' .. uri .. '"')
        if not ok then return nil, res end
        return ok
    end
end

-- 1PARM , not nil
for _,v in ipairs({'add','playlistclear','rm','save','password','unmount','subscribe','unsubscribe'}) do
    _M[v] = function(self,state)

        if state == nil or len(state) <= 0 then
            return nil, { msg = 'missing parameters' }
        end
        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self.conn, v .. ' "' .. state .. '"')
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

        ok, res = send_and_get(self.conn, v .. ' "' .. name .. '"', 'file')
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
              ok, res = send_and_get(self.conn, v .. ' "' .. uri .. '"')
            else
              ok, res = send_and_get(self.conn, v .. ' "' .. uri .. '"', 'file','directory')
            end
        else
            if v == 'rescan' or v == 'update' then
                ok, res = send_and_get(self.conn, v)
            else
                ok, res = send_and_get(self.conn, v, 'file','directory')
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

        local cmd = v .. ' ' .. param1
        if param2 then
            cmd = cmd .. ' ' slidey(param2,0)
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self.conn, cmd)
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

        ok, res = send_and_get(self.conn, v .. ' ' .. parm1 .. ' ' .. parm2)
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

        ok, res = send_and_get(self.conn, v .. ' ' .. state)
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

        ok, res = send_and_get(self.conn, v .. ' ' .. state)
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

        ok, res = send_and_get(self.conn, v .. ' ' .. state)
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

        ok, res = send_and_get(self.conn, v .. ' ' .. state)
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

        ok, res = send_and_get(self.conn, cmd)
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

        ok, res = send_and_get(self.conn, cmd, splitparm)
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

        ok, res = send_and_get(self.conn, cmd)
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
                cmd = cmd .. ' "' .. rs[j] .. '" "' .. rs[j+1] .. '"'
            end
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self.conn, cmd, 'file')
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
                cmd = cmd .. ' group "' .. rs[j] .. '"'
            else
                cmd = cmd .. ' "' .. rs[j] .. '" "' .. rs[j+1] .. '"'
            end
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        if group ~= false then
            ok, res = send_and_get(self.conn, cmd, group)
        else
            ok, res = send_and_get(self.conn, cmd)
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
            cmd = cmd .. ' "' .. rs[j] .. '" "' .. rs[j+1] .. '"'
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self.conn, cmd)
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

        if find(t, ' ') then
            t = '"' .. t .. '"'
        end

        local cmd = v .. ' ' .. t

        for j=1,#rs,2 do
            cmd = cmd .. ' "' .. rs[j] .. '" "' .. rs[j+1] .. '"'
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self.conn, cmd, t:lower())
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

        if find(t, ' ') then
            t = '"' .. t .. '"'
        end

        local cmd = v .. ' ' .. t

        for j=1,#rs,2 do
            cmd = cmd .. ' "' .. rs[j] .. '" "' .. rs[j+1] .. '"'
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self.conn, cmd, t:lower())
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

        ok, res = send_and_get(self.conn, cmd)
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

        ok, res = send_and_get(self.conn, v .. ' "' .. name .. '" ' .. from .. ' ' .. to)
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
        local cmd = v .. ' ' .. name

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

        ok, res = send_and_get(self.conn, cmd)
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
            cmd = cmd .. ' "' .. v ..'"'
        end
    end
    local ok, res
    ok, res = self:ready_to_send()
    if not ok then return nil, res end

    ok, res = send_and_get(self.conn, cmd)
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

        ok, res = send_and_get(self.conn, v .. ' ' .. id .. ' ' .. tag .. ' ' .. val)
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

        ok, res = send_and_get(self.conn, cmd)
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

    ok, res = send_and_get(self.conn, 'moveid ' .. from .. ' ' .. to)
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

    ok, res = send_and_get(self.conn, cmd)
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
            cmd = cmd .. ' "' .. tag .. '"'
        end

        local ok, res
        ok, res = self:ready_to_send()
        if not ok then return nil, res end

        ok, res = send_and_get(self.conn, cmd)
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

        ok, res = send_and_get(self.conn, v .. ' ' .. pos1 .. ' ' .. pos2)
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

    ok, res = send_and_get(self.conn, cmd, 'file')
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

        ok, res = send_and_get(self.conn, v .. ' "' .. name .. '" ' .. pos)
        if not ok then return nil, res end
        return ok
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

        ok, res = send_and_get(self.conn, v .. ' "' .. tag .. '" "' .. needle .. '"', 'file')
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

        ok, res = send_and_get(self.conn, cmd)
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

        ok, res = send_and_get(self.conn, cmd, 'file')
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

    ok, res = send_and_get(self.conn, 'replay_gain_mode ' .. mode)
    if not ok then return nil, res end
    return mode
end

function _M:close()
    if self.conn then
        self.conn:close()
    end
end

return _M
