# Lock screens, display sleep, and unattended access

Normal macOS password-lock capture and remote unlocking require validation on the target Macs. Saved pairing and a connected transport do not establish that a protected screen can be captured or accept remote input.

## Current behavior

- The host explicitly enables sharing in its logged-in user session.
- While sharing is available, an idle-system-sleep assertion tries to keep the host running. Its display can sleep and its normal password-lock policy still applies.
- **Wake Display** requests display activity. It does not authenticate the user or remove the password requirement.
- **End viewing** pauses capture and releases held input while preserving the authenticated connection. **Resume** requests a fresh capture generation.
- Blank, suspended, and stopped capture invalidate cached images and the prior capture generation. The viewer clears stale video and disables ordinary input until a current frame is available.
- **Open FarReach when I log in** starts the GUI app after login. It does not start sharing automatically or run before FileVault unlock.

## Support boundaries

| Host state | Status |
| --- | --- |
| Logged-in, unlocked, awake | Normal desktop use; verify permissions and connectivity. |
| Display asleep but system awake | A display-wake request is implemented; verify a fresh image on the target Mac. |
| Screen saver or ordinary password lock | Capture and input are separate compatibility checks; remote unlock is unverified. |
| Whole-system sleep, closed lid, low battery, or powered off | Access is not guaranteed. There is no independent Wake-on-LAN implementation. |
| Logout or another user’s session | Access is not supported by the current GUI-session design. |
| FileVault preboot | Unsupported. |

FarReach does not store or autofill the Mac login password. If you choose to enter it remotely, do so only when the current lock screen is visibly available. Its input events use the authenticated desktop connection, not signaling. Do not put passwords in diagnostics, test fixtures, or issue reports.

## Two-Mac validation

Keep a local way to recover access and test each case separately:

1. Pair while unlocked, close the viewer connection, and reconnect through your configured signaling service.
2. Start a screen saver and verify capture/input with the configured password policy.
3. Lock an already connected session. Verify the current lock screen appears or capture is explicitly unavailable; a stale desktop must not appear live.
4. Disconnect and reconnect while locked. Starting capture in that state is a separate test.
5. If a current password screen appears, enter the password yourself and verify return to the desktop. Do not record the input.
6. Let only the display sleep, use **Wake Display**, and verify a new image without changing the password policy.
7. Confirm Stop Sharing, logout, quit, and reboot terminate the expected access. Restarting FarReach must require explicit host sharing again.

Passing screen-saver or display-wake checks does not establish password-lock, login-window, or FileVault support. See [validation](ACCEPTANCE.md) and the [security model](SECURITY.md).
