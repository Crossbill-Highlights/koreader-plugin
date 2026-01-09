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
local HighlightExtractor = require("modules/highlight_extractor")
local BookMetadata = require("modules/book_metadata")
local SessionTracker = require("modules/sessiontracker")
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

	-- Initialize session tracker with settings
	self.session_tracker = SessionTracker:new(self.settings)
	self.session_tracker:init(DataStorage:getSettingsDir())

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

--- Sync the currently open book's highlights
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
	-- Extract book metadata
	local book_metadata = BookMetadata:new(self.ui)
	local book_data = book_metadata:extractBookData()
	local doc_path = book_metadata:getDocPath()

	-- Extract highlights
	local highlight_extractor = HighlightExtractor:new(self.ui)
	local highlights = highlight_extractor:getHighlights(doc_path)

	-- Track highlight upload response for success message
	local highlights_response = nil

	if highlights and #highlights > 0 then
		logger.dbg("Crossbill: Found", #highlights, "highlights")

		-- Add chapter numbers to highlights
		highlight_extractor:addChapterNumbers(highlights)

		-- Upload highlights to server
		local upload_success, response, err = self.api_client:uploadHighlights(book_data, highlights)

		if not upload_success then
			if not is_autosync then
				if err and err:match("^Authentication") then
					UI.showAuthError(err)
				else
					UI.showSyncFailed(err)
				end
			end
			return
		end

		highlights_response = response
	end

	-- TODO: Add proper error handling and UI notifications here...

	-- Upload reading sessions
	self:uploadReadingSessions()

	-- Fetch server metadata once for cover and EPUB uploads
	local server_metadata = self:getServerBookMetadata(book_data.client_book_id)

	-- Upload cover image if available
	self:uploadCoverImage(book_data.client_book_id, book_metadata, server_metadata)

	-- Upload EPUB file if available
	self:uploadEpub(book_data.client_book_id, book_metadata, server_metadata)

	-- Show success message for manual syncs
	if not is_autosync then
		local created = highlights_response and highlights_response.highlights_created or 0
		local skipped = highlights_response and highlights_response.highlights_skipped or 0
		UI.showSyncSuccess(created, skipped)
	end
end

--- Fetch book metadata from the server
-- @param client_book_id string The client book ID (hash of title|author)
-- @return table|nil Server metadata containing has_cover, has_epub, etc. or nil if not found
function CrossbillSync:getServerBookMetadata(client_book_id)
	local code, metadata, _ = self.api_client:getBookMetadata(client_book_id)

	if code == 404 then
		logger.dbg("Crossbill: Book not found on server")
		return nil
	end

	if not metadata then
		logger.warn("Crossbill: Failed to fetch book metadata from server")
		return nil
	end

	return metadata
end

--- Upload cover image for a book if server doesn't have one
-- @param client_book_id string The client book ID (hash of title|author)
-- @param book_metadata BookMetadata instance
-- @param server_metadata table|nil Server metadata from getServerBookMetadata
function CrossbillSync:uploadCoverImage(client_book_id, book_metadata, server_metadata)
	local success, err = pcall(function()
		-- Check if server metadata is available and if cover is needed
		if not server_metadata then
			logger.dbg("Crossbill: No server metadata, skipping cover upload")
			return
		end

		if server_metadata.has_cover then
			logger.dbg("Crossbill: Server already has cover, skipping upload")
			return
		end

		-- Server doesn't have cover, extract and upload it
		local tmp_path, cover_data, cover_image = book_metadata:extractCoverToFile(client_book_id)

		if not cover_data then
			return
		end

		-- Upload cover using client_book_id
		self.api_client:uploadCover(client_book_id, cover_data)

		-- Cleanup
		if cover_image then
			cover_image:free()
		end
		if tmp_path then
			os.remove(tmp_path)
		end
	end)

	if not success then
		logger.err("Crossbill: Error uploading cover:", err)
	end
end

--- Upload EPUB file for a book if server doesn't have one
-- @param client_book_id string The client book ID (hash of title|author)
-- @param book_metadata BookMetadata instance
-- @param server_metadata table|nil Server metadata from getServerBookMetadata
function CrossbillSync:uploadEpub(client_book_id, book_metadata, server_metadata)
	local success, err = pcall(function()
		-- Check if server metadata is available and if EPUB is needed
		if not server_metadata then
			logger.dbg("Crossbill: No server metadata, skipping EPUB upload")
			return
		end

		if server_metadata.has_epub then
			logger.dbg("Crossbill: Server already has EPUB, skipping upload")
			return
		end

		-- Check if document is an EPUB file
		local doc_path = book_metadata:getDocPath()
		if not doc_path or not doc_path:match("%.epub$") then
			logger.dbg("Crossbill: Document is not an EPUB file, skipping upload")
			return
		end

		-- Read the EPUB file
		local epub_file = io.open(doc_path, "rb")
		if not epub_file then
			logger.err("Crossbill: Failed to open EPUB file for reading")
			return
		end

		local epub_data = epub_file:read("*all")
		epub_file:close()

		if not epub_data or epub_data == "" then
			logger.err("Crossbill: Failed to read EPUB data")
			return
		end

		-- Extract filename from path
		local filename = doc_path:match("^.+/(.+)$") or "document.epub"

		logger.dbg("Crossbill: Uploading EPUB file:", filename, "size:", #epub_data, "bytes")

		-- Upload EPUB
		local upload_success, _, upload_err = self.api_client:uploadEpub(client_book_id, epub_data, filename)

		if not upload_success then
			logger.warn("Crossbill: Failed to upload EPUB:", upload_err)
		end
	end)

	if not success then
		logger.err("Crossbill: Error uploading EPUB:", err)
	end
end

--- Upload unsynced reading sessions to server for the current book
-- @return boolean Success status
-- @return number Number of sessions synced (or error message on failure)
-- @return number|nil book_id from server response (nil on failure or no sessions)
function CrossbillSync:uploadReadingSessions()
	if not self:isSessionTrackingActive() then
		logger.dbg("Crossbill: Session tracking not enabled")
		return true, 0, nil
	end

	if not self.ui.document then
		logger.dbg("Crossbill: No document available for session sync")
		return true, 0, nil
	end

	-- Get current book's metadata and hash
	local book_metadata = BookMetadata:new(self.ui)
	local book_data = book_metadata:extractBookData()
	local doc_path = book_metadata:getDocPath()

	if not doc_path then
		logger.warn("Crossbill: Cannot get document path for session sync")
		return false, "No document path", nil
	end

	-- Get book hash using the same method as SessionTracker
	local md5 = require("ffi/sha2").md5
	local book_hash = md5(doc_path)

	-- Get unsynced sessions for this book only
	local sessions = self.session_tracker:getUnsyncedSessionsForBook(book_hash)
	if #sessions == 0 then
		logger.dbg("Crossbill: No reading sessions to sync for current book")
		return true, 0, nil
	end

	logger.info("Crossbill: Found", #sessions, "unsynced reading sessions for current book")

	local success, response, err = self.api_client:uploadReadingSessions(book_data, sessions)
	if success and response then
		-- Mark all sessions as synced (all-or-nothing API)
		local session_ids = {}
		for _, session in ipairs(sessions) do
			table.insert(session_ids, session.id)
		end
		self.session_tracker:markSessionsSynced(session_ids)

		logger.info("Crossbill: Synced", #sessions, "reading sessions")
		return true, #sessions, response.book_id
	end

	-- On failure, sessions remain unsynced for retry
	logger.warn("Crossbill: Failed to sync reading sessions:", err)
	return false, err, nil
end

--- Try to sync reading sessions opportunistically (only if already online)
function CrossbillSync:trySessionSync()
	local NetworkMgr = require("ui/network/manager")
	if NetworkMgr:isOnline() then
		self:uploadReadingSessions()
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
