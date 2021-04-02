# lua-resty-mpd

Despite the name "lua-resty-mpd" this will work on regular Lua as well!

This is a library for interacting with [Music Player Daemon](https://www.musicpd.org/),
over TCP sockets or Unix sockets.

It works with [OpenResty's cosockets](https://github.com/openresty/lua-nginx-module#ngxsockettcp),
[cqueues sockets](https://github.com/wahern/cqueues), and
[LuaSocket](http://w3.impa.br/~diego/software/luasocket/). It will try to auto-detect the most
appropriate library to use, you can also specify if you'd like to use a particular library.

You can use this library synchronously or asynchronously in nginx and cqueues,
on Luasocket, you can only perform synchronous operations.

## Installation

You can use `luarocks`:

`luarocks install lua-resty-mpd`

Or OPM:

`opm get jprjr/lua-resty-mpd`

Or grab the amalgamation file from this repo (under `lib/`), it's all
the sources of this module combined into a single file.

Since this can use multiple socket libraries, I don't list them as dependencies,
you'll need to install luasocket or cqueues on your own. No other external
dependencies are required.

## Example Usage

Here's an script that just loops over calls to idle().

```lua
local mpd = require'resty.mpd'
local client = mpd()
client:settimeout(1000) -- set a low timeout just to demo idle timing out.
client:connect('tcp://127.0.0.1:6600')

-- loop until we've read 5 events
local events = 5

while events > 0 do
  local res, err = client:idle()
  if err and err ~= 'socket:timeout' then
    print('Error: ' .. err)
    os.exit(1)
  end
  for _,event in ipairs(res) do
    print('Event: ' .. event)
    events = events - 1
    -- do something based on the event
  end
end
client:close()

```

Here's an example of asynchronous usage under openresty, using nginx threads:

```lua
local mpd = require'resty.mpd'

local client = mpd()

-- If MPD isn't running, bail

assert(client:connect('127.0.0.1'))

-- Holds references to our threads

local threads = {}

-- Each entry is the command to run and a
-- key that should be in the response.
--
-- We do this to verify that each thread is
-- getting the correct response (if we called
-- "status" but didn't get the "state" key, then
-- something went really, really wong.

local commands = {
  { 'status', 'state' },
  { 'stats',  'uptime' },
  { 'replay_gain_status','replay_gain_mode'},
}

-- Start a loop around client:idle().
-- This will write out any idle events (should be zero
-- unless you happen to do something to MPD in the
-- 2 seconds that this script runs for), and
-- exits if it receives an error.
table.insert(threads,ngx.thread.spawn(function()
  while true do
    print('calling client:idle()')
    local events, err = client:idle()
    if err and err ~= 'socket:timeout' then
      print(string.format('client:idle() error %s',err))
      return false, err
    end

    print(string.format('client:idle() returned %d events',#events))
    for _,event in ipairs(events) do
      print(string.format('client:idle() event: %s',event))
    end
  end
end))

-- Start threads to send individual commands.
-- These will interrupt the idle call and force
-- idle to return zero events.
for i=1,#commands do
  table.insert(threads,ngx.thread.spawn(function()
    local func = commands[i][1]
    local key  = commands[i][2]
    print(string.format('calling client:%s()',func))
    local res, err = client[func](client)
    if err then
      print(string.format('client:%s() error: %s',func,err))
      return false, err
    end
    if not res[key] then
      err = string.format('missing key %s',key)
      print(string.format('client:%s() error: %s',func,err))
      return false,err
    end
    print(string.format('client:%s() success',func))
    return true
  end))
end

-- Shut everything down after 2 seconds.
table.insert(threads,ngx.thread.spawn(function()
  ngx.sleep(2)
  print('calling client:close()')
  local ok, err = client:close()
  if err then
    print(string.format('client:close() err: ' .. err))
  end
end))

-- Rejoin all the threads
for i=1,#threads do
  local ok, err = ngx.thread.wait(threads[i])
  if not ok then error(err) end
end

```

This is basically the same as the nginx example but with cqueues.
No comments in this one since it's virtually identical.

```lua
local cqueues = require'cqueues'
local mpd = require'resty.mpd'
local loop = cqueues.new()

local client = mpd.new()
assert(client:connect('127.0.0.1'))

local commands = {
  { 'status', 'state' },
  { 'stats',  'uptime' },
  { 'replay_gain_status','replay_gain_mode'},
}

loop:wrap(function()
  while true do
    print('calling client:idle()')
    local events, err = client:idle()
    if err and err ~= 'socket:timeout' then
      print(string.format('client:idle() error %s',err))
      return false, err
    end

    print(string.format('client:idle() returned %d events',#events))
    for _,event in ipairs(events) do
      print(string.format('client:idle() event: %s',event))
    end
  end
end)

for i=1,#commands do
  loop:wrap((function()
    local func = commands[i][1]
    local key  = commands[i][2]
    print(string.format('calling client:%s()',func))
    local res, err = client[func](client)
    if err then
      print(string.format('client:%s() error: %s',func,err))
      return false, err
    end

    if not res[key] then
      err = string.format('missing key %s',key)
      print(string.format('client:%s() error: %s',func,err))
      return false,err
    end
    print(string.format('client:%s() success',func))
    return true
  end))
end

loop:wrap(function()
  cqueues.sleep(2)
  print('calling client:close()')
  local ok, err = client:close()
  if err then
    print(string.format('client:close() err: ' .. err))
  end
end)

assert(loop:loop())
```

## Global options

### `lib = mpd:backend([name])`

Returns the socket/condition variable library being used by all
new clients, `name` is an optional parameter to choose a particular
library. Valid `name` values are:

* `nginx` - nginx cosockets.
* `cqueues` - cqueues.
* `luasocket` - luasocket.

If a library isn't available, it will instead return the default
library.

The returned value is the library in use, you can check the `.name`
field to see which specific library it is. Example:

```lua
lib = mpd:backend('luasocket')
assert(lib.name == 'luasocket')
```

## Instantiating a client

### `client = mpd()`

Creates a new client instance.

You can also call this as `mpd.new()`

### `lib = client:backend([name])`

Returns the socket library being used by this particular client,
it behaves the same as `mpd:backend` above.

* `nginx` - nginx cosockets.
* `cqueues` - cqueues.
* `luasocket` - luasocket.

If your client has already called `connect`, you're unable to
change the library, you'll need to call `close`, change the
library, then reconnect.

### `ok, err = client:connect(url)`

Connects to MPD, supports tcp and unix socket connections.

The URL should be in one of two formats:

* `tcp://host:port`
* `unix:/path/to/socket`
* `host:port`
* `host` (implied port 6600)
* `tcp://host` (implied port 6600)
* `path/to/socket` (does not have to be absolute)

You can also call this as `client:connect(host,port)` for TCP connections.

### `ok, err = client:settimeout(ms)`

Sets the socket timeout in milliseconds, or use `nil` to
represent no timeout.

By default, clients have no timeout and will block forever,
please note this includes the nginx/OpenResty backend.

(Technically OpenResty doesn't support having no timeout, so it's set
to the maximum value).

### `ok, err = client:close()`

Closes the connection, forces any pending operations to error out.

## Implemented Protocol Functions and error handling

I used to list every implemented function, instead I recommend
just looking up the MPD protocol documentation:
[https://www.musicpd.org/doc/protocol/command_reference.html](https://www.musicpd.org/doc/protocol/command_reference.html)

Commands return either a table of results or a boolean as the first
return value, and an error (if any) as the second.

If the error is from MPD, the message will begin with the string
`mpd:` followed by the error number, and the error message in parenthesis,
example:

`mpd:50(No such file)`

Any socket-related error messaged will begin with `socket:`, these
are non-recoverable (you should disconnect/quit/etc). The exception
to this is `idle`, see below.

### `client:idle()`

When `idle` times out, it automatically sends `noidle` to cancel
the current `idle` request. Otherwise, your scheduler (nginx threads,
cqueues, etc) *could* potentially send a command before you
call `noidle` from your app, since when `idle` ends the next queued
command gets called.

What this means is `idle` will always return a list of events,
which may be an empty table in the case of a timeout, you should
check the value of `err` to see if there was a timeout (if `err`
is `nil`, then the `idle` was canceled intentionally via another
command being queued).

### General usage

Generally-speaking you just send values like listed in the MPD protocol documentation.
For example, the MPD protocol documentation has the following prototype for the `list` command:

`list {TYPE} {FILTER} [group {GROUPTYPE}]`

This would translate to:

```lua
response, err = client:list(type,filter,'group',grouptype)
```

For functions that take ranges, you use separate parameters for each part of the range. For
example, using the `find` command, which lets you specify a `window` range:

`find {FILTER} [sort {TYPE}] [window {START:END}]`

This becomes

```lua
response, err = client:find(filter,'sort',type,'window',start,end)
```

For optional parameters, just leave them out. If you wanted to call
`find` with just a filter and window:


```lua
response, err = client:find(filter,'window',start,end)
```

Or for just a filter:

```lua
response, err = client:find(filter)
```

Groups (and nested groups) are fully supported for commands that use them,
groups will return an array-like table instead of an object, so as an
example:

```lua
local res, err = client:list('title','group','album','group','albumartist')
```

`res` will be an array-like table, each entry will contain a `title`, `album`, and
`albumartist` key.

## Changelog

### Version 5.1.0

Adds the new `binarylimit` protocol command.

### Version 5.0.1

Minor bugfix, return a socket error if not connected.

### Version 5.0.0

Complete rewrite, client commands (list, play, etc) should be
compatible with older versions, but functions for choosing
backend libraries are not.

This was rewritten with asynchronous operations in mind, the
new version can auto-call `noidle` as needed without any
hacks like in version 3.

### Version 4.0.0

Reverts the automatic noidle via condvar/semaphore, it
turned out this wasn't a good idea.

Retains previous enhancements of handling binary responses
and being compatible up to MPD 0.22.0.

### Version 3.0.1

Bug fix with condition variables/semaphores, seems to
be way more reliable now at calling noidle.

### Version 3.0.0

Major version bump.

Version 3.0.0 tries to detect if a command is sent
while waiting on an `IDLE` command to finish,
and automatically calls `noidle`, it does this through
nginx semaphores and cqueues condition variables.

This new behavior is not supported on LuaSocket, you'll
need to call `noidle` on your own.

Also handles binary responses and *should* handle all
MPD protocol functions as of MPD 0.22.0.

### Version 2.2.0

New feature, now supports cqueues socket library.

Library is auto-detected with the following priority:

1. nginx cosockets
2. cqueues
3. luasocket

This can be overridden at a global level, or per-client.

### Version 2.1.1

Bugfix: escape quotes/backslashes when sending.

### Version 2.1.0

New feature: `new` takes an optional table, see documentation.

### Version 2.0.2

Fixes potential race condition in `noidle`.

Uses correct socket timeout scale (seconds with luasocket, milliseconds in nginx).

### Version 2.0.1

Fixes timed out operations.

### Version 2.0.0

#### Breaking Changes

**`idle` change**

In previous versions, calling `idle` would return a string, with
a special string ("interrupted") in the case of the idle being
canceled with `noidle`. In MPD, a call to `idle` can return multiple
events.

`idle` now returns an array of events, with an empty array used to
represent `idle` being canceled.

**`commands` and `notcommands` change**

Previous versions returned a table with each command being a key set
to `true`.

`commands` and `notcommands` now returns an array of commands.

#### Non-Breaking Changes

Previous versions required the URL to match the formats:

* `tcp://host:port`
* `unix:/path/to/socket`

The URL can additionally use the formats:

* `host:port`
* `host` (implied port 6600)
* `tcp://host` (implied port 6600)
* `path/to/socket` (does not have to be absolute)

I still recommend the `tcp://` or `unix:` prefixes to be explicit

## LICENSE

MIT license (see `LICENSE`)
