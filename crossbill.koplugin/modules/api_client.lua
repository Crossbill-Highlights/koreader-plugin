--[[
API Client Module for Crossbill Sync

Provides a clean interface for communicating with the Crossbill server API.
Handles highlight uploads, cover image uploads, and other API operations.
]]

local Network = require("modules/network")
local logger = require("logger")

-- Handle empty array JSON serialization
local JSON = require("json")
-- The most reliable way to get the marker for an empty array is to decode one
local empty_array = JSON.decode("[]") or {}

local ApiClient = {}
ApiClient.__index = ApiClient

--- Create a new ApiClient instance
-- @param settings Settings instance
-- @param auth Auth instance
-- @return ApiClient instance
function ApiClient:new(settings, auth)
	local instance = setmetatable({}, ApiClient)
	instance.settings = settings
	instance.auth = auth
	return instance
end

--- Get the API base URL
-- @return string API base URL
function ApiClient:getApiUrl()
	return self.settings:getBaseUrl() .. "/api/v1"
end

--- Upload highlights to the server
-- @param book_data table Book metadata
-- @param highlights table Array of highlights
-- @return boolean Success status
-- @return table|nil Response data containing book_id, highlights_created, highlights_skipped
-- @return string|nil Error message
function ApiClient:uploadHighlights(book_data, highlights)
	local token, auth_err = self.auth:getValidToken()
	if not token then
		return false, nil, auth_err or "Authentication failed"
	end

	local payload = {
		book = book_data,
		highlights = highlights,
	}

	local api_url = self:getApiUrl() .. "/highlights/upload"
	logger.dbg("Crossbill API: Sending highlights to", api_url)

	local code, response_data, err = Network.postJson(api_url, payload, token)

	if not code then
		logger.err("Crossbill API: Network error:", err)
		return false, nil, err or "Network error"
	end

	if code == 200 and response_data then
		logger.dbg("Crossbill API: Highlights uploaded successfully")
		return true, response_data, nil
	else
		logger.err("Crossbill API: Upload failed with code:", code)
		return false, nil, "Upload failed: " .. tostring(code)
	end
end

--- Get book metadata from server by client_book_id
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @return number|nil HTTP status code
-- @return table|nil Response data containing book_id, bookname, author, hasCover, hasEpub
-- @return string|nil Error message
function ApiClient:getBookMetadata(client_book_id)
	local token, auth_err = self.auth:getValidToken()
	if not token then
		return nil, nil, auth_err or "Authentication failed"
	end

	local api_url = self:getApiUrl() .. "/ereader/books/" .. client_book_id
	logger.dbg("Crossbill API: Fetching book metadata from", api_url)

	local code, response_data, err = Network.getJson(api_url, token)

	if not code then
		logger.err("Crossbill API: Network error fetching book metadata:", err)
		return nil, nil, err or "Network error"
	end

	if code == 200 and response_data then
		logger.dbg("Crossbill API: Book metadata fetched successfully")
		return code, response_data, nil
	elseif code == 404 then
		logger.dbg("Crossbill API: Book not found (404)")
		return code, nil, nil
	else
		logger.warn("Crossbill API: Fetch book metadata failed with code:", code)
		return code, nil, "Fetch failed: " .. tostring(code)
	end
end

--- Upload a cover image for a book using client_book_id
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @param cover_data string The cover image binary data
-- @return boolean Success status
-- @return string|nil Error message
function ApiClient:uploadCover(client_book_id, cover_data)
	local token, auth_err = self.auth:getValidToken()
	if not token then
		return false, auth_err or "Authentication failed"
	end

	local api_url = self:getApiUrl() .. "/ereader/books/" .. client_book_id .. "/cover"
	logger.dbg("Crossbill API: Uploading cover to", api_url)

	local files = {
		{
			name = "cover",
			filename = "cover.jpg",
			content_type = "image/jpeg",
			data = cover_data,
		},
	}

	local code, _, err = Network.postMultipart(api_url, files, token)

	if not code then
		logger.err("Crossbill API: Network error uploading cover:", err)
		return false, err or "Network error"
	end

	if code == 200 then
		logger.info("Crossbill API: Cover uploaded successfully for book", client_book_id)
		return true, nil
	else
		logger.warn("Crossbill API: Cover upload failed with code:", code)
		return false, "Upload failed: " .. tostring(code)
	end
