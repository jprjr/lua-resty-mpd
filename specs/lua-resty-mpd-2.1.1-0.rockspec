package = "lua-resty-mpd"
version = "2.1.1-0"
source = {
    url = "https://github.com/jprjr/lua-resty-mpd/archive/2.1.1.tar.gz",
    file = "lua-resty-mpd-2.1.1.tar.gz"
}
description = {
    summary = "An OpenResty/Luasocket MPD client library",
    homepage = "https://github.com/jprjr/lua-resty-mpd",
    license = "MIT"
}
build = {
    type = "builtin",
    modules = {
        ["resty.mpd"] = "lib/resty/mpd.lua"
    }
}
dependencies = {
    "lua >= 5.1",
}
