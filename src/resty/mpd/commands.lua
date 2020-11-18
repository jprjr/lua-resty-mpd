-- implements MPD commands
local stack_lib = require'resty.mpd.stack'
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
    if not self.socket then
      return nil,'socket:not connected'
    end
    local cond = self._backend.condition.new()

    self.stack:push(cond)
    if self.stack:front() ~= cond then
      self.socket:signal()
      cond:wait()
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
    return f(table.unpack(newargs))
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
    return send_and_read(self,cmd,table.unpack(args))
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
  if not self.socket then
    return nil, 'socket:not connected'
  end

  local cond = self._backend.condition.new()
  local response = {}
  local line, err
  local errnum, msg, _

  self.stack:push(cond)
  if self.stack:front() ~= cond then
    cond:wait()
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

      return send_and_read(table.unpack(args))
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

    return send_and_read(table.unpack(args))
  end)
end

-- @return table
for _,k in ipairs({'count'}) do
  commands[k] = cond_wrapper(function(self,...)
    local rs = {...}
    local args = { self, k }
    build_filter_args(args,rs)

    return send_and_read(table.unpack(args))
  end)
end

-- @return boolean
for _,k in ipairs({'findadd','searchadd'}) do
  commands[k] = cond_wrapper(function(self,...)
    local rs = {...}
    local args = { self, k }
    build_filter_args(args,rs)

    local _,err = send_and_read(table.unpack(args))
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

    local _,err = send_and_read(table.unpack(args))
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

    return send_and_read(table.unpack(args))
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

      local _,err = send_and_read(table.unpack(args))
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
      if eq and val then
        val = mandatory_string.f(val)
      end
      local res, err = send_and_read(self,'sticker','find',typ,uri,name,eq,val,{'file'})
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
