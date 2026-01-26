<p align="center">

<img width="96" height="96" alt="image" src="https://github.com/user-attachments/assets/6461072f-2265-443b-a018-db7ae26cb42f" />
</p>

# Crossbill KOReader Plugin

Syncs your KOReader highlights to your Crossbill server.

## Installation

1. Copy the `crossbill.koplugin` directory to your KOReader plugins folder:
   - **Device**: `koreader/plugins/`
   - **Desktop**: `.config/koreader/plugins/` (Linux/Mac) or `%APPDATA%\koreader\plugins\` (Windows)

2. Restart KOReader

3. Open any book and go to: Menu → crossbill Sync → Configure Server

4. Enter your Crossbill server host URL (e.g., `http://192.168.1.100:8000`)

## Usage

1. Open a book with highlights
2. Menu → Crossbill Sync → Sync Current Book
3. View your synced highlights on your crossbill server

## Features

- Syncs highlights from the currently open book
- Uploads book cover and epub to the Crossbill
- Uploads reading session data to the Crossbill
- Works with EPUB files

## Requirements

- Network connection to your Crossbill server

## Tested devices

While the plugin _should_ work on any device running KOReader, it has been specifically tested on:

- Pocketbook Era

## Server Configuration

The default server URL is `http://localhost:8000`. You'll need to change this to your actual Crossbill server host address.

## Development

You can use `copy_to_pocketbook.sh` script to copy the plugin to a connected Pocketbook device for testing by creating `.env`file
with your unique path to the device's Koreader plugins folder. The script copies the plugin both as a "production" version and
as a "development" version letting you to use different server configuration for local testing and production.
