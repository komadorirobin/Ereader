# KOReader patches
KOReader patches, likely not useful for anybody else.

## Automatic installation and updates

Install [Ereader Patch Manager](https://github.com/komadorirobin/ereader-patch-manager.koplugin/releases/latest) to automatically discover, install, and update the numbered patches in this repository. The plugin preserves each patch's enabled or disabled state and creates a backup before replacing an existing file.

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

# [2-footer-margin.lua](https://github.com/komadorirobin/Ereader/blob/main/2-footer-margin.lua)

Makes the manga/comic fill the entire screen beneath the header. Meant to be combined with [2-header-manga.lua](https://github.com/komadorirobin/Ereader/blob/main/2-header-manga.lua). Also meant for screen size 1264 x 1680.

# [2-footer-info-progress.lua](https://github.com/komadorirobin/Ereader/blob/main/2-footer-info-progress.lua)

Custom footer with "Chapter name" in left corner, "Current page/total pages", "Pages left in chapter", "Pages left in book", and "Percentage read" in right corner. Also a thin progress bar beneath.
