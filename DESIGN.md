# Native iOS design

Mode: Operate in the library and connection settings; Experience during playback.

Use UIKit navigation, inset grouped file lists, SF Symbols, semantic system colors, system Dynamic Type and standard back gestures. Browser follows the device's light/dark appearance. Playback remains black for video letterboxing with legible dark controls. Teal is the single interaction accent; playback uses its brighter mint variant for contrast.

Top-level library has a collapsing large title. Nested folders use inline titles. Row content prioritizes full filename, then file size and progress; filename labels wrap without a line cap and rows grow with content. Search covers the current subtree, with a wrapping parent-path line for disambiguating duplicate names. Folder disclosure and icons distinguish directories without relying on color alone.

Controls stay inside safe areas, including landscape. Targets are at least 44 points. Standard menu contains persistent speeds and a separate hold-speed setting. Holding the canvas for 350 ms activates the temporary speed; release, cancellation, app interruption and dismissal restore the selected speed. Seeking and buttons have separate touch regions.

No hero marketing layout, display web fonts, decorative gradients, poster placeholders, or web UI wrappers. Captures must come from the built iOS simulator; browser mockups are not evidence of native rendering.

Connection extends the native visual system: a scrollable form with persistent Password / QR segments, labeled address and password fields, visibility toggle, inline failures, and a primary Connect action. Bonjour discovery never broadcasts credentials. Scanning uses the native camera or a system photo picker.

Desktop settings use a restrained light surface, teal primary action, system Chinese typography, labeled inputs, wrapping directory preview, a single Save and apply button, and a connection QR panel. Closing keeps the tray service alive; an explicit tray command stops it. Save failures preserve editable fields and report recovery.

Playback adds a 48-point display-mode control beside the title, retaining safe-area controls and native action sheets. Default fill preserves proportions; full-frame mode keeps all content. Embedded black-border analysis is local and can be bypassed with full-frame mode.

Playback input lives on a transparent surface above the VLC drawable and below the controls. A tap toggles both bars; playing without input hides them after four seconds. A horizontal pan previews the target and signed time difference in a centered dark overlay, committing only on release. A full-width drag covers 30–120 seconds depending on duration, bounded to the media timeline. Vertical pans do not seek. Holding still activates temporary speed; moving horizontally before the hold threshold seeks instead. Paused seeks retain their requested time until VLC acknowledges the clock; resuming is validated against advancing decoder time. Cancelled gestures discard the preview. The standard slider and buttons remain available alongside gestures.
