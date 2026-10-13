defmodule MishkaDocument.KitTest do
  @moduledoc """
  The bundle this extension ships, and the rows installing it writes.

  ## Why the components are data and not code

  Five live components arrive as `priv/cms_ui_kits/mishka_document.json` and are installed through
  the CMS's own kit machinery — the same path Chelekom's 136 take. Everything a component is travels
  in that file: its markup, its declarations, and its own code, including the Ash reads it runs.

  That is what makes it a component rather than a library with a component-shaped wrapper. It can be
  imported one at a time or in batches, edited in the admin like any other row, and carries no
  dependency on an Elixir module a third-party importer would not have.

  ## What is asserted here and what is not

  This suite does not start the CMS's compilers — `test/test_helper.exs` says why. So what is pinned
  here is the bundle's shape and the rows the installer writes from it. Compiling them, rendering
  them on a page and clicking them is `MishkaDocument.LiveComponentsRenderTest`.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Component, JsHook, Stylesheet}

  require Ash.Query

  @moduletag :integration

  # THE TWO KINDS, AND WHICH IS WHICH. A live component runs its own reads and holds what it read;
  # a function component is markup the live ones hand their rows to. Splitting them here is what
  # lets every assertion below ask the right question of each — a function component has no socket,
  # so it has no `mount/1`, no `id={@id}` and nothing to aim an event at.
  @live ~w(doc-workspace-list doc-section doc-sidebar doc-toc doc-switcher doc-section-cards)

  @functions ~w(doc-workspace-card doc-pager doc-notice doc-callout doc-example)

  @names @live ++ @functions

  # The RESOURCES a component reads through Ash. Everything else under `MishkaDocument.` is this
  # extension's Elixir, and a component that called one would stop being installable by anyone who
  # does not also have that code.
  @resources ~w(MishkaDocument.Workspace MishkaDocument.WorkspaceVersion MishkaDocument.Section
                MishkaDocument.Note)

  # The actions a visitor may run. Every other read on these resources is behind the admin policy,
  # and a component that named one would answer a reader with a forbidden error.
  @public_actions ~w(public_list public_get public_list_at_workspace_version)

  # The reads of the document a page sits in and of its versions, the only ones made as the system:
  # a page whose own lock opens for the reader is drawn inside a document whose lock does not.
  # `doc-section-cards` reaches them from the page it is drawn in, through `version_of` and
  # `document_of`.
  @frame_reads ~w(workspace_row versions_of version_of document_of)
  @frame_resources ~w(Workspace WorkspaceVersion)

  # A read as the stored code writes it, in BOTH shapes it is written in: piped into `for_read/4`,
  # and called with the resource as its first argument — which is what a helper does when it has to
  # keep hold of the query to add a clause to it. Recognising only the first shape left
  # `doc-switcher`'s `translated_slugs` unchecked by every test below that reads this.
  @read_calls [
    ~r/MishkaDocument\.(\w+)\s*\|>\s*Ash\.Query\.for_read\(\s*:(\w+)/,
    ~r/Ash\.Query\.for_read\(\s*MishkaDocument\.(\w+),\s*:(\w+)/
  ]

  # The columns one read asks the database for.
  @select_call ~r/Ash\.Query\.select\(\s*\[(.*?)\]\s*\)/s

  setup do
    site = create_site!(name: "docville", host: "docville.test", active: true)
    {:ok, _installed} = MishkaDocument.Kit.install!(site.id)
    {:ok, site: site}
  end

  defp bundle, do: MishkaDocument.Kit.bundle_path() |> File.read!() |> Jason.decode!()

  # The components one component's markup draws, read off the template the way
  # `MishkaCmsCore.Runtime.CssClosure` reads reachability: the literal name in the call, never a
  # name built at runtime — `doc-workspace-list`'s `card` attribute is an author's choice and
  # belongs to no bundle.
  defp drawn_siblings(component) do
    ~r/component_name="([^"]+)"/
    |> Regex.scan(component["template"])
    |> Enum.map(fn [_whole, name] -> name end)
    |> Enum.uniq()
  end

  defp components, do: bundle()["components"]

  defp row(name, site) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^name and site_id == ^site.id)
    |> Ash.read_one!()
  end

  describe "the bundle" do
    test "is a v3 kit bundle, which is what the installer reads" do
      assert bundle()["$schema"] == "mishka.ui_kit.bundle.v3"
      assert bundle()["name"] == "mishka_document"
    end

    test "ships exactly the eleven components, each of the kind it is listed under" do
      assert Enum.map(components(), & &1["name"]) |> Enum.sort() == Enum.sort(@names)

      for component <- components() do
        assert component["stateful"] == component["name"] in @live,
               "#{component["name"]} is the other kind of component"
      end
    end

    # THE POINT OF THE WHOLE SHAPE. A component's stored code may call the standard library, Ash and
    # Phoenix, and its own helpers — and nothing of this extension's. The moment one reaches for a
    # `MishkaDocument.*` function it stops being installable by anyone who does not also have this
    # Elixir code, which is the coupling a bundle exists to remove.
    #
    # `@resources` are RESOURCES, not helpers: a component reads documents the way any caller does,
    # through Ash.
    test "and no component's code calls into this extension's own modules" do
      for component <- components(), helper <- component["helpers"] do
        offenders =
          ~r/MishkaDocument\.[A-Za-z.]+/
          |> Regex.scan(helper["code"])
          |> List.flatten()
          |> Enum.reject(&(&1 in @resources))

        assert offenders == [],
               "#{component["name"]}'s #{helper["name"]} calls #{inspect(offenders)}"
      end
    end

    test "and neither does any template" do
      for component <- components() do
        offenders =
          ~r/MishkaDocument\.[A-Za-z.]+/
          |> Regex.scan(component["template"])
          |> List.flatten()
          |> Enum.reject(&(&1 in @resources))

        assert offenders == [], "#{component["name"]}'s template calls #{inspect(offenders)}"
      end
    end

    # A READER IS NOT AN ADMIN. Every read these components run has to be one of the actions whose
    # policy lets anybody through — and those are the same actions that filter to approved pages of
    # published versions of active documents, so naming them is also what keeps a draft out of a
    # visitor's page.
    test "and reads only through the actions a visitor is allowed to run" do
      seen =
        for component <- components(),
            helper <- component["helpers"],
            [_whole, resource, action] <- reads(helper["code"]) do
          assert action in @public_actions,
                 "#{component["name"]}'s #{helper["name"]} reads #{resource} through :#{action}, " <>
                   "which a visitor may not run"

          action
        end

      assert seen != [], "no read was recognised, so this asserts nothing"
    end

    # AND EVERY ONE OF THEM WAS LOOKED AT. The check above and the page cap below both work off a
    # pattern, and a read written in a shape that pattern does not know is not a read that fails
    # them — it is a read they never see. `assert seen != []` cannot notice, because every other
    # read in the bundle keeps that list full.
    test "and every read it runs is one of the reads those checks recognise" do
      for component <- components(), helper <- component["helpers"] do
        assert length(reads(helper["code"])) == for_reads(helper["code"]),
               "#{component["name"]}'s #{helper["name"]} runs #{for_reads(helper["code"])} reads " <>
                 "and only #{length(reads(helper["code"]))} of them are written in a shape the " <>
                 "checks above recognise"
      end
    end

    # A PAGE IS READ FOR THE READER IT IS DRAWN FOR. An action that keeps pages to what its reader
    # may open (`MishkaDocument.Resources.Preparations.OpenToActor`, `kind: :section`) reads as the
    # system, and hands over every locked page, when it is not told who is reading. A document and
    # its versions are looked up as the system: a page whose own lock opens for the reader is
    # reachable inside a document that does not.
    test "and every read of a page names the visitor it reads for" do
      kept =
        for component <- components(),
            helper <- component["helpers"],
            {resource, action, given} <- read_calls(helper["code"]),
            reads_a_page?(resource, action) do
          assert given =~ "read_as(",
                 "#{component["name"]}'s #{helper["name"]} reads #{resource} through :#{action} " <>
                   "without naming the visitor"

          action
        end

      assert kept != [], "no read of a page was recognised, so this asserts nothing"
    end

    # AND READS AS THAT VISITOR, through the public action's own policies. `authorize?: false` skips
    # every rule the action keeps, for every visitor at once, so only `@frame_reads` use it, and only
    # of `@frame_resources`; every other read is handed `read_as/1`.
    test "and reads as the visitor, never as the system, but for the document a page sits in" do
      seen =
        for component <- components(),
            helper <- component["helpers"],
            {resource, action, given} <- read_calls(helper["code"]) do
          case given =~ "authorize?: false" do
            true ->
              assert helper["name"] in @frame_reads and resource in @frame_resources,
                     "#{component["name"]}'s #{helper["name"]} reads #{resource} as the system"

            false ->
              assert given =~ "read_as(",
                     "#{component["name"]}'s #{helper["name"]} reads #{resource} through " <>
                       ":#{action} without naming the visitor"
          end

          helper["name"]
        end

      assert seen != [], "no read was recognised, so this asserts nothing"

      for component <- components(),
          helper <- component["helpers"],
          helper["name"] not in @frame_reads do
        refute helper["code"] =~ "authorize?: false",
               "#{component["name"]}'s #{helper["name"]} reads as the system"
      end

      read_as =
        for component <- components(),
            helper <- component["helpers"],
            helper["name"] == "read_as",
            do: {component["name"], helper["code"]}

      assert read_as != [], "no component carries read_as/1, so this asserts nothing"

      for {name, code} <- read_as do
        assert code =~ "actor: visitor", "#{name}'s read_as/1 does not read as the visitor"
      end
    end

    # AND AS THIS SITE, ALWAYS. The tenant comes from the component's own compiled metadata, so a
    # read that forgot it would either raise or — for a resource that tolerates it — answer with
    # another site's documents.
    test "and every read names the site the component was installed for" do
      seen =
        for component <- components(),
            helper <- component["helpers"],
            given <- ash_reads(helper["code"]) do
          assert given =~ "tenant: site_id()",
                 "#{component["name"]}'s #{helper["name"]} runs a read that does not name the site"
        end

      assert seen != [], "no read was recognised, so this asserts nothing"
    end

    # A TASK READS IN THE PAGE'S SITE AND LOCALE ONLY WHEN IT IS HANDED THEM. Phoenix's own
    # `start_async/3` and `assign_async/3` start one with neither, and `site_path/2` in it builds no
    # link at all; the host's `MishkaCms.AsyncLocaleTest` holds Elixir code to the same rule, and
    # does not read this bundle.
    test "and every block that reads in the background starts its task through Gervaz" do
      started =
        for component <- components(),
            helper <- component["helpers"],
            helper["code"] =~ ~r/\b(start|assign)_async\(/ do
          refute helper["code"] =~ ~r/Phoenix\.LiveView\.(start_async|assign_async)\(/,
                 "#{component["name"]}'s #{helper["name"]} starts a task through Phoenix's own " <>
                   "— use MishkaGervaz.Messages.start_async/4"

          assert helper["code"] =~ "MishkaGervaz.Messages.start_async(",
                 "#{component["name"]}'s #{helper["name"]} starts a task some other way"

          component["name"]
        end

      assert Enum.sort(started) ==
               ~w(doc-section doc-section-cards doc-sidebar doc-switcher doc-toc doc-workspace-list)
    end

    # A READ THAT FAILS IS A TUPLE THE BLOCK DRAWS ITS ERROR FROM, on the builder's canvas as in a
    # task; anything else is a bug, and is let crash.
    test "and catches nothing: no rescue, catch or try" do
      for component <- components(), helper <- component["helpers"] do
        code = String.replace(helper["code"], ~r/^\s*#.*$/m, "")

        refute code =~ ~r/\b(rescue|catch|try)\b/,
               "#{component["name"]}'s #{helper["name"]} catches what it should let crash"
      end
    end

    # EVERY ASSIGN THE MARKUP READS IS DECLARED, or the component raises inside a visitor's LiveView
    # the first time a page leaves that attribute out.
    test "declares every assign its own markup reads" do
      # `streams` IS LIVEVIEW'S OWN. `Phoenix.LiveView.stream/4` puts it on the socket and there is
      # no attribute to declare it with — a block that streams its rows reads `@streams.documents`
      # and declares `documents` nowhere.
      injected = ~w(id rest myself socket flash inner_block streams)

      for component <- components() do
        declared = MapSet.new(component["attrs"], & &1["name"])
        slots = MapSet.new(component["slots"] || [], & &1["name"])
        local = MapSet.new(read_assigns(component["template"]))

        missing =
          local
          |> MapSet.difference(declared)
          |> MapSet.difference(slots)
          |> MapSet.difference(MapSet.new(injected))
          |> MapSet.difference(MapSet.new(lifecycle_assigns(component)))

        assert MapSet.size(missing) == 0,
               "#{component["name"]} reads #{inspect(MapSet.to_list(missing))} and declares none of it"
      end
    end

    # AND HOLDS NO STATE UNDER THE NAME OF ONE OF ITS OWN ATTRIBUTES. `update_many/1` puts the
    # parent's assigns on the socket before `update/2` runs, so an attribute and a lifecycle assign
    # sharing a name are ONE key — and an event, which does not go through `update_many/1`, then
    # reads back whatever `load/1` last wrote there instead of what the page set.
    #
    # Measured: `doc-sidebar` held the resolved workspace under `workspace`, its own slug attribute.
    # The first render was right, and the first letter a reader typed into its filter handed a
    # `%Workspace{}` to the code expecting that slug and took the whole page down with it.
    test "and holds no piece of state under the name of one of its own attributes" do
      for component <- components() do
        declared = MapSet.new(component["attrs"], & &1["name"])

        clashing = Enum.filter(lifecycle_assigns(component), &MapSet.member?(declared, &1))

        assert clashing == [],
               "#{component["name"]} keeps #{inspect(clashing)} on the socket and declares the " <>
                 "same name as an attribute, so its first event overwrites the page's value"
      end
    end

    # PLAIN HTML AND TAILWIND, AND NOBODY ELSE'S COMPONENTS. A site may install this extension and
    # skip Chelekom — the installer's component step offers it and nothing forces it — and a
    # documentation page drawn with `chelekom-card` and friends would be a column of the runtime's
    # red "failed to render" boxes on every such site.
    test "and draws itself without another kit, which a production site may not have installed" do
      for component <- components() do
        refute component["template"] =~ "chelekom-",
               "#{component["name"]} calls Chelekom, and a site that skipped it renders a red box"

        for called <- drawn_siblings(component) do
          assert called in @names,
                 "#{component["name"]} draws #{called}, which this bundle does not ship"
        end
      end
    end

    # A SIBLING IT DRAWS IS A SIBLING IT NEEDS. The split gave the live blocks function components
    # to draw their rows and their states with, and `<.component component_name="doc-notice"/>`
    # against a site with no such row is the runtime's red "failed to render" box — so the row says
    # what it needs, in the field the admin's component list already shows and
    # `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` reads when it carries an update onto a site that
    # was installed before the split.
    test "and every component it draws is a dependency it declares, and the reverse" do
      for component <- components() do
        called = drawn_siblings(component)

        for name <- called do
          assert name in component["dependencies"],
                 "#{component["name"]} draws #{name} and declares no dependency on it"
        end

        for declared <- component["dependencies"] do
          assert declared in called,
                 "#{component["name"]} declares #{declared} and its template never draws it"
        end
      end
    end

    # NOTHING IS SHIPPED FOR NOBODY. A function component exists to be drawn by another component;
    # one no other row names is a row a site compiles, an admin reads and the palette offers, and
    # nothing draws.
    test "and every function component is drawn by another" do
      needed =
        components()
        |> Enum.flat_map(& &1["dependencies"])
        |> Enum.uniq()

      for name <- @functions do
        assert name in needed, "#{name} is drawn by nothing this bundle ships"
      end
    end

    # THE ONE COMPONENT THAT CALLS ANOTHER NAMES NONE OF ITS OWN. `doc-workspace-list` draws each
    # document through whatever component an author puts in its `card` attribute, which is the whole
    # of that feature: a name this bundle wrote down instead would be a dependency on a kit, and
    # `dependencies: []` above would be a lie.
    test "and the only component it calls through an assign is one an author chose" do
      called =
        for component <- components(),
            [_whole, name] <-
              Regex.scan(
                ~r/<\.component\b[^>]*?component_name=\{([^}]+)\}/s,
                component["template"]
              ) do
          assert Regex.match?(~r/^@\w+$/, String.trim(name)),
                 "#{component["name"]} calls a component named #{name}, which no author chose"

          component["name"]
        end

      assert called == ["doc-workspace-list"],
             "the set of components that call another one by assign has changed: #{inspect(called)}"
    end

    # EDITOR HINTS ARE PART OF THE COMPONENT, not documentation kept somewhere else. The inspector
    # reads `opts.doc` for the line under a control and `opts.values` for a dropdown in place of a
    # text box — see `MishkaCmsCore.Runtime.PageBuilder.Inspector` — so an attribute shipping
    # neither is a blank field an author has to guess the accepted words for.
    test "and every author-facing attribute explains itself to the inspector" do
      for component <- components(),
          attr <- component["attrs"],
          attr["type"] != "global" do
        assert attr["opts"]["doc"] not in [nil, ""],
               "#{component["name"]}'s #{attr["name"]} has nothing to say for itself"

        assert Map.has_key?(attr["opts"], "default"),
               "#{component["name"]}'s #{attr["name"]} declares no default, so a page that leaves " <>
                 "it out raises rather than falling back"
      end
    end

    test "and the ones with a fixed set of answers offer that set" do
      for component <- components(),
          attr <- component["attrs"],
          attr["name"] in ~w(sort show tone) do
        values = attr["opts"]["values"]

        assert is_list(values) and values != [],
               "#{component["name"]}'s #{attr["name"]} is a dropdown with nothing in it"

        assert attr["opts"]["default"] in values,
               "#{component["name"]}'s #{attr["name"]} defaults to a word it does not offer"
      end
    end

    # NOBODY MAY ASK FOR MORE ROWS THAN THEY WILL BE GIVEN. Every public read these components run
    # caps a page, and Ash SHRINKS a larger ask down to that cap rather than refusing it — so an
    # over-ask is silent, and a list that quietly stops short of what an author asked for is a
    # document with pages missing from its contents. The ceiling is read off the actions the
    # components name, not written down here.
    test "and never asks a read for more rows than that read will hand back" do
      caps =
        for component <- components(),
            helper <- component["helpers"],
            [_whole, resource, action] <- reads(helper["code"]),
            cap = page_cap(resource, action),
            is_integer(cap),
            do: cap

      assert caps != [], "no read was recognised, so this asserts nothing"
      ceiling = Enum.min(caps)

      for component <- components(),
          helper <- component["helpers"],
          [_whole, asked] <- Regex.scan(~r/page: \[limit: (\d+)/, helper["code"]) do
        assert String.to_integer(asked) <= ceiling,
               "#{component["name"]}'s #{helper["name"]} asks for #{asked} rows and is given #{ceiling}"
      end

      for component <- components(),
          attr <- component["attrs"],
          is_integer(attr["opts"]["max"]) do
        assert attr["opts"]["max"] <= ceiling,
               "#{component["name"]}'s #{attr["name"]} lets an author ask for " <>
                 "#{attr["opts"]["max"]}, and #{ceiling} is what one read returns"
      end
    end

    # AND SELECTS NO COLUMN NOBODY READS, which is the same rule one level down. Every read here
    # names the columns it wants, so a name left in that list after the code reading it went is a
    # wider row fetched on every render for nobody — the five carry their own copies of these
    # helpers precisely so they can ask for different columns, and a copy that differs only in dead
    # ones is a copy that costs without paying.
    #
    # A column counts as read where the component's own code or markup reaches for it by name —
    # `row.status`, `%{status: status}`, `sort(status: :asc)` — and a filter does not count: a
    # `WHERE` clause is answered by the database whether the column comes back or not.
    test "and selects no column its own template and code never read" do
      for component <- components() do
        code = Enum.map_join(component["helpers"], "\n", & &1["code"])

        # A COLUMN THE CARD IT DRAWS READS IS A COLUMN IT HAS TO SELECT. The list reads the rows and
        # hands each one to a function component, so `description` and `featured` are read in
        # `doc-workspace-card`'s markup and nowhere in the block that selected them.
        drawn =
          for sibling <- components(),
              sibling["name"] in component["dependencies"],
              do: sibling["template"]

        readable =
          Enum.join(
            [String.replace(code, @select_call, " "), component["template"] | drawn],
            "\n"
          )

        dead =
          for [_whole, listed] <- Regex.scan(@select_call, code),
              [_field, name] <- Regex.scan(~r/:(\w+)/, listed),
              not Regex.match?(~r/\.#{name}\b/, readable),
              not Regex.match?(~r/\b#{name}:/, readable),
              do: name

        assert dead == [],
               "#{component["name"]} selects #{inspect(Enum.uniq(dead))} and reads none of it"
      end
    end

    # A HELPER NOBODY CALLS IS CODE A SITE STILL COMPILES AND AN ADMIN STILL READS. Five components
    # share one set of small helpers, and each carries only its own copies, so a helper dropped from
    # a template has to be dropped from the component too. A helper is called as a function, or, when
    # it is a function component, as `<.name …>`.
    test "and ships no helper its own template and code never call" do
      lifecycle = ~w(mount update update_many render handle_event handle_async site_id)

      for component <- components(),
          name <- Enum.uniq(Enum.map(component["helpers"], & &1["name"])),
          name not in lifecycle do
        callers =
          [
            component["template"]
            | for(h <- component["helpers"], h["name"] != name, do: h["code"])
          ]
          |> Enum.join()

        assert callers =~ ~r/\b#{Regex.escape(name)}\s*\(|<\.#{Regex.escape(name)}\b/,
               "#{component["name"]} carries #{name}/n and calls it nowhere"
      end
    end

    # AND IT HAS TO TRAVEL. `MishkaDocument.Kit.bundle_path/0` reads the file out of
    # `:code.priv_dir/1`, and `priv` used to be left out of the package's `files` — so a hex install
    # of this extension would point at a path that does not exist and give that site no document
    # components at all. Nothing else in this suite could notice: a checkout has `priv` whether the
    # package ships it or not.
    test "and travels inside the hex package" do
      files = Mix.Project.config()[:package][:files]

      assert Enum.any?(files, &(&1 in ~w(priv priv/cms_ui_kits))),
             "the bundle's directory is not in the package, so a hex install has nothing to read"
    end

    test "ships exactly two hooks, one for the code windows and one for the examples" do
      assert Enum.map(bundle()["js_hooks"], & &1["name"]) == ["doc-code-copy", "doc-example"]
    end

    # THE COPY BUTTON ON A CODE WINDOW IS ANSWERED IN THE BROWSER, by the hook `doc-section` mounts
    # on its root under the name `copy_hook/0` asks the rule the site's JavaScript is built with for.
    # It writes no style attribute and no markup, which a site's CSP and a LiveView patch would each
    # undo.
    test "ships the hook doc-section mounts for the copy button on its code windows" do
      hook = Enum.find(bundle()["js_hooks"], &(&1["name"] == "doc-code-copy"))
      assert hook["name"] == "doc-code-copy"
      assert hook["format"] == "js"
      assert hook["active"] == true
      assert hook["content"] =~ "export default DocCodeCopy;"
      assert hook["content"] =~ ~s([data-role="doc-code-copy"])
      assert hook["content"] =~ "navigator.clipboard"
      assert hook["content"] =~ ~s|document.execCommand("copy")|
      assert hook["content"] =~ ~s|setAttribute("data-copied", "true")|
      assert hook["content"] =~ ~s|removeAttribute("data-copied")|
      refute hook["content"] =~ ~r/setAttribute\(\s*["']style["']|innerHTML|insertAdjacentHTML/

      section = Enum.find(components(), &(&1["name"] == "doc-section"))
      copy_hook = Enum.find(section["helpers"], &(&1["name"] == "copy_hook"))

      assert section["template"] =~ ~r/\A<div\n  id=\{@id\}\n[^>]*phx-hook=\{copy_hook\(\)\}/

      assert copy_hook["code"] =~
               "MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler.browser_name("

      assert copy_hook["code"] =~ ~s(name: "doc-code-copy")
    end

    # WHAT A PLUGIN ADDS TO A PAGE is asked through `Hook.call/3`, which hands the state back when
    # the event cannot run, and a command it adds is copied by the same hook as a code window.
    test "asks plugins for a page's extras through the event that falls back to the page" do
      section = Enum.find(components(), &(&1["name"] == "doc-section"))
      asks = Enum.find(section["helpers"], &(&1["name"] == "ask_extras"))

      assert asks["code"] =~
               ~s|MishkaInstaller.Event.Hook.call("document:page:extras", asked)|

      # What is still being fetched is waited for on the topic the plugin names, never polled.
      waits = Enum.find(section["helpers"], &(&1["name"] == "wait_for_extras"))
      assert waits["code"] =~ "Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, &1)"
      assert waits["code"] =~ "after\n            wait ->"
      refute Enum.any?(section["helpers"], &(&1["code"] =~ ~r/Process\.send_after|:timer\./))

      for drawn <- ~w(doc_extras doc_tab_bar doc_tab_panels) do
        assert section["template"] =~ "<.#{drawn}\n      :if={@extras."
      end

      hook = Enum.find(bundle()["js_hooks"], &(&1["name"] == "doc-code-copy"))
      assert hook["content"] =~ ~s([data-role="doc-extra-command"])
    end

    # A LONG CODE BLOCK AND A TALL EXAMPLE ARE CUT AT A HEIGHT THE STYLESHEET DRAWS, never one a style
    # attribute sets: every height an author may choose has its rule. The hooks mark what is shown
    # whole through their JS commands, which a LiveView patch keeps.
    test "cuts a long code block and a tall example only at heights its stylesheet draws" do
      [sheet] = bundle()["stylesheets"]

      for {component, attr, rule} <- [
            {"doc-section", "code_lines", ~s([data-role="doc-code"][data-collapse-lines="~s"])},
            {"doc-example", "collapse_height",
             ~s([data-role="doc-example"][data-collapse-height="~s"])}
          ] do
        %{"opts" => %{"values" => values, "default" => default}} =
          components()
          |> Enum.find(&(&1["name"] == component))
          |> Map.fetch!("attrs")
          |> Enum.find(&(&1["name"] == attr))

        assert default in values

        for value <- values, value != 0 do
          assert sheet["content"] =~ String.replace(rule, "~s", Integer.to_string(value)),
                 "#{component}'s #{attr} offers #{value} and the stylesheet draws no cut for it"
        end
      end

      copy = Enum.find(bundle()["js_hooks"], &(&1["name"] == "doc-code-copy"))
      assert copy["content"] =~ ~s|js.setAttribute(frame, "data-expanded", "true")|
      assert copy["content"] =~ ~s|js.setAttribute(expand, "aria-expanded"|

      example = Enum.find(bundle()["js_hooks"], &(&1["name"] == "doc-example"))
      assert example["content"] =~ ~s|this.js().setAttribute(this.el, "data-collapsible", "true")|
      assert example["content"] =~ ~s|js.setAttribute(this.el, "data-expanded", "true")|

      for hook <- [copy, example] do
        refute hook["content"] =~ ~r/setAttribute\(\s*[^,]+,\s*["']style["']|innerHTML/
      end
    end

    # AN EXAMPLE'S TOOLBAR IS ANSWERED IN THE BROWSER, by the hook `doc-example` mounts on its own
    # root under the name `example_hook/0` asks the same rule for. It moves the choice onto the root,
    # the buttons and the example's stage through the hook's JS commands, which a LiveView patch
    # keeps, opens the preview as a modal dialog, dresses the frame's page, and sizes the frame
    # through its `width` and `height` attributes and scales it through CSSOM properties — never a
    # style attribute, which a site's CSP may refuse.
    test "ships the hook doc-example mounts for the toolbar over its example" do
      hook = Enum.find(bundle()["js_hooks"], &(&1["name"] == "doc-example"))
      content = hook["content"]

      assert hook["format"] == "js"
      assert hook["active"] == true
      assert content =~ "export default DocExample;"
      assert content =~ ~s([data-role="doc-example-option"])
      assert content =~ ~s([data-role="doc-example-frame"])
      assert content =~ "js.setAttribute(this.el, `data-frame-${action}`, value)"
      assert content =~ ~s|js.setAttribute(option, "aria-pressed"|
      assert content =~ ~s|js.setAttribute(stage, "dir", value)|
      assert content =~ "this.preview.showModal()"
      assert content =~ ~s|frame.setAttribute("srcdoc", frame.getAttribute("data-document"))|
      assert content =~ ~s|root.setAttribute("data-theme", theme)|
      assert content =~ ~s|root.setAttribute("dir", dir)|
      assert content =~ ~s|frame.setAttribute("width", String(width))|
      assert content =~ ~s|frame.setAttribute("height", String(Math.max(height, 1)))|
      assert content =~ "desktop: 1280, tablet: 768, mobile: 375"
      assert content =~ "new ResizeObserver("

      assert content
             |> then(&Regex.scan(~r/\.style\.(\w+)\s*=/, &1))
             |> Enum.map(&List.last/1)
             |> Enum.uniq() ==
               ~w(transform width height)

      refute content =~
               ~r/setAttribute\(\s*[^,]+,\s*["']style["']|\.style\s*=|cssText|innerHTML|insertAdjacentHTML|srcdoc\s*=/

      example = Enum.find(components(), &(&1["name"] == "doc-example"))
      example_hook = Enum.find(example["helpers"], &(&1["name"] == "example_hook"))

      assert example["template"] =~
               ~r/\A<div\n  id=\{@id\}\n[^>]*phx-hook=\{@id && example_hook\(\)\}/

      assert example_hook["code"] =~
               "MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler.browser_name("

      assert example_hook["code"] =~ ~s(name: "doc-example")
    end

    # THE EXAMPLE IS DRAWN ON THE PAGE, where its components' scripts run; its preview is a frame
    # that holds all the example needs and nothing more: its page links the site's stylesheet and
    # carries no script, and the sandbox grants only the same origin the hook reads it through. The
    # dialog it opens in is the browser's once drawn, so a LiveView patch never closes it.
    test "draws its example on the page, and a preview in a frame that runs nothing" do
      example = Enum.find(components(), &(&1["name"] == "doc-example"))
      template = example["template"]

      assert template =~ ~s(data-role="doc-example-body")
      assert template =~ "{example}"
      assert template =~ ~s(phx-update="ignore")
      assert template =~ ~s(<dialog)
      assert template =~ ~s(sandbox="allow-same-origin")
      assert template =~ "data-document={document}"
      refute template =~ "srcdoc"
      refute template =~ "allow-scripts"
      refute template =~ ~r/\sstyle=/

      page = Enum.find(example["helpers"], &(&1["name"] == "frame_page"))
      refute page["code"] =~ "<script"

      link = Enum.find(example["helpers"], &(&1["name"] == "stylesheet_link"))
      assert link["code"] =~ "MishkaCmsCore.Runtime.Compilers.Shared.site_css_href("
    end

    # A `<details>` DRAWN AS A MENU CLOSES WHEN THE READER LEAVES IT, on a click outside it and on
    # Escape, by pressing its own summary while it is open, and a patch leaves its `open` as the
    # reader left it: LiveView's own JS commands, no hook of its own.
    test "closes every menu it draws on a click outside it and on Escape" do
      menus =
        for component <- components(),
            code <- [component["template"] | Enum.map(component["helpers"], & &1["code"])],
            tag <- Regex.scan(~r/<details\b[^>]*>/s, code) |> List.flatten(),
            do: {component["name"], tag}

      assert menus != [], "no <details> was found, so this asserts nothing"

      closes = ~s|{JS.dispatch("click", to: {:inner, ":scope[open] summary"})}|

      for {name, tag} <- menus do
        assert tag =~ ~s|phx-click-away=#{closes}|,
               "#{name} draws a menu a click outside it leaves open"

        assert tag =~ ~s|phx-window-keydown=#{closes}| and tag =~ ~s|phx-key="Escape"|,
               "#{name} draws a menu Escape leaves open"

        assert tag =~ ~s|phx-mounted={JS.ignore_attributes(["open"])}|,
               "#{name} draws a menu a patch closes"

        refute tag =~ "JS.remove_attribute(", "#{name} closes a menu with a sticky command"
      end
    end

    test "puts the id LiveView requires onto every live component's root element" do
      for component <- components(), component["stateful"] do
        assert component["template"] =~ "id={@id}",
               "#{component["name"]} has no id on its root, and a live component cannot exist without one"
      end
    end

    # A LIVE COMPONENT THAT NEITHER ANSWERS NOR LEADS ANYWHERE is a picture. `href=` counts because
    # `doc-toc` links inside the page it is drawn on and has nowhere to navigate to.
    test "carries a mount, and either answers its own controls or leads somewhere" do
      for component <- components(), component["stateful"] do
        names = Enum.map(component["helpers"], & &1["name"])

        assert "mount" in names,
               "#{component["name"]} has no mount/1, so it starts with no state"

        assert component["template"] =~ "phx-target={@myself}" or
                 component["template"] =~ "target={@myself}" or
                 component["template"] =~ "patch=" or
                 component["template"] =~ "navigate=" or
                 component["template"] =~ "href=",
               "#{component["name"]} neither answers its own events nor links anywhere"
      end
    end

    # A FUNCTION COMPONENT HAS NOTHING TO HOLD STATE IN, and the compiler gives it a module shape
    # with no socket in it: a `mount/1` there would never be called and a `phx-target={@myself}`
    # would render `phx-target=""`. Whatever answers a click in one of them is aimed at the live
    # block above it, which is handed over as `target`.
    test "and no function component pretends to be live" do
      for component <- components(), not component["stateful"] do
        names = Enum.map(component["helpers"], & &1["name"])

        for callback <- ~w(mount update handle_event handle_async) do
          refute callback in names,
                 "#{component["name"]} declares #{callback}, which nothing will ever call"
        end

        refute component["template"] =~ "@myself",
               "#{component["name"]} aims an event at a socket it does not have"
      end
    end
  end

  describe "installing" do
    test "writes a row per component, each of its own kind and scoped to the site", %{site: site} do
      for name <- @names do
        found = row(name, site)

        assert found, "#{name} was not installed"
        assert found.stateful == name in @live
        assert found.site_id == site.id
        assert found.template != "", "#{name} arrived with no markup"

        assert found.helpers != [] or name in @functions,
               "#{name} arrived with no code"
      end
    end

    test "twice changes nothing and raises nothing", %{site: site} do
      before = row("doc-section", site)

      assert {:ok, _again} = MishkaDocument.Kit.install!(site.id)

      after_second = row("doc-section", site)
      assert after_second.id == before.id
      assert length(after_second.helpers) == length(before.helpers)
    end

    # THE COLOURS OF A HIGHLIGHTED PAGE travel with the components. Every class Makeup's own Monokai
    # style colours is coloured here, read off Makeup rather than listed in this test.
    test "writes the stylesheet a highlighted code block is coloured by", %{site: site} do
      reader = create_user_with_permissions!(["admin:dashboard:runtime:stylesheet"])

      sheet =
        Stylesheet
        |> Ash.Query.for_read(:read, %{}, actor: reader, tenant: site.id)
        |> Ash.Query.filter(name == "doc-code-highlight" and site_id == ^site.id)
        |> Ash.read_one!()

      assert sheet, "the stylesheet was not installed"
      assert sheet.kind == :base
      assert sheet.content =~ "background-color: #272822"

      monokai = Makeup.stylesheet(:monokai_style, "highlight")

      for [class] <- Regex.scan(~r/^\.highlight \.([\w-]+) \{/m, monokai, capture: :all_but_first),
          class != "hll" do
        assert sheet.content =~ ".highlight .#{class} {", "nothing colours .#{class}"
      end

      for drawn <- ~w(doc-code doc-code-head doc-code-lang doc-code-copy doc-code-status) do
        assert sheet.content =~ ~s([data-role="#{drawn}"] {), "nothing draws #{drawn}"
      end

      assert sheet.content =~ ~s([data-role="doc-code-copy"][data-copied] {)
    end

    test "writes the hooks the copy buttons and the examples are answered by, for the site",
         %{site: site} do
      for shipped <- bundle()["js_hooks"] do
        name = shipped["name"]

        hook =
          JsHook
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(name == ^name and site_id == ^site.id)
          |> Ash.read_one!()

        assert hook, "#{name} was not installed"
        assert hook.active
        assert hook.format == :js
        assert String.trim(hook.content) == String.trim(shipped["content"])
      end
    end

    # LAZY BY DEFAULT, like any other component. `precompile: true` is for a component a site cannot
    # afford to compile on the first request; these are ordinary and compile when first called.
    test "leaves them to compile on first use rather than at boot", %{site: site} do
      for name <- @names do
        assert row(name, site).precompile == false,
               "#{name} asks to be compiled at boot, which it does not need"
      end
    end

    # PER SITE, because a document belongs to a tenant. Installing for one site writes that site's
    # rows and nobody else's.
    test "writes rows for the site it was given and no other", %{site: site} do
      elsewhere = create_site!(name: "elsewhere", host: "elsewhere.test", active: true)

      for name <- @names do
        assert row(name, site)

        assert Component
               |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
               |> Ash.Query.filter(name == ^name and site_id == ^elsewhere.id)
               |> Ash.read_one!() == nil,
               "#{name} was installed for a site nobody asked about"
      end
    end
  end

  # Every read in a piece of stored code, in whichever shape it was written.
  defp reads(code), do: Enum.flat_map(@read_calls, &Regex.scan(&1, code))

  # And how many reads are in there at all, so a shape nobody thought of is a failure rather than a
  # read the checks above quietly never look at.
  defp for_reads(code), do: length(Regex.scan(~r/Ash\.Query\.for_read\(/, code))

  # Every read in `code`, piped or called with its resource first: the resource, the action, and
  # everything `for_read` is handed.
  defp read_calls(code) do
    for [{at, length}] <- Regex.scan(~r/Ash\.Query\.for_read\(/, code, return: :index) do
      given = code |> binary_part(at + length, byte_size(code) - at - length) |> call_body()

      case Regex.run(~r/^\s*MishkaDocument\.(\w+),\s*:(\w+)/, given) do
        [_whole, resource, action] ->
          {resource, action, given}

        nil ->
          [_whole, resource] =
            Regex.run(~r/MishkaDocument\.(\w+)\s*\|>\s*\z/, binary_part(code, 0, at))

          [_whole, action] = Regex.run(~r/^\s*:(\w+)/, given)
          {resource, action, given}
      end
    end
  end

  # What every `Ash.read/2` in `code` is handed.
  defp ash_reads(code) do
    for [{at, length}] <- Regex.scan(~r/Ash\.read\(/, code, return: :index),
        do: code |> binary_part(at + length, byte_size(code) - at - length) |> call_body()
  end

  # What a call is handed, up to the parenthesis that closes it.
  defp call_body(rest) do
    rest
    |> String.graphemes()
    |> Enum.reduce_while({1, []}, fn
      ")", {1, taken} -> {:halt, {0, taken}}
      ")", {depth, taken} -> {:cont, {depth - 1, [")" | taken]}}
      "(", {depth, taken} -> {:cont, {depth + 1, ["(" | taken]}}
      char, {depth, taken} -> {:cont, {depth, [char | taken]}}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp reads_a_page?(resource, action) do
    module = Module.concat(MishkaDocument, resource)
    Code.ensure_loaded!(module)

    module
    |> Ash.Resource.Info.action(String.to_existing_atom(action))
    |> Map.fetch!(:preparations)
    |> Enum.any?(
      &match?(
        %Ash.Resource.Preparation{
          preparation: {MishkaDocument.Resources.Preparations.OpenToActor, [kind: :section]}
        },
        &1
      )
    )
  end

  # How many rows one page of that action hands back, whatever a caller asks for.
  defp page_cap(resource, action) do
    module = Module.concat(MishkaDocument, resource)
    Code.ensure_loaded!(module)

    case Ash.Resource.Info.action(module, String.to_existing_atom(action)) do
      %{pagination: %{max_page_size: most}} -> most
      _unpaged -> nil
    end
  end

  defp read_assigns(template) do
    ~r/@([a-z_][a-zA-Z0-9_]*)/
    |> Regex.scan(template)
    |> Enum.map(fn [_whole, name] -> name end)
    |> Enum.uniq()
  end

  # An assign a component's own lifecycle puts on the socket is not an attribute and is not
  # declared. WHICH names those are is read out of the component rather than listed here: `mount/1`
  # is where a live component states everything it holds, so its keyword list is the state, plus
  # both single-key forms a helper writes with — `assign(socket, :one, value)` and the piped
  # `socket |> assign(:one, value)`.
  defp lifecycle_assigns(component) do
    helpers = component["helpers"]

    mounted =
      helpers
      |> Enum.filter(&(&1["name"] == "mount"))
      |> Enum.flat_map(&Regex.scan(~r/([a-z_]+):\s/, &1["code"] || ""))
      |> Enum.map(fn [_whole, name] -> name end)

    single =
      helpers
      |> Enum.flat_map(&Regex.scan(~r/assign\(\s*[a-z_]+,\s*:([a-z_]+)/, &1["code"] || ""))
      |> Enum.map(fn [_whole, name] -> name end)

    piped =
      helpers
      |> Enum.flat_map(&Regex.scan(~r/assign\(\s*:([a-z_]+)/, &1["code"] || ""))
      |> Enum.map(fn [_whole, name] -> name end)

    Enum.uniq(mounted ++ single ++ piped)
  end
end
