# Updates

Oatcake looks for a new release 20 seconds after it opens and then once a day (Settings ›
Updates can turn that off, and has **Check now**; a development copy only checks when asked).
A new release shows in the sidebar above Settings; **Update…** asks, then downloads it, checks
it, and quits and reopens Oatcake on the new version. Settings › Updates shows what's new in it,
with its own **Install and relaunch…**, which asks the same question. It won't start while a call is being recorded or
analysed, a summary, a draft for sharing or an answer is being written, or meetings are being
imported, nor while it would lose edits that couldn't be saved or notes typed for a call that
couldn't be recorded: it says so, and you try again afterwards. Edits waiting to be saved are
saved first. Nothing is installed until you click.

Each release carries `latest.json`, a manifest naming the version and its zip (address,
SHA-256, size), signed with Oatcake's Ed25519 release key. Oatcake checks that signature
against the public keys it ships (`Update.publicKeys`), checks the zip's size and
checksum, unpacks it with `ditto`, checks it's Oatcake at that version, and checks the new app
is signed with the same certificate as the running one (`codesign --verify --deep --strict -R`
with the running app's designated requirement). The new copy is staged next to the installed
one (and removed again if the swap can't be started); a small detached script waits for Oatcake
to quit, swaps the two, and opens it. Its log is
`~/Library/Application Support/Oatcake/update.log`. The mechanics are in
`Sources/OatcakeCore/Update.swift`.

A copy that can't replace itself says why in Settings: a development copy, one macOS is running
from a quarantined download (move it to Applications), one built without the release
certificate, or one in a folder you can't write to. For the last two it offers the install line
instead. Oatcake also remembers the newest release it has been offered, and treats a feed that
later names an older one as an error rather than as "up to date".
