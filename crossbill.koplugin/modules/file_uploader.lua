--[[
File Uploader Module for Crossbill Sync

Handles uploading book-related files to the Crossbill server:
- Cover images
- EPUB files

Extracted from main.lua to improve separation of concerns.
]]

local logger = require("logger")

local FileUploader = {}
FileUploader.__index = FileUploader

--- Create a new FileUploader instance
-- @param api_client ApiClient instance for server communication
-- @return FileUploader instance
function FileUploader:new(api_client)
	local instance = setmetatable({}, FileUploader)
	instance.api_client = api_client
	return instance
end

--- Upload cover image for a book if server doesn't have one
-- @param client_book_id string The client book ID (hash of title|author)
-- @param book_metadata BookMetadata instance for cover extraction
-- @param server_metadata table|nil Server metadata from getBookMetadata
-- @return boolean Success status
-- @return string|nil Error message
function FileUploader:uploadCover(client_book_id, book_metadata, server_metadata)
	if not server_metadata then
		logger.dbg("Crossbill FileUploader: No server metadata, skipping cover upload")
		return true, nil
	end

	if server_metadata.has_cover then
		logger.dbg("Crossbill FileUploader: Server already has cover, skipping upload")
		return true, nil
	end

	local tmp_path, cover_data, cover_image = book_metadata:extractCoverToFile(client_book_id)

	if not cover_data then
		logger.dbg("Crossbill FileUploader: No cover available for extraction")
		return true, nil
	end

	local success, _, err = self.api_client:uploadCover(client_book_id, cover_data)

	if cover_image then
		cover_image:free()
	end
	if tmp_path then
		os.remove(tmp_path)
	end

	if not success then
		logger.warn("Crossbill FileUploader: Failed to upload cover:", err)
		return false, err
	end

	return true, nil
end

--- Upload EPUB file for a book if server doesn't have one
-- @param client_book_id string The client book ID (hash of title|author)
-- @param book_metadata BookMetadata instance for getting document path
-- @param server_metadata table|nil Server metadata from getBookMetadata
-- @return boolean Success status
-- @return string|nil Error message
function FileUploader:uploadEpub(client_book_id, book_metadata, server_metadata)
	if not server_metadata then
		logger.dbg("Crossbill FileUploader: No server metadata, skipping EPUB upload")
		return true, nil
	end

	if server_metadata.has_ebook then
		logger.dbg("Crossbill FileUploader: Server already has EPUB, skipping upload")
		return true, nil
	end

	local doc_path = book_metadata:getDocPath()
	if not doc_path or not doc_path:match("%.epub$") then
		logger.dbg("Crossbill FileUploader: Document is not an EPUB file, skipping upload")
		return true, nil
	end

	local epub_file = io.open(doc_path, "rb")
	if not epub_file then
		logger.err("Crossbill FileUploader: Failed to open EPUB file for reading")
		return false, "Failed to open EPUB file"
	end

	local epub_data = epub_file:read("*all")
	epub_file:close()

	if not epub_data or epub_data == "" then
		logger.err("Crossbill FileUploader: Failed to read EPUB data")
		return false, "Failed to read EPUB data"
	end

	local filename = doc_path:match("^.+/(.+)$") or "document.epub"

	logger.dbg("Crossbill FileUploader: Uploading EPUB file:", filename, "size:", #epub_data, "bytes")

	-- Upload EPUB
	local success, _, err = self.api_client:uploadEpub(client_book_id, epub_data, filename)

	if not success then
		logger.warn("Crossbill FileUploader: Failed to upload EPUB:", err)
		return false, err
	end

	return true, nil
end

return FileUploader
