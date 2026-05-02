//// Buffer state lookup with disk fallback.
////
//// Single entry point used by tools that need current file content:
//// asks the bridge for unsaved buffer text when the extension is
//// available, falls back to reading from disk otherwise.
////
//// Caches results within a single tool call to avoid redundant
//// fetches when multiple sub-operations touch the same file.
////
//// Stub — buffer reader lands in Milestone 7.
