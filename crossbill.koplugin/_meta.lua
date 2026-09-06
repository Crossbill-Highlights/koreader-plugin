local _ = require("gettext")
return {
	name = "Crossbill",
	fullname = _("Crossbill Sync"),
	description = _([[Syncs your highlights to Crossbill server for editing and management.]]),
	version = "0.15.0",
	-- Where the plugin comes from: shown in About, and offered when the
	-- server refuses this version without naming an address of its own.
	homepage = "https://github.com/Crossbill-App/koreader-plugin",
	-- What "Check for Updates" asks for the newest published version. A whole
	-- address rather than a repository name, so serving releases from
	-- somewhere else is an edit here rather than in the module that reads it.
	update_check_url = "https://api.github.com/repos/Crossbill-App/koreader-plugin/releases/latest",
}
