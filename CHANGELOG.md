# Changelog for MishkaDocument 0.0.3

- Needs mishka_gervaz 0.0.10, whose relation selects open through their `.SearchSelect` hook in place of `phx-focus`, and mishka_cms_core 0.0.5-alpha.17. Every dependency is at its latest release, including joken 2.8.0 and mochiweb 3.6.1
- Pages, notes and their drafts keep a version of every edit. The Sections, Section Drafts and Note Drafts screens open a record's version history, and an admin of the section area restores any of its own versions
- The admin documents page reads its cards' health and maintainer figures in one query per page instead of two per card, the figures across the top in three reads instead of eight, and refreshes them once for a burst of document changes
- Needs mishka_cms_core 0.0.5-alpha.13 (a page's event, info and state handlers keep their code signature with `CODE_SIGNING_KEY` set), mishka_gervaz 0.0.8 and guarded_struct 0.1.7. Every dependency is at its latest release, including ash 3.37.4 and spark 2.7.10
- Agent receipts for the document's writes (`MishkaDocument.Plugins.AgentOperations`, on the core's `agent:operations` event): a version's publish, a page draft's and a note draft's review (approved twice, the page or note it writes is read back from the table, by its id or, for a new one, by its version, slug and language or its page and title), and a page's, note's and workspace's create, update, version restore, archive, unarchive and permanent delete, each with its master twin. `MishkaCmsCore.Agent.Receipts.run/3` returns the receipt beside the result. `ReceiptHook` is on `WorkspaceVersion`, `SectionDraft` and `NoteDraft`, and `UiObserver` on the versions, pages, page drafts and note drafts screens

# Changelog for MishkaDocument 0.0.2

- Public slugs of workspaces, sections, section drafts and tags come from `mishka_slug` instead of `ash_slug`: a title keeps the script of the site languages (Persian stays Persian on a site that publishes `fa`), Latin accents become ASCII, `_` stays and `.`, `!`, `?` are dropped. A title in a script the site does not publish is a form error
- The visual editor now comes from the `mishka_cms_builder` package instead of `mishka_cms_core`. The extension runs on `mishka_cms_core` 0.0.4, `mishka_gervaz` 0.0.3 and `mishka_installer` 0.1.15 from Hex
- A `doc-notice` dropped on a page from the palette says "Nothing here yet." instead of drawing an empty box
- A `doc-section` placed on a page whose address names no document draws nothing for a reader. The line that tells the author what the block needs shows only in the editor and the preview
- The example preview no longer allows a WebSocket source when the Host header carries a port above 65535
- The release runs on Erlang 29.1.2 and Elixir 1.20.5. The temporary OTP 29.0.5 pin is gone
- `igniter_js` is 0.5.2 and every dependency is at its latest release, including `phoenix_html` 4.4.0, which fixes a security advisory, and `jose` 1.11.13, which fixes 8 advisories
- Dependencies are audited with `hex.audit` and `deps.audit`, the workflows use a read-only `GITHUB_TOKEN`, and Dependabot runs weekly
- A workspace version set to `:stable` through an update now gets its `published_at` stamped, like a create does, instead of failing validation

# Changelog for MishkaDocument 0.0.1

- Initial version: [mishka.tools/cms](https://mishka.tools/cms)
