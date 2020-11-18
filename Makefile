.PHONY: lib/resty/mpd.lua

SRCDIR = src/resty
SRCS = \
	$(SRCDIR)/mpd/stack.lua \
	$(SRCDIR)/mpd/backend/cqueues.lua \
	$(SRCDIR)/mpd/backend/luasocket.lua \
	$(SRCDIR)/mpd/backend/nginx.lua \
	$(SRCDIR)/mpd/backend.lua \
	$(SRCDIR)/mpd/commands.lua \
	$(SRCDIR)/mpd.lua

lib/resty/mpd.lua: $(SRCS)
	lua combine.lua $@ $(SRCS)
