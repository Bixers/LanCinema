# 局域影院

An iOS app browsing videos stored on their Windows PC. Targets iPhone with iOS 16 or later; simulator checks use iPhone 17 Pro. Windows root defaults to G:\123 and is selectable in the desktop companion and includes nested folders. The PC runs a read-only HTTP service; iPhone streams files over the LAN. Deliverables are a standalone Windows EXE with tray mode, login autostart and persistent settings, plus an unsigned arm64 IPA built on GitHub Actions macOS. Pairing supports Bonjour discovery plus a password or scanning a connection QR code. Playback defaults to aspect-fill with conservative local black-border analysis; users can switch to full-frame and the preference persists.

Required: recursive folder navigation, name search across the current folder and every descendant, complete wrapping of long file/folder names, in-app playback with broad codec support, persistent playback speed, and press-and-hold temporary speed restored on release/cancellation. VLC is selected for codec compatibility. Lightweight here means a small application layer and no transcoding service; the codec framework contributes substantial binary size.

No file modification, cloud video uploads, user accounts, advertising, or analytics. GitHub receives source code only, not media files or the access code. App UI is Chinese.
