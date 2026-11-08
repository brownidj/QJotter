# Deleting notes

Updated 9 November 2026, build 14.

All deletion entry points (toolbar trash, note actions, and desktop Delete or
Backspace in the list) ask “Are you sure?” before making a change. Cancel or
closing the dialog leaves the note intact. Confirmation removes the captured
note, even if sync changes the selected note while the dialog is open; switching
accounts invalidates the pending confirmation.

There is no deletion snackbar or Undo action. List deletion keeps the list and
search open. Other notes remain available. Deleting the final note leaves zero
notes, including after saving, reopening and sync. Typing on the empty capture
page creates a note; + explicitly creates a blank note as before.

Existing blank notes are not automatically purged. They can be deleted using
the same confirmation flow.

Validation: all 83 Flutter tests pass and Flutter analysis is clean. The final
notes UI suite also passes (18 cases). Mac debug and iOS Profile builds succeed.
iOS build 14 was installed on device 00008110-001E48A02187601E and launched
without a debugger. The running Mac session needs restarting to load the build.
