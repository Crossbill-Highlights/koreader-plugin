--[[
Crossbill Sync Plugin for KOReader

A plugin to synchronize book highlights with a Crossbill server.
Supports manual sync, auto-sync on suspend/exit, and cover image uploads.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local DataStorage = require("datastorage")

local Settings = require("modules/settings")
local Network = require("modules/network")
local Auth = require("modules/auth")
local ApiClient = require("modules/api_client")
local SessionTracker = require("modules/sessiontracker")
local FileUploader = require("modules/file_uploader")
local SyncService = require("modules/sync_service")
local UI = require("modules/ui")

local CrossbillSync = WidgetContainer:extend({
	name = "Crossbill",
	is_doc_only = true, -- Only show when document is open
})

--- Initialize the plugin
function CrossbillSync:init()
	-- Initialize settings
	self.settings = Settings:new():load()

	-- Initialize authentication with settings
	self.auth = Auth:new(self.settings)

	-- Initialize API client with settings and auth
	self.api_client = ApiClient:new(self.settings, self.auth)

	-- Initialize file uploader with API client
	self.file_uploader = FileUploader:new(self.api_client)

	-- Initialize session tracker with settings
	self.session_tracker = SessionTracker:new(self.settings)
	self.session_tracker:init(DataStorage:getSettingsDir())

	-- Initialize sync service with all dependencies
	self.sync_service = SyncService:new(self.api_client, self.file_uploader, self.session_tracker, self.settings)

	-- Register menu
	self.ui.menu:registerToMainMenu(self)
end

--- Add plugin menu items to KOReader main menu
function CrossbillSync:addToMainMenu(menu_items)
	menu_items.crossbill_sync = UI.buildMenuItems({
		on_sync = function()
			self:syncCurrentBook()
		end,
		on_configure = function()
			self:configureServer()
		end,
		is_autosync_enabled = function()
			return self.settings:isAutosyncEnabled()
		end,
		on_toggle_autosync = function()
			local enabled = self.settings:toggleAutosync()
			UI.showAutosyncToggled(enabled)
		end,
		is_session_tracking_enabled = function()
			return self.settings:isSessionTrackingEnabled()
		end,
		on_toggle_session_tracking = function()
			-- End current session before disabling tracking
			if self:isSessionTrackingActive() then
				self.session_tracker:endSession(self.ui.document, self.ui, "tracking_disabled")
			end
			local enabled = self.settings:toggleSessionTracking()
			UI.showSessionTrackingToggled(enabled)
			-- Start new session if re-enabled and document is open
			if enabled and self.ui.document and self.session_tracker then
				self.session_tracker:startSession(self.ui.document, self.ui)
			end
		end,
		on_configure_min_session_duration = function()
			UI.showMinSessionDurationDialog(self.settings)
		end,
	})
end

--- Show server configuration dialog
function CrossbillSync:configureServer()
	UI.showConfigureServerDialog(self.settings)
end

--- Check if session tracking is currently active
-- @return boolean True if session tracking is enabled and tracker is available
function CrossbillSync:isSessionTrackingActive()
	return self.settings:isSessionTrackingEnabled() and self.session_tracker ~= nil
end

--- Sync the currently open book's data
-- @param is_autosync boolean If true, run in silent mode (no UI feedback)
function CrossbillSync:syncCurrentBook(is_autosync)
	local callback = function()
		self:performSync(is_autosync)
	end

	if not Network.ensureWifiEnabled(callback) then
		-- WiFi is being enabled, callback will be called when ready
		logger.info("Crossbill: Waiting for WiFi to be enabled...")
	else
		-- WiFi already on, sync immediately
		self:performSync(is_autosync)
	end
end

--- Perform the actual sync operation
-- @param is_autosync boolean If true, run in silent mode
function CrossbillSync:performSync(is_autosync)
	-- Safety check: ensure document is available
	if not self.ui.document then
		logger.warn("Crossbill: Cannot sync - no document available")
		return
	end

	if not is_autosync then
		UI.showSyncingMessage()
	end

	local success, err = pcall(function()
		self:doSync(is_autosync)
	end)

	if not success then
		logger.err("Crossbill: Error in sync:", err)
		if not is_autosync then
			UI.showSyncError(err)
		end
	end

	-- Always clean up WiFi after sync
	Network.disableWifiIfNeeded()
end

--- Execute the sync workflow
-- @param is_autosync boolean If true, run in silent mode
function CrossbillSync:doSync(is_autosync)
	local result = self.sync_service:syncBook(self.ui)

	if not result.success and not is_autosync then
		if result.error and result.error:match("^Authentication") then
			UI.showAuthError(result.error)
		else
			UI.showSyncFailed(result.error)
		end
		return
	end

	-- Show success message for manual syncs
	if not is_autosync then
		UI.showSyncSuccess(result.highlights_created, result.highlights_skipped)
	end
end

--- Try to sync reading sessions opportunistically (only if already online)
function CrossbillSync:trySessionSync()
	-- TODO: This is a weird abstraction level for this operation. Should we instead do this kind of check in sync service...?
	local NetworkMgr = require("ui/network/manager")
	if NetworkMgr:isOnline() then
		self.sync_service:uploadReadingSessionsIfOnline(self.ui)
	end
	-- If offline, sessions remain in DB for next sync opportunity
end

-- Event handlers for session tracking and auto-sync

--- Called when document is ready for reading
function CrossbillSync:onReaderReady()
	if self:isSessionTrackingActive() then
		self.session_tracker:startSession(self.ui.document, self.ui)
	end
	return false
end

--- Called on every page update
function CrossbillSync:onPageUpdate(pageno)
	if self:isSessionTrackingActive() then
		self.session_tracker:updatePosition(self.ui.document, self.ui, pageno)
	end
	return false
end

--- Called when device resumes from sleep
function CrossbillSync:onResume()
	if self:isSessionTrackingActive() and self.ui.document then
		self.session_tracker:startSession(self.ui.document, self.ui)
	end
	return false
end

--- Called when document is closed
function CrossbillSync:onCloseDocument()
	if self:isSessionTrackingActive() then
		self.session_tracker:endSession(self.ui.document, self.ui, "document_close")
		self:trySessionSync()
	end
	return false
end

--- Called when device goes to sleep/suspend
function CrossbillSync:onSuspend()
	if self:isSessionTrackingActive() then
		self.session_tracker:endSession(self.ui.document, self.ui, "suspend")
	end
	if self.settings:isAutosyncEnabled() then
		logger.info("Crossbill: Auto-syncing on suspend")
		self:syncCurrentBook(true)
	else
		-- Try opportunistic session sync even when auto-sync is disabled
		self:trySessionSync()
	end
	return false
end

--- Called when KOReader exits
function CrossbillSync:onExit()
	if self:isSessionTrackingActive() then
		self.session_tracker:endSession(self.ui.document, self.ui, "app_exit")
	end
	if self.settings:isAutosyncEnabled() then
		logger.info("Crossbill: Auto-syncing on exit")
		self:syncCurrentBook(true)
	else
		-- Try opportunistic session sync even when auto-sync is disabled
		self:trySessionSync()
	end
	-- Close database after sync attempts
	if self.session_tracker then
		self.session_tracker:close()
	end
	return false
end

return CrossbillSync
