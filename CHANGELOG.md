# CHANGELOG

## Unreleased

- Fix `vtab-hide-scroll-bars` so nil shows a vertical scrollbar in the side window.
- Fix `vtab-active-fill-width` so the active row uses the extending face, including the final tab.
- Fix full-width active tabs so short labels do not show Emacs' truncation marker or trigger horizontal scrolling, while long labels still show `$`.

## v1.1.0

- Add defcustom for window-divider and fringe styling control

## v1.0.0

- Initial release
- Vertical tab bar display in a side window
- Tab selection, creation, closing via keybindings
- Per-frame tab state support
