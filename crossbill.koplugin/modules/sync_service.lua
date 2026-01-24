--[[
Sync Service Module for Crossbill Sync

Orchestrates the complete sync workflow including:
- Highlight extraction and upload
- Reading session upload
- Cover and EPUB file uploads

Extracted from main.lua to improve separation of concerns.
The main plugin handles lifecycle events and UI, while this
module handles the sync business logic.
]]

local logger = require("logger")
local BookMetadata = require("modules/book_metadata")
local HighlightExtractor = require("modules/highlight_extractor")

local SyncService = {}
SyncService.__index = SyncService

--- Create a new SyncService instance
-- @param api_client ApiClient instance for server communication
-- @param file_uploader FileUploader instance for file uploads
-- @param session_tracker SessionTracker instance for reading sessions
-- @param settings Settings instance for configuration
-- @return SyncService instance
function SyncService:new(api_client, file_uploader, session_tracker, settings)
	local instance = setmetatable({}, SyncService)
	instance.api_client = api_client
	instance.file_uploader = file_uploader
	instance.session_tracker = session_tracker
	instance.settings = settings
	return instance
end

--- Sync result structure
-- @field success boolean Whether sync completed successfully
-- @field highlights_created number Number of new highlights synced
-- @field highlights_skipped number Number of duplicate highlights skipped
-- @field sessions_synced number Number of reading sessions synced
-- @field error string|nil Error message if sync failed

--- Execute the complete sync workflow for a book
-- @param ui table The KOReader UI context
-- @return table SyncResult with success status and counts
function SyncService:syncBook(ui)
	local result = {
		success = true,
		highlights_created = 0,
		highlights_skipped = 0,
		sessions_synced = 0,
		error = nil,
	}

	-- Extract book metadata
	local book_metadata = BookMetadata:new(ui)
	local book_data = book_metadata:extractBookData()
	local doc_path = book_metadata:getDocPath()

	-- Fetch or create book on server
	local server_metadata = self:_getServerBookMetadata(book_data.client_book_id)
	if not server_metadata then
		-- Book doesn't exist on server, create it
		logger.info("Crossbill SyncService: Book not found on server, creating it")
		local create_success, created_metadata, create_err = self.api_client:createBook(book_data)
		if not create_success then
			result.success = false
			result.error = create_err or "Failed to create book on server"
			return result
		end
		server_metadata = created_metadata
	end

	-- Upload files (cover and EPUB)
	self:_syncFiles(book_data.client_book_id, book_metadata, server_metadata)

	-- Extract and upload highlights
	local highlight_result = self:_syncHighlights(ui, book_data, doc_path)
	if not highlight_result.success then
		result.success = false
		result.error = highlight_result.error
		return result
	end
	result.highlights_created = highlight_result.created
	result.highlights_skipped = highlight_result.skipped

	-- Upload reading sessions
	local session_result = self:_syncReadingSessions(ui, book_data, doc_path)
	result.sessions_synced = session_result.synced

	return result
end

