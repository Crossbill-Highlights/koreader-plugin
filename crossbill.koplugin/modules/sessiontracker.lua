--[[
Session Tracker Module for Crossbill Sync

Tracks reading sessions locally in a SQLite3 database.
Stores device-independent position data (XPointers for reflowable docs,
page numbers for fixed-layout docs) for later sync and analytics.
]]

local logger = require("logger")
local SQ3 = require("lua-ljsqlite3/init")
local Device = require("device")
local BookMetadata = require("modules/book_metadata")

local SessionTracker = {}
SessionTracker.__index = SessionTracker

-- Constants
local DB_FILENAME = "crossbill_sessions.sqlite3"

-- Database schema
local SCHEMA = [[
CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_file TEXT NOT NULL,
    book_hash TEXT NOT NULL,
    book_title TEXT,
    book_author TEXT,
    start_time INTEGER NOT NULL,
    end_time INTEGER NOT NULL,
    duration_seconds INTEGER,
    position_type TEXT NOT NULL,
    start_position TEXT NOT NULL,
    end_position TEXT NOT NULL,
    start_page INTEGER,
    end_page INTEGER,
    total_pages INTEGER,
    synced INTEGER DEFAULT 0,
    sync_attempts INTEGER DEFAULT 0,
    created_at INTEGER DEFAULT (strftime('%s', 'now')),
    device_id TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_book_hash ON sessions(book_hash);
CREATE INDEX IF NOT EXISTS idx_sessions_synced ON sessions(synced);
CREATE INDEX IF NOT EXISTS idx_sessions_start_time ON sessions(start_time);
]]

--- Create a new SessionTracker instance
-- @param settings Settings instance for accessing configuration
-- @return SessionTracker instance
function SessionTracker:new(settings)
	local instance = setmetatable({}, SessionTracker)
	instance.db = nil
	instance.current_session = nil
	instance.db_path = nil
	instance._initialized = false
	instance.settings = settings
	return instance
end

--- Initialize the session tracker with database
-- @param settings_dir string Path to KOReader settings directory
-- @return boolean Success status
function SessionTracker:init(settings_dir)
	if self._initialized then
		return true
	end

	self.db_path = settings_dir .. "/" .. DB_FILENAME
	logger.dbg("Crossbill SessionTracker: Initializing database at", self.db_path)

	local success, err = pcall(function()
		self.db = SQ3.open(self.db_path)
		-- Enable WAL mode for better performance
		self.db:exec("PRAGMA journal_mode=WAL;")
		-- Create schema
		self.db:exec(SCHEMA)
		-- Migrate existing databases: add book_author column if missing
		pcall(function()
			self.db:exec("ALTER TABLE sessions ADD COLUMN book_author TEXT")
		end)
	end)

	if not success then
		logger.err("Crossbill SessionTracker: Failed to initialize database:", err)
		self.db = nil
		return false
	end

	self._initialized = true
	logger.dbg("Crossbill SessionTracker: Database initialized successfully")
	return true
end

--- Close the database connection
function SessionTracker:close()
	if self.db then
		logger.dbg("Crossbill SessionTracker: Closing database")
		local success, err = pcall(function()
			-- Checkpoint WAL to ensure all data is written to main file
			self.db:exec("PRAGMA wal_checkpoint(TRUNCATE);")
			self.db:close()
		end)
		if not success then
			logger.warn("Crossbill SessionTracker: Error closing database:", err)
		end
		self.db = nil
	end
	self._initialized = false
	self.current_session = nil
end

--- Get MD5 hash of a file path for consistent book identification
-- This is a public method that can be used by other modules to ensure
-- consistent book hash calculation across the plugin.
-- @param file_path string The file path to hash
-- @return string MD5 hash
function SessionTracker:getBookHash(file_path)
	local md5 = require("ffi/sha2").md5
	return md5(file_path)
end

--- Get device identifier
-- @return string Device ID or "unknown"
function SessionTracker:_getDeviceId()
	local success, device_info = pcall(function()
		return Device:info()
	end)

	if success and device_info then
		-- Try to construct a meaningful device ID
		local model = Device.model or "unknown"
		return model
	end

	return "unknown"
end

--- Capture current reading position from document
-- @param document The document object
-- @param ui The UI object
-- @return table Position data {type, position, page}
function SessionTracker:_capturePosition(document, ui)
	if not document then
		return nil
	end

	local position_data = {
		type = "page",
		position = "0",
		page = 0,
	}

	local success, err = pcall(function()
		-- Check if document has fixed pages (PDF, DjVu) or is reflowable (EPUB, etc.)
		local has_pages = document.info and document.info.has_pages

		if has_pages then
			-- Fixed layout document - use page number
			position_data.type = "page"
			local page = ui.view and ui.view.state and ui.view.state.page or 1
			position_data.position = tostring(page)
			position_data.page = page
		else
			-- Reflowable document - use XPointer
			position_data.type = "xpointer"
			local xpointer = document:getXPointer()
			if xpointer then
				position_data.position = xpointer
			end
			-- Also capture page for reference
			if ui.view and ui.view.state and ui.view.state.page then
				position_data.page = ui.view.state.page
			end
		end
	end)

	if not success then
		logger.warn("Crossbill SessionTracker: Error capturing position:", err)
	end

	return position_data
