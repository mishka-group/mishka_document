defmodule MishkaDocument.Dev.Seeds do
  @moduledoc """
  Dev seeds for MishkaDocument.

  Models a realistic documentation lifecycle for five MishkaCMS products:
  Mishka CMS, Mishka Gervaz, Mishka Installer, GuardedStruct and Mishka
  Chelekom. Each product has an English canonical workspace — the master —
  plus one translated workspace per entry in its `:translations` list,
  linked to the master via `language_group_id`. Persian, French and Arabic
  editions carry translated names, descriptions and section titles; note
  bodies outside Persian reuse the English copy.

  Every product aims at a different completion band, so the admin card grid
  renders each colour: Mishka CMS 100 (blue), Mishka Gervaz 90 (green),
  Mishka Installer 65 (indigo), GuardedStruct 40 (amber) and Mishka
  Chelekom 15 (red).

  Each English workspace progresses through six versions (0.0.1 → 0.0.6)
  using the version system — not separate workspaces; translated workspaces
  get three (0.0.1 → 0.0.3). Later versions clone sections from earlier ones
  (`source_section_id` + shared `section_lineage_id`) and record the clone
  relationship in `WorkspaceVersionLineage`. A translated section joins the
  language group of the English section holding the same position in the
  version of the same number, so `read :language_variants` has data at the
  section level too.

  Drafts live only on the latest stable English version (0.0.6), covering a
  new chapter, an edit and a rewrite; a third of them reach `applied_at`, and
  two note drafts hang off a sibling section draft rather than a live section.
  Twenty issues are spread over sections and notes — a quarter of them on a
  translated workspace — with long-tailed comment threads, the longest on the
  ones that end up resolved or closed. When a master is among the users, about
  one comment in five is theirs, so a tenant admin sees comments it can read but
  not edit or delete.

  Views, bookmarks and follows are seeded so the reader-facing counters are not
  uniformly zero; those three carry their real creation time rather than a
  backdated one.

  ## Review status

  A section, note or draft carries two independent review axes, and completion
  is the share of a workspace's items where *both* are approved. One stable hash
  per item decides full approval at the product's target rate, so the
  100/90/65/40/15 bands land exactly; a second hash gives every other item a
  divergent pair — content approved while technical is still pending is the
  ordinary mid-review state — and sends a fifth of them to `:rejected` or
  `:needs_revision` so the Sections filters and the draft `:draft_applied`
  column have rows in every branch. `:archived` is never written here: the
  destroy action force-sets both fields when a section or note is soft deleted.

  ## Archived vs. archived

  `archived_at` (AshArchival soft delete, what the admin Archived tab filters
  on) and a `status` of `:archived` are separate things. The seed only ever
  reaches the first one through `Ash.destroy!/2` on the archival `:destroy`
  action, which force-sets `status`/`content_review_status`/
  `technical_review_status` to `:archived` by itself on the resources that have
  such a field. No workspace is created carrying the `:archived` label alone —
  `MishkaDocumentWeb.Templates.DocumentCard.archived?/1` matches the status
  before it looks at `archived_at`, so such a row would render as archived while
  still sitting in the Active tab. `MishkaDocument.WorkspaceVersion` is the one
  place where the label is the whole story: it has no `archived_at` at all, and
  versions 0.0.1 → 0.0.3 keep `status: :archived`.

  Archiving runs last, after every create, status transition and timestamp
  backdate. `prevent_archived_*_updates` raises on any update of a row that is
  already archived, and no resource declares `archive_related`, so children are
  archived before parents and language masters are never archived while a live
  translation still points at them.
  """

  alias MishkaCmsCore.Dev.Seeds
  alias MishkaDocument.Workspace
  import MishkaDocument.Dev.Generator

  require Ash.Query

  @products [
    %{
      slug_base: "mishka-cms",
      en_name: "Mishka CMS",
      en_desc:
        "A modular, extensible content management system built on Elixir, Phoenix, and the Ash framework.",
      completion: 100,
      translations: [
        %{
          language: "fa",
          name: "میشکا سی ام اس",
          desc:
            "یک سیستم مدیریت محتوای ماژولار و توسعه‌پذیر که با Elixir، Phoenix و فریم‌ورک Ash ساخته شده است."
        },
        %{
          language: "fr",
          name: "Mishka CMS",
          desc:
            "Un système de gestion de contenu modulaire et extensible, bâti sur Elixir, Phoenix et le framework Ash."
        },
        %{
          language: "ar",
          name: "ميشكا سي إم إس",
          desc: "نظام إدارة محتوى معياري وقابل للتوسيع، مبني على Elixir وPhoenix وإطار عمل Ash."
        }
      ]
    },
    %{
      slug_base: "mishka-gervaz",
      en_name: "Mishka Gervaz",
      en_desc: "A declarative DSL for generating admin forms and tables on top of Ash resources.",
      completion: 90,
      translations: [
        %{
          language: "fa",
          name: "میشکا گرواز",
          desc: "یک DSL اعلانی برای تولید فرم‌ها و جدول‌های مدیریتی بر پایه منابع Ash."
        }
      ]
    },
    %{
      slug_base: "mishka-installer",
      en_name: "Mishka Installer",
      en_desc:
        "Runtime plugin and extension installer for Elixir applications, with zero-downtime reloads.",
      completion: 65,
      translations: [
        %{
          language: "fa",
          name: "میشکا اینستالر",
          desc:
            "نصب‌کننده افزونه و اکستنشن در زمان اجرا برای برنامه‌های Elixir، با بارگذاری بدون توقف."
        },
        %{
          language: "fr",
          name: "Mishka Installer",
          desc:
            "Installateur de plugins et d'extensions à l'exécution pour les applications Elixir, avec rechargement sans interruption de service."
        }
      ]
    },
    %{
      slug_base: "guarded-struct",
      en_name: "GuardedStruct",
      en_desc:
        "Macros for declaring validated, type-safe structs with derive rules, sanitizers, and conditional fields.",
      completion: 40,
      translations: [
        %{
          language: "fa",
          name: "گاردد استراکت",
          desc:
            "ماکروهایی برای تعریف ساختارهای اعتبارسنجی‌شده و ایمن از نوع با قوانین، پاک‌کننده‌ها و فیلدهای شرطی."
        }
      ]
    },
    %{
      slug_base: "mishka-chelekom",
      en_name: "Mishka Chelekom",
      en_desc:
        "A Phoenix component library of accessible, themeable UI primitives generated straight into your app.",
      completion: 15,
      translations: [
        %{
          language: "fa",
          name: "میشکا چلکم",
          desc:
            "کتابخانه کامپوننت فینیکس با المان‌های رابط کاربری دسترس‌پذیر و پوسته‌پذیر که مستقیماً درون برنامه شما تولید می‌شوند."
        },
        %{
          language: "ar",
          name: "ميشكا تشيليكوم",
          desc:
            "مكتبة مكوّنات لـ Phoenix توفّر عناصر واجهة مستخدم سهلة الوصول وقابلة للتخصيص، تُولَّد مباشرة داخل تطبيقك."
        }
      ]
    }
  ]

  @en_version_specs [
    %{
      number: "0.0.1",
      status: :archived,
      sections: 2,
      notes_per: 5,
      is_latest: false,
      age_days: 420
    },
    %{
      number: "0.0.2",
      status: :archived,
      sections: 4,
      notes_per: 10,
      is_latest: false,
      age_days: 320
    },
    %{
      number: "0.0.3",
      status: :archived,
      sections: 8,
      notes_per: 10,
      is_latest: false,
      age_days: 220
    },
    %{
      number: "0.0.4",
      status: :beta,
      sections: 14,
      notes_per: 10,
      is_latest: false,
      age_days: 150
    },
    %{number: "0.0.5", status: :rc, sections: 22, notes_per: 10, is_latest: false, age_days: 75},
    %{
      number: "0.0.6",
      status: :stable,
      sections: 30,
      notes_per: 10,
      is_latest: true,
      age_days: 10
    }
  ]

  @translation_version_specs [
    %{
      number: "0.0.1",
      status: :archived,
      sections: 2,
      notes_per: 5,
      is_latest: false,
      age_days: 300
    },
    %{
      number: "0.0.2",
      status: :archived,
      sections: 4,
      notes_per: 10,
      is_latest: false,
      age_days: 180
    },
    %{
      number: "0.0.3",
      status: :stable,
      sections: 10,
      notes_per: 10,
      is_latest: true,
      age_days: 20
    }
  ]

  @section_topics [
    {"introduction", "Introduction"},
    {"installation", "Installation"},
    {"getting-started", "Getting Started"},
    {"configuration", "Configuration"},
    {"core-concepts", "Core Concepts"},
    {"cli-reference", "CLI Reference"},
    {"plugins-extensions", "Plugins and Extensions"},
    {"authentication", "Authentication"},
    {"authorization", "Authorization"},
    {"data-modeling", "Data Modeling"},
    {"queries-actions", "Queries and Actions"},
    {"validations", "Validations"},
    {"relationships", "Relationships"},
    {"multi-tenancy", "Multi-Tenancy"},
    {"real-time", "Real-Time Features"},
    {"file-uploads", "File Uploads"},
    {"internationalization", "Internationalization"},
    {"caching", "Caching Strategies"},
    {"background-jobs", "Background Jobs"},
    {"event-sourcing", "Event Sourcing"},
    {"testing", "Testing"},
    {"debugging", "Debugging"},
    {"performance", "Performance Tuning"},
    {"deployment", "Deployment"},
    {"security", "Security Best Practices"},
    {"migration-guide", "Migration Guide"},
    {"troubleshooting", "Troubleshooting"},
    {"faq", "FAQ"},
    {"contributing", "Contributing"},
    {"changelog", "Changelog"}
  ]

  @fa_section_titles %{
    "introduction" => "معرفی",
    "installation" => "نصب",
    "getting-started" => "شروع سریع",
    "configuration" => "پیکربندی",
    "core-concepts" => "مفاهیم اصلی",
    "cli-reference" => "مرجع CLI",
    "plugins-extensions" => "افزونه‌ها و اکستنشن‌ها",
    "authentication" => "احراز هویت",
    "authorization" => "مجوزدهی",
    "data-modeling" => "مدل‌سازی داده",
    "queries-actions" => "کوئری‌ها و اکشن‌ها",
    "validations" => "اعتبارسنجی‌ها",
    "relationships" => "روابط",
    "multi-tenancy" => "چندمستاجری",
    "real-time" => "قابلیت‌های بی‌درنگ",
    "file-uploads" => "بارگذاری فایل",
    "internationalization" => "بین‌المللی‌سازی",
    "caching" => "راهبردهای حافظه موقت",
    "background-jobs" => "کارهای پس‌زمینه",
    "event-sourcing" => "رویدادمحوری",
    "testing" => "تست",
    "debugging" => "اشکال‌زدایی",
    "performance" => "بهینه‌سازی کارایی",
    "deployment" => "استقرار",
    "security" => "امنیت",
    "migration-guide" => "راهنمای مهاجرت",
    "troubleshooting" => "رفع مشکل",
    "faq" => "سوالات متداول",
    "contributing" => "مشارکت",
    "changelog" => "تغییرات"
  }

  @fr_section_titles %{
    "introduction" => "Introduction",
    "installation" => "Installation",
    "getting-started" => "Démarrage rapide",
    "configuration" => "Configuration",
    "core-concepts" => "Concepts fondamentaux",
    "cli-reference" => "Référence CLI",
    "plugins-extensions" => "Plugins et extensions",
    "authentication" => "Authentification",
    "authorization" => "Autorisation",
    "data-modeling" => "Modélisation des données",
    "queries-actions" => "Requêtes et actions",
    "validations" => "Validations",
    "relationships" => "Relations",
    "multi-tenancy" => "Multi-tenance",
    "real-time" => "Fonctionnalités temps réel",
    "file-uploads" => "Téléversement de fichiers",
    "internationalization" => "Internationalisation",
    "caching" => "Stratégies de cache",
    "background-jobs" => "Tâches d'arrière-plan",
    "event-sourcing" => "Event sourcing",
    "testing" => "Tests",
    "debugging" => "Débogage",
    "performance" => "Optimisation des performances",
    "deployment" => "Déploiement",
    "security" => "Bonnes pratiques de sécurité",
    "migration-guide" => "Guide de migration",
    "troubleshooting" => "Dépannage",
    "faq" => "Questions fréquentes",
    "contributing" => "Contribuer",
    "changelog" => "Journal des modifications"
  }

  @ar_section_titles %{
    "introduction" => "مقدمة",
    "installation" => "التثبيت",
    "getting-started" => "البدء السريع",
    "configuration" => "الإعداد",
    "core-concepts" => "المفاهيم الأساسية",
    "cli-reference" => "مرجع سطر الأوامر",
    "plugins-extensions" => "الإضافات والملحقات",
    "authentication" => "المصادقة",
    "authorization" => "الصلاحيات",
    "data-modeling" => "نمذجة البيانات",
    "queries-actions" => "الاستعلامات والإجراءات",
    "validations" => "عمليات التحقق",
    "relationships" => "العلاقات",
    "multi-tenancy" => "تعدد المستأجرين",
    "real-time" => "الميزات الفورية",
    "file-uploads" => "رفع الملفات",
    "internationalization" => "التدويل",
    "caching" => "استراتيجيات التخزين المؤقت",
    "background-jobs" => "المهام الخلفية",
    "event-sourcing" => "مصادر الأحداث",
    "testing" => "الاختبارات",
    "debugging" => "تصحيح الأخطاء",
    "performance" => "تحسين الأداء",
    "deployment" => "النشر",
    "security" => "أفضل ممارسات الأمان",
    "migration-guide" => "دليل الترحيل",
    "troubleshooting" => "حل المشكلات",
    "faq" => "الأسئلة الشائعة",
    "contributing" => "المساهمة",
    "changelog" => "سجل التغييرات"
  }

  @note_topics [
    "Implementation Note",
    "Performance Consideration",
    "Security Warning",
    "Deprecation Notice",
    "Known Limitation",
    "Design Decision",
    "Example",
    "Reference",
    "Tip",
    "Caveat"
  ]

  @tag_names [
    "api",
    "auth",
    "caching",
    "config",
    "deployment",
    "logging",
    "migrations",
    "performance",
    "security",
    "testing",
    "webhooks",
    "workers"
  ]

  @fa_tag_names %{
    "api" => "رابط برنامه‌نویسی",
    "auth" => "احراز هویت",
    "caching" => "حافظه موقت",
    "config" => "پیکربندی",
    "deployment" => "استقرار",
    "logging" => "ثبت رویداد",
    "migrations" => "مهاجرت‌ها",
    "performance" => "کارایی",
    "security" => "امنیت",
    "testing" => "تست",
    "webhooks" => "وب‌هوک",
    "workers" => "کارگرها"
  }

  @issue_type_pool [
    :typo,
    :broken_link,
    :incorrect_content,
    :suggestion,
    :review_feedback,
    :other
  ]

  @comment_openers [
    "Thanks for flagging this",
    "Good catch",
    "Confirmed on my side",
    "Picking this up"
  ]

  @comment_lines [
    "Reproduced locally. I can get a patch ready this week.",
    "We touched this area two releases ago — cross-checking the diff now.",
    "The workaround is already in the changelog for 0.0.5.",
    "Draft fix is up; it needs one more pair of eyes.",
    "Small wording tweak pushed, much easier to read now.",
    "Tested against the latest snapshot and the example runs clean.",
    "Queued for the next review round.",
    "Splitting this into a follow-up so the release is not held up.",
    "The screenshot in that chapter is stale as well — same pass.",
    "Agreed, the current phrasing reads as if the option were required."
  ]

  @draft_tags ["expanded", "clarified", "rewritten", "example-added"]

  @editors_only ["admin:dashboard:document:section"]

  @permission_examples [
    %{
      name: "Internal handbook",
      slug: "internal-handbook",
      description: "What a new member of the team needs in their first weeks.",
      permissions: @editors_only,
      pages: [
        %{
          title: "Onboarding",
          slug: "onboarding",
          paragraph:
            "Your first week starts with a walk through the codebase and a pairing session with " <>
              "your onboarding buddy. By Friday you will have shipped one small change to " <>
              "production and know who to ask about what."
        },
        %{
          title: "Tools we use",
          slug: "tools-we-use",
          paragraph:
            "We plan work in the issue tracker, talk in the team chat and review every change in " <>
              "a pull request before it is merged. Your buddy gives you access to each of them on " <>
              "your first day."
        }
      ]
    },
    %{
      name: "Team guide",
      slug: "team-guide",
      description: "How the team works day to day.",
      permissions: [],
      pages: [
        %{
          title: "Welcome",
          slug: "welcome",
          paragraph:
            "This guide collects how the team works day to day. Start here, then read the pages " <>
              "that apply to you; anything missing or out of date can be raised as an issue on " <>
              "its page."
        },
        %{
          title: "Pay and leave",
          slug: "pay-and-leave",
          permissions: @editors_only,
          paragraph:
            "Salaries are paid on the last working day of each month. Annual leave is twenty-five " <>
              "days a year: request it at least two weeks ahead and tell your lead before you book " <>
              "travel."
        },
        %{
          title: "Meeting notes",
          slug: "meeting-notes",
          seo_tags: [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex, follow"}],
          paragraph:
            "Notes from the weekly team meeting, newest first. Decisions are marked as such; the " <>
              "rest is discussion and may change before the next meeting."
        }
      ]
    },
    # WHAT A PAGE TAKES FROM ABOVE IT: one naming nothing takes the nearest page above it that names
    # something, else its document's; one naming its own opens with that alone.
    %{
      name: "Staff handbook",
      slug: "staff-handbook",
      description: "Locked to editors; one page of it is the writers' instead.",
      permissions: @editors_only,
      pages: [
        %{
          title: "Start here",
          slug: "start-here",
          paragraph:
            "This page names no permission, so it takes its document's: only an account that " <>
              "may edit the documentation can open it."
        },
        %{
          title: "Writers' desk",
          slug: "writers-desk",
          permissions: ["admin:dashboard:blog:post"],
          paragraph:
            "This page names its own permission, the blog's post permission, and its own wins " <>
              "over the document's: a writer can open it and an editor of the documentation cannot."
        },
        %{
          title: "Style guide",
          slug: "style-guide",
          parent: "writers-desk",
          paragraph:
            "This page names no permission and sits under Writers' desk, so it takes that page's " <>
              "rather than the document's: it opens for writers too."
        }
      ]
    },
    %{
      name: "Release notes archive",
      slug: "release-notes-archive",
      description: "Every past release, kept for reference but out of search results.",
      permissions: [],
      seo_tags: [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex, follow"}],
      pages: [
        %{
          title: "Older releases",
          slug: "older-releases",
          paragraph:
            "Every release before the current one, oldest first, with what changed and what an " <>
              "upgrade needs. Kept for reference; search engines are asked to leave it out."
        },
        %{
          title: "Latest release",
          slug: "latest-release",
          seo_tags: [%{tag: "meta", attrs: %{"name" => "robots"}, content: "index, follow"}],
          paragraph:
            "What the newest release brings and how to upgrade to it. This page asks to be " <>
              "indexed, so it is listed even though the rest of the archive is not."
        }
      ]
    }
  ]

  # ---------------------------------------------------------------------------
  # Entry points
  # ---------------------------------------------------------------------------

  @doc """
  Creates realistic document seed data for a single site.

  RUN AGAIN ON A SITE THAT HAS DOCUMENTS, this adds none of the products and answers
  `:already_seeded`. The five products would come back under the same names — `unique_slug_per_site`
  would refuse the second set outright — and everything hanging off them, versions, sections, notes,
  drafts and issues, is generated with nothing to recognise it by afterwards. So the thing that is
  either there or not is the documentation, and a site that has it keeps what its authors have done
  to it. The permission and robots examples are asked apart from it, each by its own slug, so a site
  seeded before they existed gets them on its next run.
  """
  @spec dev_seed(String.t(), [struct()], (String.t() -> any())) :: :ok | :already_seeded
  def dev_seed(site_id, users, progress \\ fn _ -> :ok end) do
    Seeds.announce("  ==> [MishkaDocument] Seeding site #{String.slice(site_id, 0, 8)}...")

    # THE SAMPLE PAGES FIRST, here rather than only in the Oban job a site create enqueues: a dev
    # seed that left them to the queue seeded sites whose documentation had no page to read it on
    # until a worker happened to run. `ensure!/1` writes only what the site is missing.
    progress.("Writing the documentation's sample pages…")
    MishkaDocument.Provision.ensure!(site_id)

    # THE EXTENSION'S OWN ROLES, now that installing it has created their names.
    Seeds.seed_role_accounts(site_id, [{"editor", ["admin:dashboard:document:section"]}])

    result =
      if seeded?(site_id) do
        Seeds.announce("  ==> [MishkaDocument] This site already has documents — nothing added.")
        :already_seeded
      else
        seed_everything(site_id, users, progress)
      end

    # THREE DOCUMENTS TO TRY A RECORD'S PERMISSIONS AND ROBOTS META ON, each written only while the
    # site has none at its slug. "Internal handbook" names `admin:dashboard:document:section` and its
    # pages follow it; in "Team guide", "Pay and leave" names it alone and "Meeting notes" says
    # `noindex, follow`; "Release notes archive" says `noindex, follow` and its pages follow it, but
    # "Latest release" says `index, follow` and wins. A closed page sends a guest to sign in, answers
    # `viewer@<site>.test` with a 404 and opens for `editor@<site>.test`, who holds the name
    # (`seed_role_accounts/2` above), and for `admin@<site>.test`. A noindex page opens for everyone
    # and stays out of the sitemap. After the documentation, not before it: written first, they would
    # be what `seeded?/1` finds, and a new site would get nothing else.
    seed_permission_examples(site_id, users)

    result
  end

  # ONE WORKSPACE IS ENOUGH TO SAY THE SITE HAS DOCUMENTATION, and one `query` matches is enough to
  # say it has that document. Archived ones count as well, and have to: the closing pass of a run
  # archives whole translation workspaces, so a check that looked only at live rows would call a
  # fully seeded site unseeded once its authors had tidied up.
  defp seeded?(site_id, query \\ Workspace) do
    Enum.any?([:read_any, :master_archived], fn action ->
      query
      |> Ash.Query.for_read(action, %{}, authorize?: false)
      |> Ash.Query.filter(site_id == ^site_id)
      |> Ash.exists?(authorize?: false)
    end)
  end

  defp seed_everything(site_id, users, progress) do
    authors = authors_for(users, site_id)
    masters = masters_in(users)

    progress.("Tags")
    tags = seed_tags(site_id, authors)

    progress.("Products, versions & sections")

    product_data =
      @products
      |> Enum.with_index()
      |> Enum.map(fn {product, index} -> seed_product(site_id, product, tags, authors, index) end)

    progress.("Drafts")

    drafts =
      Enum.map(product_data, fn %{product: product, en_versions: en_versions} ->
        seed_drafts(site_id, List.last(en_versions), product, authors)
      end)

    progress.("Issues & comments")
    issues = seed_issues_with_comments(site_id, product_data, authors, masters, 20)

    progress.("Views, bookmarks & followers")
    seed_readers(product_data, authors)

    progress.("Backdating history")
    backdate(site_id, tags, product_data, drafts, issues)

    progress.("Archiving")
    archived = archive_pass(site_id, tags, product_data, drafts, issues)

    total_sections =
      Enum.reduce(product_data, 0, fn %{en_versions: ev, translation_versions: tv}, acc ->
        Enum.reduce(ev ++ tv, acc, fn v, a -> a + length(v.sections) end)
      end)

    Seeds.announce(
      "  ==> [MishkaDocument] Done. #{length(product_data)} products, #{total_sections} sections, #{archived} records archived."
    )

    :ok
  end

  @doc """
  Stress seed: large volumes of document data for a site.

  Runs the same building blocks as `dev_seed/3` at scale — language-paired tags, long-tailed note
  counts, per-record authors, commented issues and a closing archival pass — so a stress run
  exercises the code paths the admin pages actually render rather than a flat grid of identical
  rows.
  """
  def stress_seed(site_id, users, opts \\ []) do
    workspace_count = Keyword.get(opts, :workspaces, 50)
    versions_per_workspace = Keyword.get(opts, :versions_per_workspace, 5)
    sections_per_version = Keyword.get(opts, :sections_per_version, 20)
    notes_per_section = Keyword.get(opts, :notes_per_section, 10)
    issue_count = Keyword.get(opts, :issues, 50)
    tag_count = Keyword.get(opts, :tags, 50)

    Seeds.announce("  ==> [MishkaDocument] Stress seeding site #{String.slice(site_id, 0, 8)}...")

    authors = authors_for(users, site_id)
    masters = masters_in(users)

    tags =
      Enum.map(1..tag_count, fn i ->
        dev_document_tag([site_id: site_id], site_id, pick_author(authors, {:stress_tag, i}))
        |> Ash.Generator.generate()
      end)

    tag_pool = %{en: tags, fa: tags}

    workspaces =
      Enum.map(1..workspace_count, fn i ->
        dev_workspace([site_id: site_id], site_id, pick_author(authors, {:stress_workspace, i}))
        |> Ash.Generator.generate()
      end)

    groups =
      Enum.map(workspaces, fn ws ->
        versions =
          Enum.map(1..versions_per_workspace, fn i ->
            stress_version(
              site_id,
              ws,
              i,
              versions_per_workspace,
              sections_per_version,
              notes_per_section,
              tag_pool,
              authors
            )
          end)

        %{workspace: ws, versions: versions}
      end)

    doomed =
      workspaces
      |> pick_many(2, {site_id, :stress_archive_workspaces})
      |> MapSet.new(& &1.id)

    {dead_groups, live_groups} =
      Enum.split_with(groups, &MapSet.member?(doomed, &1.workspace.id))

    sections = Enum.flat_map(live_groups, &group_sections/1)
    notes = Enum.flat_map(live_groups, &group_notes/1)
    issues = stress_issues(site_id, sections, authors, masters, issue_count)

    archived = stress_archive(site_id, dead_groups, sections, notes, tags, issues)

    Seeds.announce(
      "  ==> [MishkaDocument] Stress seed done for site #{String.slice(site_id, 0, 8)}. #{archived} records archived."
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Permission examples
  # ---------------------------------------------------------------------------

  defp seed_permission_examples(site_id, users) do
    authors = authors_for(users, site_id)

    @permission_examples
    |> Enum.with_index(length(@products))
    |> Enum.reject(fn {%{slug: slug}, _order} ->
      seeded?(site_id, Ash.Query.filter(Workspace, slug == ^slug))
    end)
    |> Enum.each(fn {example, order} ->
      seed_example(site_id, example, order, pick_author(authors, {:workspace, example.slug}))
      Seeds.announce("  ==> [MishkaDocument] Added the example document \"#{example.name}\".")
    end)
  end

  # Active, with one published version marked latest whose pages are approved on both axes: what
  # `doc-section` shows a reader.
  defp seed_example(site_id, example, order, author) do
    spec = %{number: "1.0.0", status: :stable, age_days: 30}

    workspace =
      workspace(
        [
          name: example.name,
          slug: example.slug,
          description: example.description,
          status: :active,
          schema: [],
          seo_tags: Map.get(example, :seo_tags, []),
          permissions: example.permissions,
          featured: false,
          display_order: order,
          language: "en",
          language_group_id: nil,
          site_id: site_id
        ],
        site_id,
        author
      )
      |> Ash.Generator.generate()

    version =
      workspace_version(
        [
          workspace_id: workspace.id,
          version_number: spec.number,
          version_name: version_name(spec),
          description: version_description(spec, workspace),
          status: spec.status,
          is_latest_for_version: true,
          source_version_id: nil,
          published_at: published_at(spec),
          site_id: site_id
        ],
        site_id,
        author
      )
      |> Ash.Generator.generate()

    # Each page is written after the one it sits under, which is named by slug.
    example.pages
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {page, position}, written ->
      section(
        [
          workspace_version_id: version.id,
          parent_section_id: page |> Map.get(:parent) |> then(&Map.get(written, &1)),
          title: page.title,
          slug: page.slug,
          content: "<p>#{page.paragraph}</p>",
          order_position: position,
          change_version: spec.number,
          content_review_status: :approved,
          technical_review_status: :approved,
          schema: [],
          seo_tags: Map.get(page, :seo_tags, []),
          permissions: Map.get(page, :permissions, []),
          language: "en",
          language_group_id: nil,
          section_lineage_id: nil,
          source_section_id: nil,
          site_id: site_id,
          tag_ids: []
        ],
        site_id,
        author
      )
      |> Ash.Generator.generate()
      |> then(&Map.put(written, &1.slug, &1.id))
    end)
  end

  # ---------------------------------------------------------------------------
  # Tags
  # ---------------------------------------------------------------------------

  defp seed_tags(site_id, authors) do
    {en, fa} =
      @tag_names
      |> Enum.map(fn name ->
        author = pick_author(authors, {:tag, name})

        en_tag =
          document_tag(
            [
              name: name,
              slug: name,
              language: "en",
              language_group_id: nil,
              site_id: site_id
            ],
            site_id,
            author
          )
          |> Ash.Generator.generate()

        fa_tag =
          document_tag(
            [
              name: Map.fetch!(@fa_tag_names, name),
              slug: "#{name}-fa",
              language: "fa",
              language_group_id: en_tag.id,
              site_id: site_id
            ],
            site_id,
            author
          )
          |> Ash.Generator.generate()

        {en_tag, fa_tag}
      end)
      |> Enum.unzip()

    %{en: en, fa: fa}
  end

  defp attach_tags(section, tags, lang, count) do
    tags
    |> language_tags(lang)
    |> pick_many(count, {:tags, section.id})
    |> Enum.each(fn tag ->
      section_tag(section_id: section.id, tag_id: tag.id)
      |> Ash.Generator.generate()
    end)
  end

  defp language_tags(%{fa: fa}, :fa), do: fa
  defp language_tags(%{en: en}, _lang), do: en

  defp tag_count_for(idx) do
    cond do
      rem(idx, 7) == 0 -> 0
      rem(idx, 3) == 0 -> 4
      true -> 3
    end
  end

  # ---------------------------------------------------------------------------
  # Workspaces + versions + sections + notes
  # ---------------------------------------------------------------------------

  defp seed_product(site_id, product, tags, authors, index) do
    en_ctx = %{site_id: site_id, lang: :en, product: product, tags: tags, authors: authors}

    en_ws = create_workspace(en_ctx, index)
    en_versions = create_versions(en_ctx, en_ws, @en_version_specs, [])

    translations =
      product.translations
      |> Enum.with_index(1)
      |> Enum.map(fn {translation, display_order} ->
        ctx = %{en_ctx | lang: lang_atom(translation.language)}
        ws = create_translation_workspace(ctx, translation, en_ws, display_order)

        %{
          workspace: ws,
          versions: create_versions(ctx, ws, @translation_version_specs, en_versions)
        }
      end)

    %{
      product: product,
      en_ws: en_ws,
      en_versions: en_versions,
      translations: translations,
      translation_versions: Enum.flat_map(translations, & &1.versions)
    }
  end

  defp create_workspace(ctx, index) do
    workspace(
      [
        name: ctx.product.en_name,
        slug: ctx.product.slug_base,
        description: ctx.product.en_desc,
        status: workspace_status(ctx.product),
        schema: [],
        seo_tags: [],
        featured: ctx.product.completion >= 65,
        display_order: index,
        language: "en",
        language_group_id: nil,
        site_id: ctx.site_id
      ],
      ctx.site_id,
      pick_author(ctx.authors, {:workspace, ctx.product.slug_base})
    )
    |> Ash.Generator.generate()
  end

  defp create_translation_workspace(ctx, translation, en_ws, display_order) do
    workspace(
      [
        name: translation.name,
        slug: "#{ctx.product.slug_base}-#{translation.language}",
        description: translation.desc,
        status: workspace_status(ctx.product),
        schema: [],
        seo_tags: [],
        featured:
          :erlang.phash2({ctx.product.slug_base, translation.language, :featured}, 100) < 30,
        display_order: display_order,
        language: translation.language,
        language_group_id: en_ws.id,
        site_id: ctx.site_id
      ],
      ctx.site_id,
      pick_author(ctx.authors, {:workspace, ctx.product.slug_base, translation.language})
    )
    |> Ash.Generator.generate()
  end

  defp workspace_status(%{completion: completion}) when completion <= 40, do: :draft
  defp workspace_status(_product), do: :active

  defp create_versions(ctx, workspace, specs, en_versions) do
    {_, entries} =
      Enum.reduce(specs, {nil, []}, fn spec, {prev_entry, acc} ->
        version = create_version(ctx, workspace, spec, prev_entry)
        link_version(ctx, version, prev_entry)

        en_entry = Enum.find(en_versions, &(&1.spec.number == spec.number))
        sections = create_sections(ctx, version, spec, prev_entry, en_entry)
        notes = Enum.flat_map(sections, &create_notes(ctx, &1, spec))

        entry = %{version: version, sections: sections, notes: notes, spec: spec}
        {entry, acc ++ [entry]}
      end)

    entries
  end

  defp create_version(ctx, workspace, spec, prev_entry) do
    workspace_version(
      [
        workspace_id: workspace.id,
        version_number: spec.number,
        version_name: version_name(spec),
        description: version_description(spec, workspace),
        status: spec.status,
        is_latest_for_version: spec.is_latest,
        source_version_id: source_version_id(prev_entry),
        published_at: published_at(spec),
        site_id: ctx.site_id
      ],
      ctx.site_id,
      pick_author(ctx.authors, {:version, workspace.slug, spec.number})
    )
    |> Ash.Generator.generate()
  end

  defp source_version_id(%{version: version}), do: version.id
  defp source_version_id(_prev_entry), do: nil

  defp published_at(%{status: status, age_days: age_days}) when status in [:stable, :archived],
    do: DateTime.add(DateTime.utc_now(), -age_days * 86_400, :second)

  defp published_at(_spec), do: nil

  defp link_version(_ctx, _version, nil), do: :ok

  defp link_version(ctx, version, %{version: source}) do
    workspace_version_lineage(
      [
        new_version_id: version.id,
        source_version_id: source.id,
        site_id: ctx.site_id
      ],
      ctx.site_id
    )
    |> Ash.Generator.generate()
  end

  defp version_name(%{status: :stable, number: n}), do: "Stable #{n}"
  defp version_name(%{status: :rc, number: n}), do: "Release Candidate #{n}"
  defp version_name(%{status: :beta, number: n}), do: "Beta #{n}"
  defp version_name(%{status: :alpha, number: n}), do: "Alpha #{n}"
  defp version_name(%{status: :archived, number: n}), do: "Archived #{n}"
  defp version_name(%{number: n}), do: "Draft #{n}"

  defp version_description(%{status: status, number: n}, ws) do
    "#{ws.name} #{n} — #{status_description(status)}"
  end

  defp status_description(:stable), do: "stable production release."
  defp status_description(:rc), do: "release candidate; API-frozen, final testing."
  defp status_description(:beta), do: "beta build with feature-complete surface."
  defp status_description(:alpha), do: "alpha preview; APIs still in flux."
  defp status_description(:archived), do: "archived release, superseded by newer versions."
  defp status_description(_), do: "in-progress draft."

  defp create_sections(ctx, version, spec, prev_entry, en_entry) do
    cloned = clone_sections(ctx, version, spec, prev_entry, en_entry)

    new_start = length(cloned) + 1
    new_count = spec.sections - length(cloned)

    new_sections =
      Enum.map(new_start..(new_start + new_count - 1)//1, fn idx ->
        fresh_section(
          ctx,
          version,
          section_topic(idx),
          idx,
          spec,
          master_section_id(en_entry, idx)
        )
      end)

    cloned ++ new_sections
  end

  defp clone_sections(ctx, version, spec, %{sections: prev_sections}, en_entry)
       when prev_sections != [] do
    prev_sections
    |> Enum.with_index(1)
    |> Enum.map(fn {prev_sec, idx} ->
      clone_section(ctx, version, prev_sec, idx, spec, master_section_id(en_entry, idx))
    end)
  end

  defp clone_sections(_ctx, _version, _spec, _prev_entry, _en_entry), do: []

  defp master_section_id(nil, _idx), do: nil

  defp master_section_id(%{sections: sections}, idx) do
    case Enum.at(sections, idx - 1) do
      nil -> nil
      section -> section.language_group_id
    end
  end

  defp clone_section(ctx, version, prev_sec, idx, spec, master_id) do
    {content_status, technical_status} =
      review_status_for(ctx.product, {:section, spec.number, idx})

    section =
      section(
        [
          workspace_version_id: version.id,
          title: prev_sec.title,
          slug: prev_sec.slug,
          content: section_content(prev_sec.title, spec, ctx.lang),
          order_position: idx,
          change_version: spec.number,
          content_review_status: content_status,
          technical_review_status: technical_status,
          schema: [],
          seo_tags: [],
          language: lang_string(ctx.lang),
          language_group_id: master_id,
          section_lineage_id: prev_sec.section_lineage_id,
          source_section_id: prev_sec.id,
          site_id: ctx.site_id,
          tag_ids: []
        ],
        ctx.site_id,
        pick_author(ctx.authors, {:section, ctx.product.slug_base, ctx.lang, spec.number, idx})
      )
      |> Ash.Generator.generate()

    attach_tags(section, ctx.tags, ctx.lang, tag_count_for(idx))
    section
  end

  defp fresh_section(ctx, version, {slug, en_title}, idx, spec, master_id) do
    {content_status, technical_status} =
      review_status_for(ctx.product, {:section, spec.number, idx})

    section =
      section(
        [
          workspace_version_id: version.id,
          title: section_title(ctx.lang, slug, en_title),
          slug: slug,
          content: section_content(en_title, spec, ctx.lang),
          order_position: idx,
          change_version: spec.number,
          content_review_status: content_status,
          technical_review_status: technical_status,
          schema: [],
          seo_tags: [],
          language: lang_string(ctx.lang),
          language_group_id: master_id,
          section_lineage_id: nil,
          source_section_id: nil,
          site_id: ctx.site_id,
          tag_ids: []
        ],
        ctx.site_id,
        pick_author(ctx.authors, {:section, ctx.product.slug_base, ctx.lang, spec.number, idx})
      )
      |> Ash.Generator.generate()

    attach_tags(section, ctx.tags, ctx.lang, tag_count_for(idx))
    section
  end

  defp section_topic(idx) do
    count = length(@section_topics)
    {slug, title} = Enum.at(@section_topics, rem(idx - 1, count))
    disambiguate_topic(slug, title, div(idx - 1, count))
  end

  defp disambiguate_topic(slug, title, 0), do: {slug, title}

  defp disambiguate_topic(slug, title, cycle),
    do: {"#{slug}-#{cycle + 1}", "#{title} (Part #{cycle + 1})"}

  defp section_title(:fa, slug, en_title), do: Map.get(@fa_section_titles, slug, en_title)
  defp section_title(:fr, slug, en_title), do: Map.get(@fr_section_titles, slug, en_title)
  defp section_title(:ar, slug, en_title), do: Map.get(@ar_section_titles, slug, en_title)
  defp section_title(_lang, _slug, en_title), do: en_title

  defp review_status_for(product, key) do
    approved? = :erlang.phash2({product.slug_base, key}, 100) < product.completion
    review_pair(approved?, :erlang.phash2({product.slug_base, key, :spread}, 10))
  end

  defp review_pair(true, _spread), do: {:approved, :approved}
  defp review_pair(false, 0), do: {:rejected, :rejected}
  defp review_pair(false, 1), do: {:needs_revision, :approved}
  defp review_pair(false, spread) when spread < 6, do: {:approved, :pending}
  defp review_pair(false, 8), do: {:pending, :approved}
  defp review_pair(false, _spread), do: {:pending, :pending}

  defp section_content(title, %{number: ver}, :fa) do
    "<h2>#{title}</h2>\n<p>این بخش جنبه‌های مختلف #{title} را در نسخه #{ver} پوشش می‌دهد. " <>
      "شامل مثال‌های عملی، نکات پیکربندی و بهترین شیوه‌ها برای استقرار تولیدی است.</p>"
  end

  defp section_content(title, %{number: ver}, :fr) do
    "<h2>#{title}</h2>\n<p>Cette section couvre tous les aspects de #{String.downcase(title)} pour la version #{ver}. " <>
      "Elle contient des exemples concrets, des conseils de configuration et des recommandations éprouvées en production.</p>"
  end

  defp section_content(title, %{number: ver}, :ar) do
    "<h2>#{title}</h2>\n<p>يغطي هذا القسم كل جوانب #{title} في الإصدار #{ver}. " <>
      "ويتضمن أمثلة عملية ونصائح للإعداد وإرشادات مجرَّبة في بيئات الإنتاج.</p>"
  end

  defp section_content(title, %{number: ver}, _lang) do
    "<h2>#{title}</h2>\n<p>This section covers every aspect of #{String.downcase(title)} as of release #{ver}. " <>
      "It includes worked examples, configuration tips, and battle-tested guidance for production deployments.</p>"
  end

  defp lang_string(:fa), do: "fa"
  defp lang_string(:fr), do: "fr"
  defp lang_string(:ar), do: "ar"
  defp lang_string(_lang), do: "en"

  defp lang_atom("fa"), do: :fa
  defp lang_atom("fr"), do: :fr
  defp lang_atom("ar"), do: :ar

  defp create_notes(ctx, section, spec) do
    Enum.map(1..note_count_for(ctx, section, spec)//1, fn idx ->
      topic = Enum.at(@note_topics, rem(idx - 1, length(@note_topics)))

      {content_status, technical_status} =
        review_status_for(ctx.product, {:note, spec.number, section.slug, idx})

      note(
        [
          section_id: section.id,
          title: note_title(topic, idx, ctx.lang),
          content: note_content(topic, section.title, spec, ctx.lang),
          order_position: idx,
          change_version: spec.number,
          content_review_status: content_status,
          technical_review_status: technical_status,
          schema: [],
          seo_tags: [],
          site_id: ctx.site_id
        ],
        ctx.site_id,
        pick_author(ctx.authors, {:note, ctx.product.slug_base, spec.number, section.slug, idx})
      )
      |> Ash.Generator.generate()
    end)
  end

  defp note_count_for(ctx, section, spec) do
    key = {ctx.product.slug_base, ctx.lang, spec.number, section.slug, :notes}
    div(note_count(:erlang.phash2(key, 100)) * spec.notes_per, 10)
  end

  defp note_count(hash) when hash < 12, do: 0
  defp note_count(hash) when hash < 30, do: 2
  defp note_count(hash) when hash < 62, do: 5
  defp note_count(hash) when hash < 84, do: 7
  defp note_count(hash) when hash < 95, do: 10
  defp note_count(_hash), do: 14

  defp note_title(topic, idx, :fa), do: "#{translate_note_topic(topic)} ##{idx}"
  defp note_title(topic, idx, _lang), do: "#{topic} ##{idx}"

  defp translate_note_topic("Implementation Note"), do: "یادداشت پیاده‌سازی"
  defp translate_note_topic("Performance Consideration"), do: "ملاحظه کارایی"
  defp translate_note_topic("Security Warning"), do: "هشدار امنیتی"
  defp translate_note_topic("Deprecation Notice"), do: "اعلام منسوخ‌شدن"
  defp translate_note_topic("Known Limitation"), do: "محدودیت شناخته‌شده"
  defp translate_note_topic("Design Decision"), do: "تصمیم طراحی"
  defp translate_note_topic("Example"), do: "مثال"
  defp translate_note_topic("Reference"), do: "مرجع"
  defp translate_note_topic("Tip"), do: "نکته"
  defp translate_note_topic("Caveat"), do: "هشدار"
  defp translate_note_topic(other), do: other

  defp note_content(topic, section_title, %{number: ver}, :fa) do
    "**#{translate_note_topic(topic)}:** اطلاعات تکمیلی در مورد #{section_title} در نسخه #{ver}. " <>
      "پیش از استفاده در محیط تولید، این نکته را به دقت بررسی کنید."
  end

  defp note_content(topic, section_title, %{number: ver}, _lang) do
    "**#{topic}:** Additional context for #{section_title} as of #{ver}. " <>
      "Review this before rolling the feature out to production."
  end

  # ---------------------------------------------------------------------------
  # Drafts (only on latest stable — 0.0.6 English)
  # ---------------------------------------------------------------------------

  defp seed_drafts(site_id, entry, product, authors) do
    %{version: version, sections: sections, notes: notes, spec: spec} = entry

    ctx = %{
      site_id: site_id,
      product: product,
      authors: authors,
      version: version,
      spec: spec
    }

    section_drafts = seed_section_drafts(ctx, sections)

    %{
      spec: spec,
      section_drafts: section_drafts,
      note_drafts: seed_note_drafts(ctx, sections, notes, section_drafts)
    }
  end

  defp seed_section_drafts(ctx, []), do: [new_chapter_draft(ctx)]

  defp seed_section_drafts(ctx, sections) do
    edit_target = pick_one(sections, {:edit, ctx.version.id})
    rewrite_target = pick_one(sections -- [edit_target], {:rewrite, ctx.version.id})

    [
      new_chapter_draft(ctx),
      revision_draft(ctx, edit_target, "revised", "rev", :patch),
      revision_draft(ctx, rewrite_target, "rewrite", "rw", :minor)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp new_chapter_draft(ctx) do
    slug = "advanced-patterns-#{String.slice(ctx.version.id, 0, 6)}"

    build_section_draft(ctx, %{
      source_section_id: nil,
      title: "Advanced Usage Patterns",
      slug: slug,
      content: "<p>Proposed new chapter covering advanced usage patterns for power users.</p>",
      order_position: 100,
      version_increment_type: :minor
    })
  end

  defp revision_draft(_ctx, nil, _label, _suffix, _increment), do: nil

  defp revision_draft(ctx, target, label, suffix, increment) do
    build_section_draft(ctx, %{
      source_section_id: target.id,
      title: "#{target.title} (#{label})",
      slug: "#{target.slug}-#{suffix}-#{String.slice(ctx.version.id, 0, 6)}",
      content: revision_content(label),
      order_position: target.order_position,
      version_increment_type: increment
    })
  end

  defp revision_content("revised"),
    do: "<p>Clarifies setup steps, adds a troubleshooting paragraph, fixes a typo.</p>"

  defp revision_content(_label),
    do: "<p>Proposed rewrite that restructures the chapter around task-based flows.</p>"

  defp build_section_draft(ctx, attrs) do
    {content_status, technical_status} =
      review_status_for(ctx.product, {:section_draft, attrs.slug})

    author = pick_author(ctx.authors, {:section_draft, attrs.slug})

    section_draft(
      [
        workspace_version_id: ctx.version.id,
        source_section_id: attrs.source_section_id,
        title: attrs.title,
        slug: attrs.slug,
        content: attrs.content,
        order_position: attrs.order_position,
        change_version: ctx.version.version_number,
        version_increment_type: attrs.version_increment_type,
        content_review_status: content_status,
        technical_review_status: technical_status,
        schema: [],
        seo_tags: [],
        language: "en",
        language_group_id: nil,
        created_by_user_id: author_id(author),
        site_id: ctx.site_id
      ],
      ctx.site_id,
      author
    )
    |> Ash.Generator.generate()
    |> mark_applied(ctx, attrs.slug)
  end

  defp seed_note_drafts(_ctx, _sections, [], _section_drafts), do: []

  defp seed_note_drafts(ctx, sections, notes, section_drafts) do
    notes
    |> pick_many(4, {:note_drafts, ctx.version.id})
    |> Enum.zip(@draft_tags)
    |> Enum.with_index(1)
    |> Enum.map(fn {{source_note, tag}, idx} ->
      build_note_draft(ctx, source_note, tag, idx, sections, sibling_draft(idx, section_drafts))
    end)
  end

  defp sibling_draft(idx, section_drafts) when idx >= 3, do: Enum.at(section_drafts, idx - 3)
  defp sibling_draft(_idx, _section_drafts), do: nil

  defp build_note_draft(ctx, source_note, tag, idx, sections, nil) do
    {opts, author} = note_draft_opts(ctx, source_note, tag, idx)

    opts
    |> Keyword.put(:section_id, resolve_section_id(source_note, sections))
    |> note_draft(ctx.site_id, author)
    |> Ash.Generator.generate()
    |> mark_applied(ctx, {:note_draft, idx})
  end

  defp build_note_draft(ctx, source_note, tag, idx, _sections, section_draft) do
    {opts, author} = note_draft_opts(ctx, source_note, tag, idx)

    opts
    |> Keyword.put(:section_draft_id, section_draft.id)
    |> master_note_draft(author)
    |> Ash.Generator.generate()
    |> mark_applied(ctx, {:note_draft, idx})
  end

  defp note_draft_opts(ctx, source_note, tag, idx) do
    {content_status, technical_status} = review_status_for(ctx.product, {:note_draft, idx})
    author = pick_author(ctx.authors, {:note_draft, ctx.version.id, idx})

    opts = [
      workspace_version_id: ctx.version.id,
      source_note_id: source_note.id,
      title: "#{source_note.title} (#{tag})",
      content:
        "**Draft #{tag}:** refines the original note with clearer wording and an extra example.",
      order_position: source_note.order_position,
      change_version: ctx.version.version_number,
      version_increment_type: :patch,
      content_review_status: content_status,
      technical_review_status: technical_status,
      schema: [],
      seo_tags: [],
      created_by_user_id: author_id(author),
      site_id: ctx.site_id
    ]

    {opts, author}
  end

  defp resolve_section_id(%{section_id: section_id}, _sections) when not is_nil(section_id),
    do: section_id

  defp resolve_section_id(_note, [first | _rest]), do: first.id

  defp mark_applied(draft, ctx, key) do
    apply_draft(draft, ctx, key, :erlang.phash2({key, :applied}, 100) < 35)
  end

  defp apply_draft(draft, _ctx, _key, false), do: draft

  defp apply_draft(draft, ctx, key, true) do
    at = DateTime.add(DateTime.utc_now(), -applied_age(ctx.spec, key) * 86_400, :second)

    Ash.update!(draft, %{applied_at: at},
      action: :mark_applied,
      tenant: ctx.site_id,
      authorize?: false
    )
  end

  defp draft_age(%{age_days: age_days}, key) do
    half = max(div(age_days, 2), 1)
    half + rem(:erlang.phash2({key, :draft_age}), half + 1)
  end

  defp applied_age(%{age_days: age_days}, key) do
    rem(:erlang.phash2({key, :applied_age}), max(div(age_days, 2), 1))
  end

  # ---------------------------------------------------------------------------
  # Issues + comments
  # ---------------------------------------------------------------------------

  defp seed_issues_with_comments(_site_id, [], _authors, _masters, _count), do: []
  defp seed_issues_with_comments(_site_id, _product_data, [], _masters, _count), do: []

  defp seed_issues_with_comments(site_id, product_data, authors, masters, count) do
    build_issues(site_id, issue_targets(product_data), authors, masters, count)
  end

  defp build_issues(_site_id, {[], []}, _authors, _masters, _count), do: []

  defp build_issues(site_id, targets, authors, masters, count) do
    Enum.map(1..count, fn idx ->
      {kind, record, spec} = pick_target(targets, idx)
      outcome = issue_outcome(idx)
      issue = create_issue(site_id, kind, record, authors, idx)
      comments = create_issue_comments(site_id, issue, authors, masters, idx, outcome)

      %{
        issue: settle_issue(site_id, issue, outcome),
        comments: comments,
        spec: spec
      }
    end)
  end

  defp issue_targets(product_data) do
    en = Enum.flat_map(product_data, fn data -> version_targets(data.en_versions) end)

    translated =
      Enum.flat_map(product_data, fn data -> version_targets(data.translation_versions) end)

    {en, translated}
  end

  defp version_targets(versions) do
    Enum.flat_map(versions, fn %{sections: sections, notes: notes, spec: spec} ->
      Enum.map(sections, &{:section, &1, spec}) ++ Enum.map(notes, &{:note, &1, spec})
    end)
  end

  defp pick_target({en, translated}, idx) do
    en
    |> target_pool(translated, idx)
    |> Enum.sort_by(fn {_kind, record, _spec} ->
      :erlang.phash2({{:issue_target, idx}, record.id})
    end)
    |> hd()
  end

  defp target_pool(en, [], _idx), do: en
  defp target_pool([], translated, _idx), do: translated
  defp target_pool(_en, translated, idx) when rem(idx, 4) == 0, do: translated
  defp target_pool(en, _translated, _idx), do: en

  defp issue_outcome(idx) when rem(idx, 5) == 0, do: :resolved
  defp issue_outcome(idx) when rem(idx, 7) == 0, do: :closed
  defp issue_outcome(idx) when rem(idx, 3) == 0, do: :in_progress
  defp issue_outcome(_idx), do: :open

  defp create_issue(site_id, kind, record, authors, idx) do
    issue_type = Enum.at(@issue_type_pool, rem(:erlang.phash2({:issue_type, idx}), 6))
    reporter = pick_author(authors, {:reporter, idx})
    {section_id, note_id} = issue_reference(kind, record)

    dev_issue(
      [
        note_id: note_id,
        section_id: section_id,
        reporter_id: author_id(reporter),
        title: issue_title(issue_type, idx),
        description: issue_description(issue_type, record),
        issue_type: issue_type,
        status: :open,
        site_id: site_id
      ],
      site_id,
      reporter
    )
    |> Ash.Generator.generate()
  end

  defp issue_reference(:section, record), do: {record.id, nil}
  defp issue_reference(:note, record), do: {nil, record.id}

  defp create_issue_comments(site_id, issue, authors, masters, idx, outcome) do
    Enum.map(1..comment_count(outcome, idx)//1, fn position ->
      commenter = pick_commenter(authors, masters, {:commenter, idx, position})

      issue_comment(
        [issue_id: issue.id, content: comment_body(idx, position), site_id: site_id],
        site_id,
        commenter
      )
      |> Ash.Generator.generate()
    end)
  end

  # About one comment in five is a master's, when there is a master to write it. A tenant admin can
  # read a master's comment but not edit or delete it, and threads written only by the site's own
  # users would never show that.
  defp pick_commenter(authors, [], key), do: pick_author(authors, key)

  defp pick_commenter(authors, masters, key) do
    case rem(:erlang.phash2({:master_commenter, key}), 5) do
      0 -> pick_author(masters, key)
      _other -> pick_author(authors, key)
    end
  end

  defp comment_count(outcome, idx) when outcome in [:resolved, :closed],
    do: 6 + rem(:erlang.phash2({:comments, idx}), 9)

  defp comment_count(_outcome, idx), do: rem(:erlang.phash2({:comments, idx}), 4)

  defp settle_issue(_site_id, issue, :open), do: issue

  defp settle_issue(site_id, issue, outcome) do
    Ash.update!(issue, %{}, action: outcome_action(outcome), tenant: site_id, authorize?: false)
  end

  defp outcome_action(:in_progress), do: :mark_in_progress
  defp outcome_action(:resolved), do: :mark_resolved
  defp outcome_action(:closed), do: :mark_closed

  defp issue_title(:typo, idx), do: "Typo in paragraph ##{idx}"
  defp issue_title(:broken_link, idx), do: "Broken link reported (##{idx})"
  defp issue_title(:incorrect_content, idx), do: "Incorrect content needs review (##{idx})"
  defp issue_title(:suggestion, idx), do: "Suggestion: improve example (##{idx})"
  defp issue_title(:review_feedback, idx), do: "Review feedback (##{idx})"
  defp issue_title(_type, idx), do: "Documentation issue (##{idx})"

  defp issue_description(:typo, record) do
    "Minor typo spotted while reading \"#{record.title}\". Second paragraph has a misspelled word."
  end

  defp issue_description(:broken_link, record) do
    "External link in \"#{record.title}\" returns a 404. We should point it at the new docs site."
  end

  defp issue_description(:incorrect_content, record) do
    "Content in \"#{record.title}\" no longer matches the current API. Needs a pass before next release."
  end

  defp issue_description(:suggestion, record) do
    "Suggestion for \"#{record.title}\": add a worked example showing the common happy path."
  end

  defp issue_description(:review_feedback, record) do
    "Review notes for \"#{record.title}\": the second half needs a technical pass before sign-off."
  end

  defp issue_description(_type, record) do
    "General feedback on \"#{record.title}\". Needs triage."
  end

  defp comment_body(idx, 1) do
    opener = Enum.at(@comment_openers, rem(:erlang.phash2({:opener, idx}), 4))
    "#{opener} (issue ##{idx}). Taking a look now."
  end

  defp comment_body(idx, position) do
    Enum.at(@comment_lines, rem(:erlang.phash2({:comment, idx, position}), 10))
  end

  # ---------------------------------------------------------------------------
  # Views, bookmarks & followers
  # ---------------------------------------------------------------------------

  defp seed_readers(_product_data, []), do: :ok

  defp seed_readers(product_data, authors) do
    sections = all_sections(product_data)

    seed_section_views(sections, authors)
    seed_section_bookmarks(sections, authors)
    seed_workspace_followers(product_data, authors)
  end

  defp seed_section_views(sections, authors) do
    sections
    |> Enum.filter(&(&1.order_position <= 4))
    |> Enum.each(fn section ->
      views = :erlang.phash2({section.id, :views}, 6)
      readers = pick_many(authors, div(views + 1, 2), {:views, section.id})

      readers
      |> Enum.with_index(1)
      |> Enum.each(fn {reader, index} -> track_view(section, reader, index) end)

      Enum.each((length(readers) + 1)..views//1, &track_view(section, nil, &1))
    end)
  end

  defp track_view(section, reader, index) do
    section_view(
      [
        section_id: section.id,
        ip_address: "203.0.113.#{rem(index * 37, 250) + 2}",
        referer: "https://mishka.tools/docs"
      ],
      reader
    )
    |> Ash.Generator.generate()
  end

  defp seed_section_bookmarks(sections, authors) do
    approved =
      Enum.filter(
        sections,
        &(&1.content_review_status == :approved and &1.technical_review_status == :approved)
      )

    Enum.each(authors, fn user ->
      approved
      |> pick_many(4, {:bookmarks, user.id})
      |> Enum.each(fn section ->
        section_bookmark([section_id: section.id], user)
        |> Ash.Generator.generate()
      end)
    end)
  end

  defp seed_workspace_followers(product_data, authors) do
    product_data
    |> Enum.filter(&(&1.product.completion >= 65))
    |> Enum.each(fn %{en_ws: en_ws} ->
      authors
      |> Enum.filter(&(:erlang.phash2({en_ws.id, &1.id}, 100) < 60))
      |> Enum.each(fn user ->
        workspace_follower(
          [
            workspace_id: en_ws.id,
            notification_enabled: rem(:erlang.phash2({en_ws.id, user.id, :notify}), 3) != 0
          ],
          user
        )
        |> Ash.Generator.generate()
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Backdating
  # ---------------------------------------------------------------------------

  defp backdate(site_id, %{en: en_tags, fa: fa_tags}, product_data, drafts, issues) do
    Enum.each(en_tags ++ fa_tags, fn tag ->
      stamp(site_id, tag, spread(%{age_days: 500}, {:tag, tag.id}))
    end)

    Enum.each(product_data, &backdate_product(site_id, &1))
    Enum.each(drafts, &backdate_drafts(site_id, &1))
    Enum.each(issues, &backdate_issue(site_id, &1))
  end

  defp backdate_product(site_id, data) do
    oldest = List.first(@en_version_specs)
    stamp(site_id, data.en_ws, spread(oldest, {:workspace, data.en_ws.id}))

    Enum.each(data.translations, fn %{workspace: ws} ->
      stamp(site_id, ws, spread(List.first(@translation_version_specs), {:workspace, ws.id}))
    end)

    Enum.each(data.en_versions ++ data.translation_versions, &backdate_version(site_id, &1))
  end

  defp backdate_version(site_id, %{version: version, sections: sections, notes: notes, spec: spec}) do
    stamp(site_id, version, spread(spec, {:version, version.id}))
    Enum.each(sections, &stamp(site_id, &1, spread(spec, {:section, &1.id})))
    Enum.each(notes, &stamp(site_id, &1, spread(spec, {:note, &1.id})))
  end

  defp backdate_drafts(site_id, %{
         spec: spec,
         section_drafts: section_drafts,
         note_drafts: note_drafts
       }) do
    Enum.each(section_drafts ++ note_drafts, fn draft ->
      at =
        DateTime.add(DateTime.utc_now(), -draft_age(spec, {:draft, draft.id}) * 86_400, :second)

      stamp(site_id, draft, at)
    end)
  end

  defp backdate_issue(site_id, %{issue: issue, comments: comments, spec: spec}) do
    at = spread(%{age_days: max(div(spec.age_days, 2), 2)}, {:issue, issue.id})
    stamp(site_id, issue, at)

    Enum.each(comments, fn comment ->
      offset = rem(:erlang.phash2({:comment_at, comment.id}), 36) * 3600 + 3600
      stamp(site_id, comment, DateTime.add(at, offset, :second))
    end)
  end

  defp spread(%{age_days: age_days}, key) do
    window = max(div(age_days, 3), 1)
    days = age_days - rem(:erlang.phash2(key), window + 1)
    seconds = rem(:erlang.phash2({key, :seconds}), 86_400)

    DateTime.add(DateTime.utc_now(), -days * 86_400 - seconds, :second)
  end

  defp stamp(site_id, record, at) do
    Ash.Seed.update!(record, %{inserted_at: at, updated_at: at}, tenant: site_id)
  end

  # ---------------------------------------------------------------------------
  # Archival pass — the last write of the seed
  # ---------------------------------------------------------------------------

  defp archive_pass(site_id, tags, product_data, drafts, issues) do
    dead_workspaces = archive_translation_workspaces(site_id, product_data)
    live = live_records(product_data, dead_workspaces)

    dead_notes = archive_share(site_id, live.notes, 5)
    dead_sections = archive_sections(site_id, live, dead_notes)
    dead_tags = archive_tag_group(site_id, tags)
    dead_issues = archive_issues(site_id, issues)
    dead_comments = archive_share(site_id, live_comments(issues, dead_issues), 5)
    dead_drafts = archive_drafts(site_id, drafts)

    dead_workspaces.count + MapSet.size(dead_notes) + dead_sections + dead_tags +
      dead_issues.count + MapSet.size(dead_comments) + dead_drafts
  end

  defp archive_translation_workspaces(site_id, product_data) do
    archived =
      product_data
      |> Enum.flat_map(& &1.translations)
      |> Enum.sort_by(fn %{workspace: ws, versions: versions} ->
        {section_total(versions), :erlang.phash2({site_id, ws.id, :archive})}
      end)
      |> Enum.take(2)

    count =
      Enum.reduce(archived, 0, fn %{workspace: ws, versions: versions}, acc ->
        rows =
          Enum.reduce(versions, 0, fn %{sections: sections, notes: notes}, inner ->
            Enum.each(notes, &archive(&1, site_id))
            Enum.each(sections, &archive(&1, site_id))
            inner + length(notes) + length(sections)
          end)

        archive(ws, site_id)
        acc + rows + 1
      end)

    %{ids: MapSet.new(archived, & &1.workspace.id), count: count}
  end

  defp section_total(versions), do: Enum.reduce(versions, 0, &(&2 + length(&1.sections)))

  defp live_records(product_data, dead_workspaces) do
    Enum.reduce(product_data, %{sections: [], notes: [], masters: MapSet.new()}, fn data, acc ->
      live_translations =
        Enum.reject(data.translations, &MapSet.member?(dead_workspaces.ids, &1.workspace.id))

      translated = Enum.flat_map(live_translations, & &1.versions)
      entries = data.en_versions ++ translated

      %{
        sections: acc.sections ++ Enum.flat_map(entries, & &1.sections),
        notes: acc.notes ++ Enum.flat_map(entries, & &1.notes),
        masters:
          translated
          |> Enum.flat_map(& &1.sections)
          |> Enum.reduce(acc.masters, &MapSet.put(&2, &1.language_group_id))
      }
    end)
  end

  defp archive_sections(site_id, live, dead_notes) do
    notes_by_section = Enum.group_by(live.notes, & &1.section_id)

    live.sections
    |> Enum.reject(&(&1.order_position == 1))
    |> Enum.reject(&MapSet.member?(live.masters, &1.id))
    |> Enum.filter(&archive_pick?(site_id, &1, 8))
    |> Enum.reduce(0, fn section, acc ->
      orphans =
        notes_by_section
        |> Map.get(section.id, [])
        |> Enum.reject(&MapSet.member?(dead_notes, &1.id))

      Enum.each(orphans, &archive(&1, site_id))
      archive(section, site_id)
      acc + length(orphans) + 1
    end)
  end

  defp archive_tag_group(_site_id, %{en: []}), do: 0

  defp archive_tag_group(site_id, %{en: en_tags, fa: fa_tags}) do
    master = pick_one(en_tags, {site_id, :archive_tag})
    translation = Enum.find(fa_tags, &(&1.language_group_id == master.id))

    archived = Enum.reject([translation, master], &is_nil/1)
    Enum.each(archived, &archive(&1, site_id))
    length(archived)
  end

  defp archive_issues(site_id, issues) do
    archived =
      issues
      |> Enum.sort_by(fn %{issue: issue} ->
        {issue_archive_rank(issue.status), :erlang.phash2({site_id, issue.id, :archive})}
      end)
      |> Enum.take(4)

    count =
      Enum.reduce(archived, 0, fn %{issue: issue, comments: comments}, acc ->
        Enum.each(comments, &archive(&1, site_id))
        archive(issue, site_id)
        acc + length(comments) + 1
      end)

    %{ids: MapSet.new(archived, & &1.issue.id), count: count}
  end

  defp issue_archive_rank(status) when status in [:resolved, :closed], do: 0
  defp issue_archive_rank(_status), do: 1

  defp live_comments(issues, dead_issues) do
    issues
    |> Enum.reject(&MapSet.member?(dead_issues.ids, &1.issue.id))
    |> Enum.flat_map(& &1.comments)
  end

  defp archive_drafts(site_id, drafts) do
    section_drafts = Enum.flat_map(drafts, & &1.section_drafts)
    note_drafts = Enum.flat_map(drafts, & &1.note_drafts)

    archived =
      pick_many(section_drafts, 2, {site_id, :archive_section_drafts}) ++
        pick_many(note_drafts, 2, {site_id, :archive_note_drafts})

    Enum.each(archived, &archive(&1, site_id))
    length(archived)
  end

  defp archive_share(site_id, records, pct) do
    records
    |> Enum.filter(&archive_pick?(site_id, &1, pct))
    |> Enum.map(fn record ->
      archive(record, site_id)
      record.id
    end)
    |> MapSet.new()
  end

  defp archive_pick?(site_id, record, pct),
    do: :erlang.phash2({site_id, record.id, :archive}, 100) < pct

  defp archive(record, site_id) do
    Ash.destroy!(record, action: :destroy, tenant: site_id, authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Stress-seed building blocks
  # ---------------------------------------------------------------------------

  defp stress_version(site_id, ws, index, version_count, section_count, notes_per, tags, authors) do
    version =
      dev_workspace_version(
        [
          workspace_id: ws.id,
          site_id: site_id,
          is_latest_for_version: index == version_count
        ],
        site_id,
        pick_author(authors, {:stress_version, ws.id, index})
      )
      |> Ash.Generator.generate()

    sections =
      Enum.map(1..section_count, fn position ->
        section =
          dev_section(
            [workspace_version_id: version.id, site_id: site_id, order_position: position],
            site_id,
            pick_author(authors, {:stress_section, version.id, position})
          )
          |> Ash.Generator.generate()

        attach_tags(section, tags, :en, tag_count_for(position))
        section
      end)

    notes =
      Enum.flat_map(sections, fn section ->
        count = div(note_count(:erlang.phash2({section.id, :notes}, 100)) * notes_per, 10)

        Enum.map(1..count//1, fn position ->
          dev_note(
            [section_id: section.id, site_id: site_id, order_position: position],
            site_id,
            pick_author(authors, {:stress_note, section.id, position})
          )
          |> Ash.Generator.generate()
        end)
      end)

    %{version: version, sections: sections, notes: notes}
  end

  defp stress_issues(_site_id, [], _authors, _masters, _count), do: []
  defp stress_issues(_site_id, _sections, [], _masters, _count), do: []

  defp stress_issues(site_id, sections, authors, masters, count) do
    Enum.map(1..count, fn idx ->
      section = pick_one(sections, {:stress_issue, idx})
      outcome = issue_outcome(idx)
      issue = create_issue(site_id, :section, section, authors, idx)
      comments = create_issue_comments(site_id, issue, authors, masters, idx, outcome)

      %{issue: settle_issue(site_id, issue, outcome), comments: comments}
    end)
  end

  defp stress_archive(site_id, dead_groups, sections, notes, tags, issues) do
    dead_workspaces =
      Enum.reduce(dead_groups, 0, fn group, acc ->
        group_notes = group_notes(group)
        group_sections = group_sections(group)

        Enum.each(group_notes, &archive(&1, site_id))
        Enum.each(group_sections, &archive(&1, site_id))
        archive(group.workspace, site_id)

        acc + length(group_notes) + length(group_sections) + 1
      end)

    dead_notes = archive_share(site_id, notes, 10)

    dead_sections =
      archive_sections(
        site_id,
        %{sections: sections, notes: notes, masters: MapSet.new()},
        dead_notes
      )

    dead_tags = archive_share(site_id, tags, 10)
    dead_issues = archive_issues(site_id, issues)

    dead_workspaces + MapSet.size(dead_notes) + dead_sections + MapSet.size(dead_tags) +
      dead_issues.count
  end

  defp group_sections(%{versions: versions}), do: Enum.flat_map(versions, & &1.sections)
  defp group_notes(%{versions: versions}), do: Enum.flat_map(versions, & &1.notes)

  # ---------------------------------------------------------------------------
  # Utilities
  # ---------------------------------------------------------------------------

  defp all_sections(product_data) do
    Enum.flat_map(product_data, fn %{en_versions: ev, translation_versions: tv} ->
      Enum.flat_map(ev ++ tv, & &1.sections)
    end)
  end

  # The site's own users, else its masters. Another site's user is never one of its authors.
  defp authors_for(users, site_id) do
    tenant_users = Enum.filter(users, &(Map.get(&1, :site_id) == site_id))

    [tenant_users, masters_in(users)]
    |> first_non_empty()
    |> Enum.sort_by(& &1.email)
  end

  defp masters_in(users) do
    users
    |> Enum.filter(&is_nil(Map.get(&1, :site_id)))
    |> Enum.sort_by(& &1.email)
  end

  defp first_non_empty([[] | rest]), do: first_non_empty(rest)
  defp first_non_empty([list | _rest]), do: list
  defp first_non_empty([]), do: []

  defp pick_author([], _key), do: nil
  defp pick_author(authors, key), do: Enum.at(authors, :erlang.phash2(key, length(authors)))

  defp author_id(nil), do: nil
  defp author_id(author), do: author.id

  defp pick_many([], _count, _key), do: []

  defp pick_many(list, count, key) do
    list
    |> Enum.sort_by(&:erlang.phash2({key, &1.id}))
    |> Enum.take(count)
  end

  defp pick_one([], _key), do: nil
  defp pick_one(list, key), do: hd(pick_many(list, 1, key))
end
