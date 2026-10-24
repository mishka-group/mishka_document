<div align="center">

[![Buy Me a Coffee](https://img.shields.io/badge/Buy_Me_a_Coffee-mishkagroup-ffdd00?style=flat-square&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/mishkagroup)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-mishka--group-ea4aaa?style=flat-square&logo=github)](https://github.com/sponsors/mishka-group)

# Mishka Document

**A versioned [documentation engine for Mishka CMS](https://mishka.tools/cms/extensions/documentation), built with Elixir and Phoenix LiveView.**

[Website](https://mishka.tools/cms/extensions/documentation) · [Documentation](https://mishka.tools/cms/extensions/documentation/docs) · [Mishka CMS](https://mishka.tools/cms) · [Hire us](https://mishka.tools/hire-us)

</div>

## 📖 What is Mishka Document?

`mishka_document` is the documentation extension of Mishka CMS. It lets a site publish documentation as documents with several versions, pages that nest inside each other, and notes inside the pages. A change to a page goes through a content review and a technical review before it is applied. Readers can report issues, bookmark pages and follow documents.

The code and the API call a document a workspace. The admin and the website call it a document.

## 🧩 Part of Mishka CMS

Mishka Document is an extension of [Mishka CMS](https://mishka.tools/cms), an open source real-time CMS. It runs on [mishka_cms_core](https://github.com/mishka-group/mishka_cms_core), the engine, inside the [mishka_cms](https://github.com/mishka-group/mishka_cms) application, and it is listed with the other [CMS extensions](https://mishka.tools/cms#extensions).

## ✨ Features

- Documents with a status, SEO tags, Schema.org data and a display order. A document is read at `/docs/<slug>`, or at an address of its own such as `/chelekom/docs`.
- Versions of a document with the statuses draft, alpha, beta, rc, stable and archived. A version can be cloned from an earlier one, the clone history is recorded, and one version is marked latest. Readers switch versions, and `{{doc.version}}` in a page's text shows the version being read.
- Pages that nest to any depth, with notes inside them, and groups that act as headings in the contents. Documents and pages can be translated, and the translations are linked as one.
- A two-stage review. A change to a page or a note is proposed as a draft, and it is applied to the live record once both the content review and the technical review approve it. Each review can approve, reject or ask for a revision.
- Code blocks highlighted when a page is saved, for Elixir, EEx, HEEx, Erlang, HTML, JSON, diff, SQL, JavaScript, TypeScript and CSS.
- Issues on a page or a note: typo, broken link, incorrect content, suggestion, review feedback or other. An issue moves from open to in progress to resolved or closed, and it can have comments.
- Tags for pages, an event log of who changed which record and when, and dashboard widgets for open issues, recent documents, version activity and a summary of documents.
- For readers: bookmarks on pages, follows for documents, and a count of unique views for each page.
- Eleven page components (six blocks that run their own reads and five smaller pieces, including a callout and a live code example) and three sample pages: the documentation index, a document and a document page.
- Drawn in the site's own layout: the sample pages sit between the site's header and footer, in its content column. The header's language switcher lists the languages the document or the page exists in, each at its own address, and a bar under the header holds the trail (Docs, the document, the page) and the version menu.
- SEO for each document and page: its own head, `TechArticle` and breadcrumb JSON-LD, a canonical address, `sitemap.xml` entries and share cards.
- A JSON:API for admins at `/api/json/v1/master/admin/mishka-document/…` and `/api/json/v1/tenant/admin/mishka-document/…`, and one for readers at `/api/json/v1/user/mishka-document/…`, described in the CMS's OpenAPI spec.
- Permissions `admin:dashboard:document:workspace` and `admin:dashboard:document:section`, with `admin:api:` twins for the API.
- Events for plugins, such as `document:workspace_version:after_publish` and `document:issue:after_create`.

## 🚀 Getting started

Mishka Document is installed with [Mishka CMS](https://github.com/mishka-group/mishka_cms#-getting-started). The package is not on Hex. Mishka CMS loads it from `__extensions/mishka_document` when that folder exists, and otherwise from GitHub at the revision pinned in `mix.lock`:

```elixir
{:mishka_document, github: "mishka-group/mishka_document", branch: "master", override: true}
```

Mishka CMS registers it in three places: `MishkaDocument` in `ash_domains` and `MishkaDocumentWeb` in the core's `extensions` list, both in `config/config.exs`, and `MishkaDocument` in the domains of the JSON:API router.

Then install the documentation onto a site. Tick Documentation in the install wizard, or open the Documents dashboard of a site that does not have it yet and press Set up. Either way the site gets the eleven components, the three sample pages and a snippet that lists the latest documents. Running it again adds only what is missing and leaves anything you edited. Newer components and sample pages are offered on the Documentation components card, and only the ones you choose are written.

For sample documents, versions and issues in development, run `mix run priv/repo/dev_seeds.exs` in `mishka_cms`.

## 📚 Documentation

- [Mishka Document documentation](https://mishka.tools/cms/extensions/documentation/docs), which is still being written
- [Features](https://mishka.tools/cms/extensions/documentation#features), the [two-stage review](https://mishka.tools/cms/extensions/documentation#workflow), [SEO](https://mishka.tools/cms/extensions/documentation#seo), [plugin events](https://mishka.tools/cms/extensions/documentation#events) and the [REST API](https://mishka.tools/cms/extensions/documentation#api)
- [Mishka CMS documentation](https://mishka.tools/cms/docs)
- [Mishka Installer documentation](https://mishka.tools/installer/docs), for plugins and events
- The [Mishka blog](https://mishka.tools/blog)

## 💬 Community and support

- Report a bug or ask a question in [GitHub issues](https://github.com/mishka-group/mishka_document/issues).
- Read about new releases on the [Mishka blog](https://mishka.tools/blog).
- For a custom documentation feature, a migration from another system or priority support, [hire the Mishka team](https://mishka.tools/hire-us).

## 💖 Support the project

Mishka CMS and its extensions are free and open source. You can support their development through [GitHub Sponsors](https://github.com/sponsors/mishka-group) or [Buy Me a Coffee](https://www.buymeacoffee.com/mishkagroup).

## 📜 License

Apache License 2.0. See [LICENSE](LICENSE).