end

--- Get total pages in document
-- @param document The document object
-- @param ui The UI object
-- @return number Total pages or 0
function SessionTracker:_getTotalPages(document, ui)
	local success, pages = pcall(function()
		if ui.view and ui.view.state and ui.view.state.doc_height then
			-- For reflowable docs, this might need adjustment
			return ui.document:getPageCount()
		elseif document.getPageCount then
			return document:getPageCount()
		end
		return 0
	end)

	return success and pages or 0
end

--- Start tracking a new reading session
-- @param document The document object
-- @param ui The UI object
function SessionTracker:startSession(document, ui)
	if not self._initialized or not self.db then
		logger.warn("Crossbill SessionTracker: Cannot start session - not initialized")
		return
	end

	if not document then
		logger.warn("Crossbill SessionTracker: Cannot start session - no document")
		return
	end

	-- If there's already an active session, end it first
	if self.current_session then
		logger.dbg("Crossbill SessionTracker: Ending previous session before starting new one")
		self:endSession(document, ui, "new_session")
	end

	local file_path = document.file or ""
	local position = self:_capturePosition(document, ui)

	if not position then
		logger.warn("Crossbill SessionTracker: Cannot capture start position")
		return
	end

	-- Get book title and author from document properties
	local book_title = nil
	local book_author = nil

	-- Extract full metadata if UI is available
	if ui then
		local meta_extractor = BookMetadata:new(ui)
		local success, book_data = pcall(function()
			return meta_extractor:extractBookData()
		end)
		if success and book_data then
			book_title = book_data.title
			book_author = book_data.author
		else
			logger.warn("Crossbill SessionTracker: Failed to extract book metadata")
		end
	end

	-- Fallback if metadata extraction failed or UI not available (shouldn't happen in normal reading)
	if not book_title or not book_author then
		local success, err = pcall(function()
			local props = document:getProps()
			if props then
				if not book_title and props.title and props.title ~= "" then
					book_title = props.title
				end
				if not book_author and props.authors and props.authors ~= "" then
					book_author = props.authors
				end
			end
		end)
		if not success then
			logger.dbg("Crossbill SessionTracker: Could not get book properties:", err)
		end
	end

	self.current_session = {
		book_file = file_path,
		book_hash = self:getBookHash(file_path),
		book_title = book_title,
		book_author = book_author,
		start_time = os.time(),
		start_position = position.position,
		start_page = position.page,
		position_type = position.type,
		-- These will be updated as reading progresses
		current_position = position.position,
		current_page = position.page,
		total_pages = self:_getTotalPages(document, ui),
	}

	logger.dbg("Crossbill SessionTracker: Started session for", book_title or file_path)
end

--- Update current reading position (called on every page turn)
-- This should be fast as it's called frequently
-- @param document The document object
-- @param ui The UI object
-- @param pageno number Current page number (optional)
function SessionTracker:updatePosition(document, ui, pageno)
	if not self.current_session then
		return
	end

	-- Quick update without full position capture for performance
	if pageno then
		self.current_session.current_page = pageno
	end

	-- Only do full position capture occasionally or if we don't have pageno
	if not pageno then
		local position = self:_capturePosition(document, ui)
		if position then
			self.current_session.current_position = position.position
			self.current_session.current_page = position.page
		end
	end
end

--- End current session and save to database
-- @param document The document object
-- @param ui The UI object
-- @param reason string Reason for ending ("document_close", "suspend", "app_exit", "new_session")
function SessionTracker:endSession(document, ui, reason)
	if not self.current_session then
		logger.dbg("Crossbill SessionTracker: No active session to end")
		return
	end

	if not self._initialized or not self.db then
		logger.warn("Crossbill SessionTracker: Cannot end session - database not available")
		self.current_session = nil
		return
	end

	local session = self.current_session
	local end_time = os.time()
	local duration = end_time - session.start_time

	-- Discard very short sessions
	local min_duration = self.settings:getMinReadingSessionDuration() or 60
	if duration < min_duration then
		logger.dbg("Crossbill SessionTracker: Discarding short session (", duration, "seconds) - reason:", reason)
		self.current_session = nil
		return
	end

	-- Capture final position
	local end_position = session.current_position
	local end_page = session.current_page

	if document then
		local position = self:_capturePosition(document, ui)
		if position then
			end_position = position.position
			end_page = position.page
		end
	end

	-- Save to database
	local success, err = pcall(function()
		local stmt = self.db:prepare([[
            INSERT INTO sessions (
                book_file, book_hash, book_title, book_author,
                start_time, end_time, duration_seconds,
                position_type, start_position, end_position,
                start_page, end_page, total_pages,
                device_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])

		stmt:bind(
			session.book_file,
			session.book_hash,
			session.book_title,
			session.book_author,
			session.start_time,
			end_time,
			duration,
			session.position_type,
			session.start_position,
			end_position,
			session.start_page,
			end_page,
			session.total_pages,
			self:_getDeviceId()
		)

		stmt:step()
		stmt:close()
	end)

	if success then
		logger.dbg("Crossbill SessionTracker: Saved session (", duration, "seconds) - reason:", reason)
		-- Checkpoint WAL to ensure data is written to main file
		pcall(function()
			self.db:exec("PRAGMA wal_checkpoint(PASSIVE);")
		end)
	else
		logger.err("Crossbill SessionTracker: Failed to save session:", err)
	end

	self.current_session = nil
end

--- Mark sessions as synced
-- @param session_ids table Array of session IDs to mark as synced
-- @return boolean Success status
function SessionTracker:markSessionsSynced(session_ids)
	if not self._initialized or not self.db then
		return false
	end

	if not session_ids or #session_ids == 0 then
		return true
	end

	local success, err = pcall(function()
		-- Build placeholder string for IN clause
		local placeholders = {}
		for i = 1, #session_ids do
			placeholders[i] = "?"
		end

		local sql = "UPDATE sessions SET synced = 1 WHERE id IN (" .. table.concat(placeholders, ",") .. ")"
		local stmt = self.db:prepare(sql)
		stmt:bind(unpack(session_ids))
		stmt:step()
		stmt:close()
	end)

	if not success then
		logger.err("Crossbill SessionTracker: Error marking sessions as synced:", err)
		return false
	end

	return true
end

--- Get unsynced sessions for a specific book
-- @param book_hash string MD5 hash of the book file path
-- @return table Array of session records for API upload
function SessionTracker:getUnsyncedSessionsForBook(book_hash)
	if not self._initialized or not self.db then
		return {}
	end

	if not book_hash then
		return {}
	end

	local sessions = {}
	local success, err = pcall(function()
		local stmt = self.db:prepare([[
            SELECT s.id, s.book_file, s.book_hash, s.book_title, s.book_author,
                   s.start_time, s.end_time, s.duration_seconds,
                   s.position_type, s.start_position, s.end_position,
                   s.start_page, s.end_page, s.total_pages,
                   s.device_id, s.created_at
            FROM sessions s
            WHERE s.book_hash = ? AND s.synced = 0
            ORDER BY s.start_time ASC
        ]])

		stmt:bind(book_hash)

		for row in stmt:rows() do
			table.insert(sessions, {
				id = row[1],
				book_file = row[2],
				book_hash = row[3],
				book_title = row[4],
				book_author = row[5],
				start_time = row[6],
				end_time = row[7],
				duration_seconds = row[8],
				position_type = row[9],
				start_position = row[10],
				end_position = row[11],
				start_page = row[12],
				end_page = row[13],
				total_pages = row[14],
				device_id = row[15],
				created_at = row[16],
			})
		end
		stmt:close()
	end)

	if not success then
		logger.err("Crossbill SessionTracker: Error fetching unsynced sessions for book:", err)
	end

	return sessions
end

--- Get sessions for a specific book
-- @param book_hash string MD5 hash of the book file path
-- @return table Array of session records
function SessionTracker:getSessionsForBook(book_hash)
	if not self._initialized or not self.db then
		return {}
	end

	local sessions = {}
	local success, err = pcall(function()
		local stmt = self.db:prepare([[
            SELECT id, book_file, book_hash, book_title, book_author,
                   start_time, end_time, duration_seconds,
                   position_type, start_position, end_position,
                   start_page, end_page, total_pages,
                   device_id, created_at, synced
            FROM sessions
            WHERE book_hash = ?
            ORDER BY start_time DESC
        ]])

		stmt:bind(book_hash)

		for row in stmt:rows() do
			table.insert(sessions, {
				id = row[1],
				book_file = row[2],
				book_hash = row[3],
				book_title = row[4],
				book_author = row[5],
				start_time = row[6],
				end_time = row[7],
				duration_seconds = row[8],
				position_type = row[9],
				start_position = row[10],
				end_position = row[11],
				start_page = row[12],
				end_page = row[13],
				total_pages = row[14],
				device_id = row[15],
				created_at = row[16],
				synced = row[17],
			})
		end
		stmt:close()
	end)

	if not success then
		logger.err("Crossbill SessionTracker: Error fetching sessions for book:", err)
	end

	return sessions
end

--- Check if there's an active session
-- @return boolean True if session is active
function SessionTracker:hasActiveSession()
	return self.current_session ~= nil
end

return SessionTracker
