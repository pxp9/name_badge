# Typst NIF Memory Leak Fix

## Problem Summary

The Typst Elixir NIF wrapper (`Hermanverschooten/typst`) has a memory leak that causes RSS (Resident Set Size) to grow continuously over time, eventually crashing the device. The BEAM memory (`:erlang.memory()`) stays stable, but RSS grows because the leak occurs in native Rust code outside the BEAM's visibility.

## Root Cause Analysis

The leak is in the NIF wrapper's usage pattern, **not** in the Typst Rust library itself.

### Location

File: `native/typst_nif/src/lib.rs`

### The Problem

Every call to `compile_png` or `compile_pdf` creates a **new `TypstNifWorld`**:

```rust
#[rustler::nif]
fn compile_png<'a>(...) -> Result<Vec<Binary<'a>>, String> {
    let world = TypstNifWorld::new(root_dir, markup, extra_fonts);  // <-- NEW WORLD EVERY CALL
    // ...
}
```

The `TypstNifWorld::new()` function scans all system fonts on every invocation:

```rust
impl TypstNifWorld {
    pub fn new(root: String, source: String, extra_fonts: Vec<String>) -> Self {
        let fonts = Fonts::searcher()
            .include_system_fonts(true)   // <-- Scans ALL system fonts EVERY call
            .search_with(extra_fonts);    // <-- Loads font metadata EVERY call
        // ...
    }
}
```

### Why This Causes a Leak

1. **Font scanning is expensive**: Each call loads font metadata from disk
2. **Internal caching**: The `typst-kit` and `comemo` crates cache data internally in static memory
3. **Cache accumulation**: When a new `World` is created, old cached data may not be properly released
4. **Designed for reuse**: Typst expects a `World` to be created once and reused for multiple compilations

### Evidence

- RSS grows ~3-4 MB every few minutes during normal operation
- BEAM memory (`:erlang.memory()`) stays flat
- The official `typst-cli` creates one world and reuses it

## The Fix

Cache the fonts globally using `OnceLock` so they are only loaded once per unique set of font paths.

### Changes Required

#### 1. Add imports and cache structure

At the top of `native/typst_nif/src/lib.rs`, add:

```rust
use std::sync::OnceLock;  // Add to existing sync imports

/// Global cache for fonts to avoid repeated filesystem scanning.
/// The key is a sorted, joined string of extra_fonts paths.
/// This prevents memory leaks from repeatedly loading font metadata.
static FONTS_CACHE: OnceLock<Mutex<HashMap<String, Arc<CachedFonts>>>> = OnceLock::new();

/// Cached font data that can be shared across TypstNifWorld instances.
struct CachedFonts {
    book: LazyHash<FontBook>,
    fonts: Vec<FontSlot>,
}

fn get_fonts_cache() -> &'static Mutex<HashMap<String, Arc<CachedFonts>>> {
    FONTS_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Get or create cached fonts for the given extra_fonts paths.
fn get_or_create_fonts(extra_fonts: &[String]) -> Arc<CachedFonts> {
    let cache = get_fonts_cache();
    
    // Create a cache key from sorted extra_fonts paths
    let mut sorted_fonts = extra_fonts.to_vec();
    sorted_fonts.sort();
    let cache_key = sorted_fonts.join("|");
    
    let mut cache_guard = cache.lock().unwrap();
    
    if let Some(cached) = cache_guard.get(&cache_key) {
        return Arc::clone(cached);
    }
    
    // Fonts not cached, scan and store
    let fonts = Fonts::searcher()
        .include_system_fonts(true)
        .search_with(extra_fonts.to_vec());
    
    let cached = Arc::new(CachedFonts {
        book: LazyHash::new(fonts.book),
        fonts: fonts.fonts,
    });
    
    cache_guard.insert(cache_key, Arc::clone(&cached));
    cached
}
```

#### 2. Modify `TypstNifWorld` struct

Replace the `book` and `fonts` fields with a single `cached_fonts` field:

