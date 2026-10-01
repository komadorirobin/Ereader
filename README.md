# KOReader patches
KOReader patches, likely not useful for anybody else.

## Automatic installation and updates

Install [Ereader Patch Manager](https://github.com/komadorirobin/ereader-patch-manager.koplugin/releases/latest) to automatically discover, install, and update the numbered patches in this repository. The plugin preserves each patch's enabled or disabled state and creates a backup before replacing an existing file.

## [2-bookorbit-undo-opening.lua](2-bookorbit-undo-opening.lua)

Undo a newly opened, unread book before the first page turn (within 24 hours),
including its provisional BookOrbit reading and the specific Hardcover reading
created for that opening. Existing readings, progress and annotations are not
eligible for reset. Ratings, reviews, metadata and edition links are preserved.

This is a standalone user patch, **not a fork of `bookorbit.koplugin`**. It wraps
the stock plugin's lifecycle and API methods in memory; it neither replaces its
files nor copies its sync engine. It also works when the book was opened from
Bookshelf or SimpleUI because it observes KOReader's reader lifecycle.

### Requirements and use

1. Deploy the [BookOrbit server support](server-support/bookorbit-undo-opening/README.md)
   first: migration `0101_undo_reading_opening`
   and the authenticated `/api/v1/koreader/plugin/openings`, `/commit` and `/undo`
   endpoints. This is separate server work, not something a device patch installs.
2. Keep the official BookOrbit plugin enabled and configured for automatic sync.
   Keep BookOrbit as the only automatic Hardcover writer, using the Hardcover
   sync patch below if the separate Hardcover plugin is installed.
3. Sync patches in Patch Manager, enable this patch if necessary, and restart
   KOReader. Alternatively, install this file in `koreader/patches/` manually.
4. Use **Tools > BookOrbit > Undo accidental opening** while eligible. It is also
   in BookOrbit's dashboard menu and available as the gesture action
   **BookOrbit: undo accidental opening**. It does not add a Bookshelf-only menu.

The client holds automatic uploads for the provisional opening until you turn a
page or explicitly sync that book. A whole-library sweep waits while an opening
is held; sync for other individual books is unaffected. After a successful undo,
the book returns to its previous unread state/history position. KOReader's local
statistics database is not erased, but the accidental time interval is excluded
from future BookOrbit uploads, including full sweeps.

An unsent offline opening can be undone locally. If a request may already have
reached the server, it must be reconciled before local data is reset. A pending
undo can be retried explicitly after reconnecting. If Hardcover is unavailable,
the server keeps the owned reading ID for retry; it never guesses which reading
to delete. Older readings or later edits from another device prevent remote
undo. The server does not create a first-ever Hardcover library entry just for
a provisional opening; normal sync can do that after reading continues.

### Updates and safety

Tested against stock BookOrbit plugin **1.5.5**, repository commit
`2855dbb8a39d20bf711f01772e2678ef0625dd63`. Compatibility checks fingerprint the
nine source files involved in lifecycle, queues and API acknowledgement. The
version literal is ignored: a version-only bump or changes outside those files
need no patch update. Changes inside them require review and regression tests;
even a harmless edit may conservatively trigger the guard. Never just regenerate
the fingerprints to silence the warning.

The guard runs **before plugin initialization**, before startup uploads can run.
For unknown code with no protected state, ordinary BookOrbit sync still works
but undo is unavailable. If a pending opening or excluded statistics exist,
BookOrbit is paused instead; KOReader and other plugins remain usable. Update
the patch with Patch Manager and restart once compatibility has been verified.

**Do not delete the `bookorbit_openings` setting or disable/remove this patch
without reconciling its state.** Its per-account excluded intervals must survive
plugin updates and sync-state rebuilds to prevent old accidental statistics
being uploaded again. Unreadable state also pauses BookOrbit rather than ignoring
the protection. Against a server without the new endpoints, the client releases
its provisional hold and falls back to ordinary sync; remote undo is unavailable.

Tests run without network, credentials, or user data. The adapter test loads real,
unmodified upstream source and verifies hashes, callable event handlers, menus,
queue completion, upload filtering, offline recovery and compatibility gating:

```sh
luajit tests/bookorbit_undo_state_test.lua
luajit tests/bookorbit_undo_patch_test.lua /path/to/bookorbit.koplugin
```

## [2-hardcover-bookorbit-sync.lua](https://github.com/komadorirobin/Ereader/blob/main/2-hardcover-bookorbit-sync.lua)

Use BookOrbit as the only automatic reading-sync source for Hardcover. Keep
KOReader-to-BookOrbit sync and BookOrbit's Hardcover status/progress sync enabled.
This patch requires the separate `hardcoverapp.koplugin` to remain enabled for
Bookshelf's Hardcover integration.

- Blocks the Hardcover plugin's automatic progress and status sync, including
  existing books with individual tracking enabled and the end-of-book check.
- Preserves Bookshelf's links, edition-ID auto-linking, metadata and ratings.
- Keeps the Hardcover plugin's own linking/edition selection local instead of
  writing the selected edition and current reading status back to Hardcover.
- Shows `Automatic reading sync: BookOrbit` in the Hardcover menu and disables
  its automatic tracking controls. Explicit manual Hardcover status/rating
  actions remain available; use BookOrbit for those too if you want one writer.
- Does not modify saved tracking preferences or remove existing duplicate reads.

Sync patches in Patch Manager, enable this patch if necessary, and restart
KOReader. To restore the old behavior, disable this patch and restart again.
There is no effect when the Hardcover plugin is absent or disabled.

Regression tests (using a local copy of Billiam's plugin, without network or a token):

```sh
luajit tests/hardcover_bookorbit_sync_test.lua /path/to/hardcoverapp.koplugin
```

# [2-custom-reader-header.lua](https://github.com/komadorirobin/Ereader/blob/main/2-custom-reader-header.lua)

Adds a custom header with "Author – Title" in left corner and "Battery % | Clock" in right corner. Needs localization if you're not Swedish. It also comes with a few folder rules which, again, is (likely) not useful for anybody else.

# [2-header-manga.lua](https://github.com/komadorirobin/Ereader/blob/main/2-header-manga.lua)

Same as the above, but smaller font and with "current page/total pages" and "pages left", as well as an added thin line beneath 

Long author/title text is truncated with an ellipsis to fit the space left by the
status information, with a gap between the two blocks. A trailing volume label
(such as `Vol. 5` or `Volume 12`) has priority over the author/title: its measured
width is reserved first, so it remains visible when the title is truncated.
If the whole left-hand area runs out of space, only the status is shown. The white
background and bookmark ribbon are unchanged.

Header regression tests (mocked KOReader APIs, no device required):

```sh
luajit tests/manga_header_test.lua
```

# [2-footer-margin.lua](https://github.com/komadorirobin/Ereader/blob/main/2-footer-margin.lua)

Makes the manga/comic fill the entire screen beneath the header. Meant to be combined with [2-header-manga.lua](https://github.com/komadorirobin/Ereader/blob/main/2-header-manga.lua). Also meant for screen size 1264 x 1680.

# [2-footer-info-progress.lua](https://github.com/komadorirobin/Ereader/blob/main/2-footer-info-progress.lua)

Custom footer with "Chapter name" in left corner, "Current page/total pages", "Pages left in chapter", "Pages left in book", and "Percentage read" in right corner. Also a thin progress bar beneath.
