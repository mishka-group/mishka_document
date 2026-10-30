# Changelog for MishkaDocument 0.0.2

- The visual editor now comes from the `mishka_cms_builder` package instead of `mishka_cms_core`. The extension runs on `mishka_cms_core` 0.0.3 from Hex
- A `doc-notice` dropped on a page from the palette says "Nothing here yet." instead of drawing an empty box
- A `doc-section` placed on a page whose address names no document draws nothing for a reader. The line that tells the author what the block needs shows only in the editor and the preview
- The example preview no longer allows a WebSocket source when the Host header carries a port above 65535
- The release runs on Erlang 29.1.2 and Elixir 1.20.5. The temporary OTP 29.0.5 pin is gone
- `igniter_js` is 0.5.2 and every dependency is at its latest release, including `phoenix_html` 4.4.0, which fixes a security advisory, and `jose` 1.11.13, which fixes 8 advisories
- Dependencies are audited with `hex.audit` and `deps.audit`, the workflows use a read-only `GITHUB_TOKEN`, and Dependabot runs weekly

# Changelog for MishkaDocument 0.0.1

- Initial version: [mishka.tools/cms](https://mishka.tools/cms)