```rust
pub struct TypstNifWorld {
    root: PathBuf,
    source: Source,
    library: LazyHash<Library>,
    
    // CHANGED: Use cached fonts instead of per-instance fonts
    cached_fonts: Arc<CachedFonts>,  // Was: book: LazyHash<FontBook>, fonts: Vec<FontSlot>
    
    files: Arc<Mutex<HashMap<FileId, FileEntry>>>,
    cache_directory: PathBuf,
    http: ureq::Agent,
    time: time::OffsetDateTime,
}
```

#### 3. Modify `TypstNifWorld::new()`

Replace the font loading logic:

```rust
impl TypstNifWorld {
    pub fn new(root: String, source: String, extra_fonts: Vec<String>) -> Self {
        let root = PathBuf::from(root);
        
        // CHANGED: Use cached fonts to prevent memory leaks
        let cached_fonts = get_or_create_fonts(&extra_fonts);

        Self {
            library: LazyHash::new(Library::default()),
            cached_fonts,  // CHANGED: was book and fonts
            root,
            source: Source::detached(source),
            time: time::OffsetDateTime::now_utc(),
            cache_directory: std::env::var_os("CACHE_DIRECTORY")
                .map(|os_path| os_path.into())
                .unwrap_or(std::env::temp_dir()),
            http: ureq::Agent::new(),
            files: Arc::new(Mutex::new(HashMap::new())),
        }
    }
}
```

#### 4. Update `World` trait implementation

Update the `book()` and `font()` methods to use the cached fonts:

```rust
impl typst::World for TypstNifWorld {
    // ... other methods unchanged ...

    fn book(&self) -> &LazyHash<FontBook> {
        &self.cached_fonts.book  // CHANGED: was &self.book
    }

    fn font(&self, id: usize) -> Option<Font> {
        self.cached_fonts.fonts[id].get()  // CHANGED: was self.fonts[id].get()
    }
    
    // ... other methods unchanged ...
}
```

## Complete Diff

```diff
diff --git a/native/typst_nif/src/lib.rs b/native/typst_nif/src/lib.rs
--- a/native/typst_nif/src/lib.rs
+++ b/native/typst_nif/src/lib.rs
@@ -1,6 +1,6 @@
 use std::collections::HashMap;
 use std::path::PathBuf;
-use std::sync::{Arc, Mutex};
+use std::sync::{Arc, Mutex, OnceLock};
 
 use rustler::{Binary, Env, NewBinary, Term};
 use typst::diag::{
@@ -17,6 +17,42 @@ use typst::{Library, LibraryExt};
 use typst_kit::fonts::{FontSlot, Fonts};
 use typst_pdf::PdfOptions;
 
+/// Global cache for fonts to avoid repeated filesystem scanning.
+static FONTS_CACHE: OnceLock<Mutex<HashMap<String, Arc<CachedFonts>>>> = OnceLock::new();
+
+/// Cached font data that can be shared across TypstNifWorld instances.
+struct CachedFonts {
+    book: LazyHash<FontBook>,
+    fonts: Vec<FontSlot>,
+}
+
+fn get_fonts_cache() -> &'static Mutex<HashMap<String, Arc<CachedFonts>>> {
+    FONTS_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
+}
+
+fn get_or_create_fonts(extra_fonts: &[String]) -> Arc<CachedFonts> {
+    let cache = get_fonts_cache();
+    
+    let mut sorted_fonts = extra_fonts.to_vec();
+    sorted_fonts.sort();
+    let cache_key = sorted_fonts.join("|");
+    
+    let mut cache_guard = cache.lock().unwrap();
+    
+    if let Some(cached) = cache_guard.get(&cache_key) {
+        return Arc::clone(cached);
+    }
+    
+    let fonts = Fonts::searcher()
+        .include_system_fonts(true)
+        .search_with(extra_fonts.to_vec());
+    
+    let cached = Arc::new(CachedFonts {
+        book: LazyHash::new(fonts.book),
+        fonts: fonts.fonts,
+    });
+    
+    cache_guard.insert(cache_key, Arc::clone(&cached));
+    cached
+}
+
 pub struct TypstNifWorld {
     root: PathBuf,
     source: Source,
     library: LazyHash<Library>,
-    book: LazyHash<FontBook>,
-    fonts: Vec<FontSlot>,
+    cached_fonts: Arc<CachedFonts>,
     files: Arc<Mutex<HashMap<FileId, FileEntry>>>,
     cache_directory: PathBuf,
     http: ureq::Agent,
@@ -26,14 +62,11 @@ pub struct TypstNifWorld {
 impl TypstNifWorld {
     pub fn new(root: String, source: String, extra_fonts: Vec<String>) -> Self {
         let root = PathBuf::from(root);
-        let fonts = Fonts::searcher()
-            .include_system_fonts(true)
-            .search_with(extra_fonts);
+        let cached_fonts = get_or_create_fonts(&extra_fonts);
 
         Self {
             library: LazyHash::new(Library::default()),
-            book: LazyHash::new(fonts.book),
-            fonts: fonts.fonts,
+            cached_fonts,
             root,
             source: Source::detached(source),
             time: time::OffsetDateTime::now_utc(),
@@ -50,7 +83,7 @@ impl typst::World for TypstNifWorld {
     }
 
     fn book(&self) -> &LazyHash<FontBook> {
-        &self.book
+        &self.cached_fonts.book
     }
 
     fn main(&self) -> FileId {
@@ -69,7 +102,7 @@ impl typst::World for TypstNifWorld {
     }
 
     fn font(&self, id: usize) -> Option<Font> {
-        self.fonts[id].get()
+        self.cached_fonts.fonts[id].get()
     }
 
     fn today(&self, offset: Option<i64>) -> Option<Datetime> {
```