end

--- Upload an EPUB file for a book using client_book_id
-- @param client_book_id string The client-side book ID (hash of title|author)
-- @param epub_data string The EPUB file binary data
-- @param filename string The original EPUB filename
-- @return boolean Success status
-- @return string|nil Error message
function ApiClient:uploadEpub(client_book_id, epub_data, filename)
	local token, auth_err = self.auth:getValidToken()
	if not token then
		return false, auth_err or "Authentication failed"
	end

	local api_url = self:getApiUrl() .. "/ereader/books/" .. client_book_id .. "/epub"
	logger.dbg("Crossbill API: Uploading EPUB to", api_url)

	local files = {
		{
			name = "epub",
			filename = filename,
			content_type = "application/epub+zip",
			data = epub_data,
		},
	}

	local code, _, err = Network.postMultipart(api_url, files, token)

	if not code then
		logger.err("Crossbill API: Network error uploading EPUB:", err)
		return false, err or "Network error"
	end

	if code == 200 then
		logger.info("Crossbill API: EPUB uploaded successfully for book", client_book_id)
		return true, nil
	else
		logger.warn("Crossbill API: EPUB upload failed with code:", code)
		return false, "Upload failed: " .. tostring(code)
	end
end

local function unixToISO8601(timestamp)
	if not timestamp then
		return nil
	end
	-- Convert to number (handles LuaJIT cdata int64 from SQLite)
	local ts = tonumber(timestamp)
	if not ts then
		return nil
	end
	return os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
end

--- Upload reading sessions to the server for a single book
-- @param book_data table Book metadata
-- @param sessions table Array of session records from SessionTracker
-- @return boolean Success status
-- @return table|nil Response data (success, message, created_count, skipped_duplicate_count)
-- @return string|nil Error message
function ApiClient:uploadReadingSessions(book_data, sessions)
	local token, auth_err = self.auth:getValidToken()
	if not token then
		return false, nil, auth_err or "Authentication failed"
	end

	-- Transform sessions to API format
	local api_sessions = {}
	for _, session in ipairs(sessions) do
		local api_session = {
			start_time = unixToISO8601(session.start_time),
			end_time = unixToISO8601(session.end_time),
			device_id = session.device_id,
			start_page = session.start_page and tonumber(session.start_page) or 0,
			end_page = session.end_page and tonumber(session.end_page) or 0,
		}

		-- Map position data based on type
		if session.position_type == "xpointer" then
			api_session.start_xpoint = session.start_position
			api_session.end_xpoint = session.end_position
		else
			api_session.start_xpoint = ""
			api_session.end_xpoint = ""
		end

		table.insert(api_sessions, api_session)
	end

	logger.info("Crossbill API: Prepared", #api_sessions, "sessions for upload")

	local payload = {
		book = book_data,
		sessions = (#api_sessions > 0) and api_sessions or empty_array,
	}

	local api_url = self:getApiUrl() .. "/reading_sessions/upload"
	logger.dbg("Crossbill API: Sending", #api_sessions, "reading sessions to", api_url)

	local code, response_data, err = Network.postJson(api_url, payload, token)

	if not code then
		logger.err("Crossbill API: Network error:", err)
		return false, nil, err or "Network error"
	end

	if code == 200 and response_data then
		logger.info("Crossbill API: Reading sessions uploaded successfully")
		return true, response_data, nil
	else
		logger.warn("Crossbill API: Reading sessions upload failed with code:", code)
		return false, nil, "Upload failed: " .. tostring(code)
	end
end

return ApiClient
