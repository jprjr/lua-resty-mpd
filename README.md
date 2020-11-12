# lua-resty-mpd

Despite the name "lua-resty-mpd" this will work on regular Lua as well!

This is a library for interacting with [Music Player Daemon](https://www.musicpd.org/),
over TCP sockets or Unix sockets.

It works with [OpenResty's cosockets](https://github.com/openresty/lua-nginx-module#ngxsockettcp),
[cqueues sockets](https://github.com/wahern/cqueues), and
[LuaSocket](http://w3.impa.br/~diego/software/luasocket/). It will try to auto-detect the most
appropriate library to use, you can also specify if you'd like to use a particular library.

## Example Usage

```lua
local mpd = require'resty.mpd'
local client = mpd.new()
client:connect('tcp://127.0.0.1:6600')

-- loop until we've read 5 events
local events = 5

while events > 0 do
  local res, err = client:idle()
  if err then
      if err.msg == 'timeout' then
          -- cancel current idle for next loop
          local noidle_ok, noidle_err = client:noidle()
          if noidle_err then
              print('Error: ' .. noidle_err.msg)
              os.exit(1)
          end
      else
          print('Error: ' .. err)
          os.exit(1)
      end
  else
      for _,event in ipairs(res) do
          print('Event: ' .. event)
          events = events - 1
          -- do something based on the event
       end
  end
end
```

## Global options

### `libname = mpd.global_socket_lib([name])`

Returns the socket library being used by all new clients, `name` is an optional
parameter to choose a particular library. Valid `name` values are:

* `ngx` - nginx cosockets.
* `cqueues` - cqueues.
* `socket` - luasocket.

## Instantiating a client

### `client = mpd.new(opts)`

Returns a new MPD client object. Opts is an (optional) table
of parameters for the client. Accepted parameters:

* `timeout_continue` - boolean. If true, reading operations will
continue attempting to read even during a timeout. If you have
a client that loops around calls to `idle` you may want to
consider enabling this.

### `libname = client:socket_lib([name])`

Returns the socket library being used by the client, `name` is an optional
parameter to choose a particular library. Valid `name` values are:

* `ngx` - nginx cosockets.
* `cqueues` - cqueues.
* `socket` - luasocket.

### `ok, err = client:connect(url)`

Connects to MPD, supports tcp and unix socket connections.

The URL should be in one of two formats:

* `tcp://host:port`
* `unix:/path/to/socket`
* `host:port`
* `host` (implied port 6600)
* `tcp://host` (implied port 6600)
* `path/to/socket` (does not have to be absolute)

### `ok, err = client:close()`

## Changelog

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

## Implemented Protocol Functions

For details on each of these functions, see the MPD proto docs:
[https://www.musicpd.org/doc/protocol/command_reference.html](https://www.musicpd.org/doc/protocol/command_reference.html)

### `ok, err = client:clearerror()`

Clears any current error message

### `res, err = client:currentsong()`

Returns a table about the current song. In the
case of an error, returns `nil` and an object
describing the error.


### `events, err = client:idle(...)`

Waits until MPD emits a noteworthy change. You can specify a list of
events you're interested in, or leave blank for all events. Returns
an array of events.

May return zero events, in the case of canceling an idle via `client:noidle()`

The events:

* database
* update
* stored_playlist
* playlist
* player
* mixer
* output
* options
* sticker
* subscription
* message

### `res, err = client:status()`

### `res, err = client:stats()`

### `boolean, err = client:consume(boolean)`

### `duration, err = client:crossfade(duration)`

### `db, err = client:mixrampdb(db)`

### `duration, err = client:mixrampdelay(duration)`

### `boolean, err = client:random(boolean)`

### `boolean, err = client:_repeat(boolean)`

### `volume, err = client:setvol(volume)`

### `boolean, err = client:single(boolean)`

### `mode, err = client:replay_gain_mode(mode)`

### `status, err = client:replay_gain_status()`

### `ok, err = client:_next()`

### `boolean, err = client:pause(boolean)`

### `ok, err = client:play([pos])`

### `ok, err = client:playid([id])`

### `ok, err = client:previous()`

### `ok, err = client:seek(songpos, time)`

### `ok, err = client:seekid(songid, time)`

### `ok, err = client:seekcur(time)`

### `ok, err = client:stop()`

### `ok, err = client:add(uri)`

### `ok, err = client:addid(uri,position)`

### `ok, err = client:clear()`

### `ok, err = client:_delete(pos, [end])`

### `ok, err = client:deleteid(songid)`

### `ok, err = client:move(start, end | to, [to])`

### `ok, err = client:moveid(from, to)`

### `res, err = client:playlistfind(tag, needle)`

### `res, err = client:playlistid(id)`

### `res, err = client:playlistinfo([pos],[end])`

### `res, err = client:playlistsearch(tag, needle)`

### `res, err = client:plchanges(version, [start], [end])`

### `ok, err = client:prio(priority, [start], [end], ...)`

### `ok, err = client:prioid(priority, id, ... id+)`

### `ok, err = client:rangeid(id, [start], [end])`

### `ok, err = client:shuffle([start], [end])`

### `ok, err = client:swap(song1, song2)`

### `ok, err = client:swapid(song1, song2)`

### `ok, err = client:addtagid(id, tag, value)`

### `ok, err = client:cleartagid(id, [tag])`

### `res, err = client:listplaylist(name)`

### `res, err = client:listplaylistinfo(name)`

### `res, err = client:listplaylists()`

### `ok, err = client:load(name, [start], [end])`

### `ok, err = client:playlistadd(name, uri)`

### `ok, err = client:playlistclear(name)`

### `ok, err = client:playlistdelete(name, pos)`

### `ok, err = client:playlistmove(name, from, to)`

### `ok, err = client:rename(name, newname)`

### `ok, err = client:rm(name)`

### `ok, err = client:save(name)`

### `ok, err = client:password(password)`

### `ok, err = client:ping()`

### `ok, err = client:kill()`

### `res, err = client:count(...)`

### `res, err = client:find(...)`

### `res, err = client:findadd(...)`

### `res, err = client:list(type,...)`

### `res, err = client:listfiles([uri])`

### `res, err = client:lsinfo([uri])`

### `res, err = client:readcomments([uri])`

### `res, err = client:search(...)`

### `res, err = client:searchadd(...)`

### `res, err = client:searchaddpl(playlist, ...)`

### `res, err = client:update([uri])`

### `res, err = client:rescan([uri])`

### `res, err = client:sticker(...)`

### `id, err = client:disableoutput(id)`

### `id, err = client:enableoutput(id)`

### `id, err = client:toggleoutput(id)`

### `res, err = client:outputs()`

### `res, err = client:config()`

### `res, err = client:commands()`

### `res, err = client:notcommands()`

### `res, err = client:tagtypes()`

### `res, err = client:urlhandlers()`

### `res, err = client:decoders()`

### `ok, err = client:mount(path,uri)`

### `ok, err = client:unmount(path)`

### `res, err = client:listmounts()`

### `res, err = client:listneighbors()`

### `ok, err = client:subscribe(name)`

### `ok, err = client:unsubscribe(name)`

### `res, err = client:channels()`

### `res, err = client:readmessages()`

### `ok, err = client:sendmessage(name, message)`

## LICENSE

MIT license (see `LICENSE`)