--- Sync highlights for the current book
-- @param ui table The KOReader UI context
-- @param book_data table Book metadata
-- @param doc_path string Document file path
-- @return table Result with success, created, skipped, error
function SyncService:_syncHighlights(ui, book_data, doc_path)
	local result = { success = true, created = 0, skipped = 0, error = nil }

	-- Extract highlights
	local highlight_extractor = HighlightExtractor:new(ui)
	local highlights = highlight_extractor:getHighlights(doc_path)

	if not highlights or #highlights == 0 then
		logger.dbg("Crossbill SyncService: No highlights found")
		return result
	end

	logger.dbg("Crossbill SyncService: Found", #highlights, "highlights")

	-- Add chapter numbers to highlights
	highlight_extractor:addChapterNumbers(highlights)

	-- Upload highlights to server
	local upload_success, response, err = self.api_client:uploadHighlights(book_data, highlights)

	if not upload_success then
		result.success = false
		result.error = err
		return result
	end

	if response then
		result.created = response.highlights_created or 0
		result.skipped = response.highlights_skipped or 0
	end

	return result
end

--- Sync reading sessions for the current book
-- @param ui table The KOReader UI context
-- @param book_data table Book metadata
-- @param doc_path string Document file path
-- @return table Result with success, synced, error
function SyncService:_syncReadingSessions(ui, book_data, doc_path)
	local result = { success = true, synced = 0, error = nil }

	if not self.session_tracker or not self.settings:isSessionTrackingEnabled() then
		logger.dbg("Crossbill SyncService: Session tracking not enabled")
		return result
	end

	if not doc_path then
		logger.warn("Crossbill SyncService: Cannot get document path for session sync")
		return result
	end

	-- Get book file hash using SessionTracker's method for consistency
	local book_file_hash = self.session_tracker:getBookFileHash(doc_path)

	-- Get unsynced sessions for this book only
	local sessions = self.session_tracker:getUnsyncedSessionsForBook(book_file_hash)
	if #sessions == 0 then
		logger.dbg("Crossbill SyncService: No reading sessions to sync for current book")
		return result
	end

	logger.info("Crossbill SyncService: Found", #sessions, "unsynced reading sessions")

	local success, response, err = self.api_client:uploadReadingSessions(book_data, sessions)
	if success and response then
		-- Mark all sessions as synced (all-or-nothing API)
		local session_ids = {}
		for _, session in ipairs(sessions) do
			table.insert(session_ids, session.id)
		end
		self.session_tracker:markSessionsSynced(session_ids)

		logger.info("Crossbill SyncService: Synced", #sessions, "reading sessions")
		result.synced = #sessions
	else
		-- On failure, sessions remain unsynced for retry
		logger.warn("Crossbill SyncService: Failed to sync reading sessions:", err)
		result.success = false
		result.error = err
	end

	return result
end

--- Sync files (cover and EPUB) for the current book
-- @param client_book_id string The client book ID
-- @param book_metadata BookMetadata instance
-- @param server_metadata table Server metadata containing has_cover, has_epub, etc.
function SyncService:_syncFiles(client_book_id, book_metadata, server_metadata)
	-- Upload cover image if available (errors are logged but don't fail sync)
	local cover_ok, cover_err = self.file_uploader:uploadCover(client_book_id, book_metadata, server_metadata)
	if not cover_ok then
		logger.warn("Crossbill SyncService: Cover upload issue:", cover_err)
	end

	-- Upload EPUB file if available (errors are logged but don't fail sync)
	local epub_ok, epub_err = self.file_uploader:uploadEpub(client_book_id, book_metadata, server_metadata)
	if not epub_ok then
		logger.warn("Crossbill SyncService: EPUB upload issue:", epub_err)
	end
end

--- Fetch book metadata from the server
-- @param client_book_id string The client book ID (hash of title|author)
-- @return table|nil Server metadata containing has_cover, has_epub, etc. or nil if not found
function SyncService:_getServerBookMetadata(client_book_id)
	local code, metadata, _ = self.api_client:getBookMetadata(client_book_id)

	if code == 404 then
		logger.dbg("Crossbill SyncService: Book not found on server")
		return nil
	end

	if not metadata then
		logger.warn("Crossbill SyncService: Failed to fetch book metadata from server")
		return nil
	end

	return metadata
end

--- Upload reading sessions opportunistically (called from main when already online)
-- @param ui table The KOReader UI context
-- @return boolean Success status
-- @return number Number of sessions synced
function SyncService:uploadReadingSessionsIfOnline(ui)
	if not ui.document then
		return true, 0
	end

	local book_metadata = BookMetadata:new(ui)
	local book_data = book_metadata:extractBookData()
	local doc_path = book_metadata:getDocPath()

	local result = self:_syncReadingSessions(ui, book_data, doc_path)
	return result.success, result.synced
end

return SyncService