## Testing the Fix

### Build the NIF

```bash
cd native/typst_nif
cargo build --release
```

### Run a stress test

```elixir
# Before fix: RSS grows continuously
# After fix: RSS should stabilize after first call

initial_rss = NameBadge.Telemetry.MemoryMonitor.snapshot().rss

Enum.each(1..100, fn i ->
  Typst.render_to_png!("#set page(width: 100pt, height: 100pt)\nTest #{i}", [])
  if rem(i, 25) == 0 do
    current_rss = NameBadge.Telemetry.MemoryMonitor.snapshot().rss
    IO.puts("Iteration #{i}: RSS = #{div(current_rss, 1024 * 1024)} MB")
  end
end)

final_rss = NameBadge.Telemetry.MemoryMonitor.snapshot().rss
IO.puts("RSS delta: #{div(final_rss - initial_rss, 1024 * 1024)} MB")

# Expected: RSS delta should be minimal (< 5 MB) after 100 iterations
# Before fix: RSS delta was 10+ MB and growing linearly
```

## Alternative Considerations

### Option A: Reuse the entire World (more aggressive)

Instead of just caching fonts, cache the entire `TypstNifWorld` and only update the `source` field. This would be more efficient but requires more changes:

```rust
static WORLD_CACHE: OnceLock<Mutex<HashMap<String, Arc<Mutex<TypstNifWorld>>>>> = OnceLock::new();
```

This is more complex because the `World` contains mutable state (`files` HashMap) that may need clearing between calls.

### Option B: Add a NIF to clear caches

Add a new NIF function to explicitly clear caches when needed:

```rust
#[rustler::nif]
fn clear_font_cache() -> Atom {
    if let Some(cache) = FONTS_CACHE.get() {
        cache.lock().unwrap().clear();
    }
    atoms::ok()
}
```

This allows the Elixir side to periodically clear memory if needed.

## PR Checklist

- [ ] Apply the diff to `native/typst_nif/src/lib.rs`
- [ ] Run `cargo build --release` and verify it compiles
- [ ] Run `cargo test` if tests exist
- [ ] Test with the stress test script above
- [ ] Verify RSS stabilizes after initial font loading
- [ ] Update CHANGELOG.md
- [ ] Create PR to `Hermanverschooten/typst`

## References

- Issue discovery: RSS monitoring showed growth while BEAM memory stayed flat
- Typst CLI reference: https://github.com/typst/typst/blob/main/crates/typst-cli/src/main.rs (creates one world, reuses it)
- Related crates: `typst-kit` (font loading), `comemo` (memoization/caching)
