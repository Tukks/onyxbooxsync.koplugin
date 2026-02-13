local _ = require("gettext")
return {
    name = "onyx_sync",
    fullname = _("Onyx Progress Sync"),
    description = _("Syncs progress with Onyx library."),
    is_supported = function()
        return require("device"):isAndroid()
    end,
}
