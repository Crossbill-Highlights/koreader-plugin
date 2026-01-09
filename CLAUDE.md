# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a KOReader plugin (Lua) that syncs book highlights and reading sessions to a Crossbill server. The plugin is installed by copying the `crossbill.koplugin` directory to KOReader's plugins folder.

## Development

**Testing on device**: Use `copy_to_pocketbook.sh` with a `.env` file containing the path to your device's KOReader plugins folder. The script copies both production and development versions.

**No build step required** - Lua files are loaded directly by KOReader.

## Architecture

The plugin follows a modular architecture with dependency injection:

```
main.lua (CrossbillSync)
    ├── Settings        - Configuration persistence via KOReader's G_reader_settings
    ├── Auth            - OAuth token management (login, refresh, caching)
    ├── ApiClient       - HTTP API communication (highlights, sessions, files)
    ├── FileUploader    - Cover and EPUB uploads (uses ApiClient)
    ├── SessionTracker  - SQLite-based reading session tracking
    ├── SyncService     - Orchestrates sync workflow (uses ApiClient, FileUploader, SessionTracker)
    └── UI              - KOReader dialogs and menu building
```

**Key patterns:**
- `main.lua` is the entry point, extending KOReader's `WidgetContainer`
- All modules use constructor injection: `Module:new(dependencies)`
- API methods return consistent 3-tuples: `success/code, data, error`
- Network module handles WiFi lifecycle (enable before sync, disable after if we enabled it)

**Data flow:**
1. `BookMetadata` extracts title, author, ISBN, cover from document
2. `HighlightExtractor` reads annotations from memory (preferred) or disk
3. `SyncService` coordinates upload of highlights, sessions, and files
4. `SessionTracker` stores reading sessions in SQLite (`crossbill_sessions.sqlite3`)

**Book identification:**
- `client_book_id`: MD5 hash of "title|author" - used for server-side deduplication
- `book_file_hash`: MD5 hash of file path - used for local session tracking

## KOReader Integration Points

- Event handlers: `onReaderReady`, `onPageUpdate`, `onSuspend`, `onResume`, `onCloseDocument`, `onExit`
- Menu registration: `addToMainMenu` via `self.ui.menu:registerToMainMenu(self)`
- Settings storage: `G_reader_settings` global
- Document access: `self.ui.document`, `self.ui.annotation`, `self.ui.toc`
