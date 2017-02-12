
## Instantiating a client

### `client = mpd.new()`

Returns a new MPD client object

### `ok, err = client:connect(url)`

Connects to MPD, supports tcp and unix socket connections.

The URL should be in one of two formats:

* `tcp://host:port`
* `unix:/path/to/socket`

### `ok, err = client:close()`

## Implemented Protocol Functions

For details on each of these functions, see the MPD proto docs:
[https://www.musicpd.org/doc/protocol/command_reference.html](https://www.musicpd.org/doc/protocol/command_reference.html)

### `ok, err = client:clearerror()`

Clears any current error message

### `res, err = client:currentsong()`

Returns a table about the current song. In the
case of an error, returns `nil` and an object
describing the error.


### `event, err = client:idle(...)`

Waits until MPD emits a noteworthy change. You can specify a list of
events you're interested in, or leave blank for all events.

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
