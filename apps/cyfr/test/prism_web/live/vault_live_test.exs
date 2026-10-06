# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.VaultLiveTest do
  @moduledoc """
  Tests sign-in gating, vault-entry server references, the provider a new
  entry is made for, the destination and disclosure it names, and
  management of operator OAuth client credentials on the Vault page.

  A new entry is made for a need one of the athanor's components names:
  the form offers each `api_key` and `bundle` need the grant plan answers,
  a dependency's at the version its dependent pins included, by provider
  and kind, and the entry it makes is a candidate for that need. A choice
  the needs no longer offer when the form is sent makes nothing. A
  component list that cannot be read, and an athanor whose components
  name none, offer no create; a component whose plan is refused is named
  beside the rest, and a list cut short says so.

  Storing client credentials is a sensitive change: the page asks
  through its system layer, and nothing is stored until the person
  confirms the record; the browser then submits the same form again,
  which still holds what was typed, and the page stores it. The page
  holds no typed secret while it waits. Listing and removing them need
  the session alone.
  """
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

  # The need the shipped OpenAI catalyst names, as the create form offers it.
  @openai "api_key:openai.com"

  # A component of the seated athanor naming `needs` (need name => type),
  # registered as an installed one is.
  defp install_needs!(name, needs), do: register!("reagent", name, "1.0.0", needs(needs))

  # A component release registered in the seated athanor as an installed
  # one is, its manifest naming itself.
  defp register!(type, name, version, manifest) do
    Cyfr.Test.SeedBundle.isolate!()

    manifest =
      Map.merge(manifest, %{
        "name" => name,
        "type" => type,
        "version" => version,
        "publisher" => "local"
      })

    {:ok, _} =
      Arca.Test.UnitFixtures.ship_and_register!(seed_ctx(), type, "local", name, version,
        manifest: manifest,
        wasm: @wasm
      )

    :ok
  end

  # A manifest's needs block, each need's type as given; an OAuth need
  # names the scopes it reads, as a grant plan requires of one.
  defp needs(needs) do
    %{
      "needs" =>
        Map.new(needs, fn {need, type} ->
          declared = %{"type" => type, "reason" => "to test the create form", "fields" => ["KEY"]}

          if String.starts_with?(type, "oauth:"),
            do: {need, Map.put(declared, "scopes", ["read"])},
            else: {need, declared}
        end)
    }
  end

  # `count` later releases of one component, written as the registry
  # holds a release row, each newer than every component registered
  # before: the rows `component.list` answers first.
  defp later_releases!(name, count, manifest \\ %{}) do
    actor = Sanctum.Context.actor(seed_ctx())
    base = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

    for i <- 1..count do
      version = "2.0.#{i}"

      manifest =
        Map.merge(manifest, %{
          "name" => name,
          "type" => "reagent",
          "version" => version,
          "publisher" => "local"
        })

      digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name <> version), case: :lower)
      {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
      at = DateTime.add(base, i, :microsecond)

      {:ok, _} =
        Arca.ComponentStorage.put_component(actor, %{
          id: "cmp_#{name}_#{i}",
          name: name,
          version: version,
          component_type: "reagent",
          description: "a later release",
          tags: "[]",
          digest: digest,
          release_digest: release_digest,
          size: 100,
          exports: "[]",
          manifest: Jason.encode!(manifest),
          publisher: "local",
          publisher_id: "local|local|testns",
          source: Compendium.Source.filesystem(),
          signature_verified: false,
          inserted_at: at,
          updated_at: at
        })
    end

    Arca.Cache.delete_match(:_)
  end

  # A registered component whose stored manifest no longer decodes.
  defp damage_manifest!(name) do
    Arca.Repo.query!("UPDATE components SET manifest = '{not json' WHERE name = '#{name}'")
    Arca.Cache.delete_match(:_)
  end

  defp made(ctx) do
    {:ok, entries} = Sanctum.Vault.list(ctx)
    for entry <- entries, do: {entry.name, entry.kind, entry.provider_hint}
  end

  defp refused_line(ref), do: ~s([data-test="create-needs-refused"][data-ref="#{ref}"])

  # The text of each element `selector` finds, as a person reads it: its
  # words, one space apart.
  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  # The plan's own sentence for `ref`, ended once, as the page names it.
  defp plan_sentence(ctx, ref) do
    {:error, reason} = PrismWeb.Ops.call_tool(ctx, "profile/plan", %{"ref" => ref})
    String.trim_trailing(PrismWeb.Ops.error_message(reason), ".") <> "."
  end

  # The shipped OpenAI catalyst, at its newest shipped version and with
  # its own manifest, registered in the seated athanor.
  defp install_openai! do
    unit = Cyfr.Test.SeedBundle.local_unit!("catalysts", "openai")
    Cyfr.Test.SeedBundle.isolate!()

    {:ok, _} =
      Arca.Test.UnitFixtures.ship_and_register!(
        seed_ctx(),
        "catalyst",
        "local",
        "openai",
        unit.version,
        manifest: unit.manifest,
        wasm: @wasm
      )

    :ok
  end

  defp seed_ctx,
    do:
      Sanctum.internal_context(user_id: "_test", athanor_id: seated_athanor().id, scope: :athanor)

  # The entries the shipped OpenAI need's plan names as its candidates.
  defp openai_candidates(ctx) do
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: "catalyst:local.openai"})
    need = Enum.find(plan.needs, &(&1.need == "api_key"))
    need.candidates |> Enum.map(& &1[:entry_id]) |> Enum.sort()
  end

  # The create form's provider choice, as `{value, label}` per option.
  defp need_options(view) do
    view
    |> element(~s(#vault-create-form select[name="need"]))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> Enum.map(fn option ->
      [value] = LazyHTML.attribute(option, "value")
      {value, option |> LazyHTML.text() |> String.trim()}
    end)
  end

  @needs_unread "The keys your components need cannot be read right now — try again."
  @no_need "No component here needs a key yet — install one first."
  @not_offered "Choose the provider this key is for"
  @no_longer_needed "That key is no longer needed here — choose again."
  @unconfirmed "Whether that key is still needed could not be read, so nothing was made."
  @cut "Only the 1000 newest component versions were read, so a key one of the others " <>
         "needs may be missing here — make it with " <>
         ~s(cyfr call vault '{"action":"create",…,"provider_hint":"…"}'.)

  describe "GET /vault (unauthenticated)" do
    test "redirects to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(conn, athanor_path("/vault", "@nobody"))
    end
  end

  test "a vault entry shows the MCP servers that read it through vault: headers", %{conn: conn} do
    user = test_user()
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(user.user_id, "Wired #{user.namespace}")

    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: group.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    # Entering the credential is a sensitive change, made under the
    # confirmation its person proves (`Sanctum.TestContext.confirming/2`).
    {:ok, _} =
      Sanctum.TestContext.confirming(
        ctx,
        &Grimoire.call_external("vault", &1, %{
          "action" => "create",
          "name" => "bridge-token",
          "kind" => "api_key",
          "fields" => %{"TOKEN" => "t"},
          "destination" => %{"hosts" => ["example.com"]}
        })
      )

    {:ok, _} =
      Grimoire.call_external("mcp_servers", ctx, %{
        "action" => "create",
        "name" => "bridge",
        "config" => %{
          "url" => "https://example.com/mcp",
          "headers" => %{"Authorization" => "vault:bridge-token"}
        }
      })

    conn = log_in_user(conn, user, athanor_id: group.id)
    {_view, html} = mount_athanor(conn, "/vault", group)
    assert html =~ "bridge-token"
    assert html =~ "used by MCP server bridge"

    # the list verb carries the names — never the header values
    assert {:ok, %{servers: [server]}} =
             Grimoire.call_external("mcp_servers", ctx, %{"action" => "list"})

    assert server.vault_refs == ["bridge-token"]
    refute inspect(server) =~ "Authorization"
  end

  # A secret no rendered page holds by accident: a LiveView's element id and
  # session token are random base64url text, where three letters turn up.
  @client_secret "client secret: never rendered"

  # Submits the create form as typed, proves the record it waits on, and
  # submits it again when the page asks: the browser's resubmission.
  defp create_confirmed!(view, ctx, typed) do
    # A created entry closes the form; the next one opens it again.
    unless has_element?(view, "#vault-create-form"),
      do: render_click(view, "show_add", %{"mode" => "fields"})

    view |> form("#vault-create-form", typed) |> render_submit()

    assert {:ok, [%{ref: ref, operation: "vault.create"}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    Sanctum.TestContext.prove!(ctx, ref)
    assert_push_event(view, "system_layer:resubmit", %{form: "vault-create-form"}, 2_000)
    view |> form("#vault-create-form", typed) |> render_submit()

    {:ok, entries} = Sanctum.Vault.list(ctx)
    Enum.find(entries, &(&1.name == typed["name"]))
  end

  test "a new entry names where it may go, nothing prefilled, attached unless disclosed",
       %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    install_needs!("vault-form-keyed", %{"api_key" => "api_key:example.com"})
    {view, _html} = mount_athanor(conn, "/vault")
    render_click(view, "show_add", %{"mode" => "fields"})

    # The page reads the needs for the provider choice alone, so the
    # person types the destination: no host is offered, and a component
    # reading the value is off until they turn it on.
    hosts = ~s(#vault-create-form input[name="destination_hosts"])
    assert has_element?(view, hosts <> "[required]")
    refute view |> element(hosts) |> render() =~ ~r/value="[^"]+"/
    assert has_element?(view, ~s(#vault-create-form input[type="checkbox"][name="disclose"]))
    refute has_element?(view, ~s(#vault-create-form input[name="disclose"][checked]))

    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: seated_athanor().id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    attached =
      create_confirmed!(view, ctx, %{
        "name" => "routed-#{System.unique_integer([:positive])}",
        "need" => "api_key:example.com",
        "fields" => "TOKEN=t0k3n",
        "destination_hosts" => "API.example.com",
        "destination_paths" => "/v1/"
      })

    assert attached.destination == %{
             "hosts" => ["api.example.com"],
             "paths" => ["/v1/"],
             "scheme" => "https"
           }

    assert attached.attach_only == true

    disclosed =
      create_confirmed!(view, ctx, %{
        "name" => "read-#{System.unique_integer([:positive])}",
        "need" => "api_key:example.com",
        "fields" => "TOKEN=t0k3n",
        "destination_hosts" => "db.example.com",
        "destination_port" => "8443",
        "disclose" => "true"
      })

    assert disclosed.destination == %{
             "hosts" => ["db.example.com"],
             "port" => 8443,
             "scheme" => "https"
           }

    assert disclosed.attach_only == false

    # Each row says where its entry goes, and whether components may read it.
    html = render(view)
    assert html =~ "https://api.example.com · /v1/"
    assert html =~ "https://db.example.com:8443"
    assert has_element?(view, ~s([data-test="entry-disclosure"]), "never handed to a component")

    # An attach-only entry's row, and the form's disclosure choice, say what
    # happens to the value instead: CYFR attaches it.
    assert has_element?(
             view,
             ~s([data-test="entry-disclosure"]),
             "CYFR attaches it to requests bound for its destination"
           )

    render_click(view, "show_add", %{"mode" => "fields"})

    assert view |> element("#vault-create-form") |> render() =~
             "CYFR attaches it to requests bound for the entry&#39;s destination"

    assert has_element?(view, ~s([data-test="entry-disclosure"]), "disclosed: components read it")
    Cyfr.Test.Sandbox.end_views()
  end

  describe "the provider a new entry is made for" do
    test "an entry made through the form is stored with the provider of the need it was " <>
           "made for, and that need sees it",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()
      ctx = seated_ctx(user)
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      name = "openai-#{System.unique_integer([:positive])}"

      typed = %{
        "name" => name,
        "fields" => "OPENAI_API_KEY=sk-first",
        "destination_hosts" => "api.openai.com"
      }

      # The choice rides beside what was typed rather than as a field the
      # form must hold: what is held here is what the vault stored, read
      # as its own list answers it, whatever the form drew.
      chosen = %{"need" => @openai}

      view |> form("#vault-create-form", typed) |> render_submit(chosen)
      assert [%{ref: ref, operation: "vault.create"}] = open_records(ctx)
      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-create-form"}, 2_000)
      view |> form("#vault-create-form", typed) |> render_submit(chosen)

      {:ok, entries} = Sanctum.Vault.list(ctx)
      stored = Enum.find(entries, &(&1.name == name))

      assert {Map.take(stored, [:kind, :provider_hint]), openai_candidates(ctx)} ==
               {%{kind: "api_key", provider_hint: "openai.com"}, [stored.id]}
    end

    test "the form offers each api_key and bundle need once, by provider and kind, with no " <>
           "free text; a second entry for one provider is a second candidate for its need",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()

      install_needs!("vault-form-mixed", %{
        "model" => @openai,
        "store" => "bundle:supabase.com",
        "drive" => "oauth:google.com"
      })

      ctx = seated_ctx(user)
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})

      # One required choice: the OpenAI need two components name appears
      # once, and the OAuth need is left to the OAuth form.
      assert has_element?(view, ~s(#vault-create-form select[name="need"][required]))

      assert need_options(view) == [
               {"", "Choose a provider"},
               {@openai, "openai.com (api_key)"},
               {"bundle:supabase.com", "supabase.com (bundle)"}
             ]

      refute has_element?(view, ~s(#vault-create-form [name="kind"]))
      refute has_element?(view, ~s(#vault-create-form [name="provider_hint"]))
      refute has_element?(view, ~s(#vault-create-form input[name="need"]))

      typed = fn key ->
        %{
          "name" => "openai-#{System.unique_integer([:positive])}",
          "need" => @openai,
          "fields" => "OPENAI_API_KEY=#{key}",
          "destination_hosts" => "api.openai.com"
        }
      end

      first = create_confirmed!(view, ctx, typed.("sk-first"))
      assert {first.kind, first.provider_hint} == {"api_key", "openai.com"}
      assert openai_candidates(ctx) == [first.id]

      second = create_confirmed!(view, ctx, typed.("sk-second"))
      assert {second.kind, second.provider_hint} == {"api_key", "openai.com"}
      assert openai_candidates(ctx) == Enum.sort([first.id, second.id])

      bundle =
        create_confirmed!(view, ctx, %{
          "name" => "supabase-#{System.unique_integer([:positive])}",
          "need" => "bundle:supabase.com",
          "fields" => "SUPABASE_URL=https://x.supabase.co\nSUPABASE_KEY=k",
          "destination_hosts" => "x.supabase.co"
        })

      assert {bundle.kind, bundle.provider_hint} == {"bundle", "supabase.com"}
    end

    test "a choice the page did not offer makes nothing: free text, a kind no need names, an " <>
           "OAuth need, no choice, or the vault's own arguments typed",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()
      install_needs!("vault-form-oauth", %{"drive" => "oauth:google.com"})
      ctx = seated_ctx(user)
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})

      typed = %{
        "name" => "forged-#{System.unique_integer([:positive])}",
        "fields" => "OPENAI_API_KEY=sk-forged",
        "destination_hosts" => "api.openai.com"
      }

      for forged <- [
            %{"need" => "api_key:evil.example"},
            %{"need" => "openai.com"},
            %{"need" => "bundle:openai.com"},
            %{"need" => "oauth:google.com"},
            %{"need" => ""},
            %{},
            %{"kind" => "api_key", "provider_hint" => "openai.com"}
          ] do
        render_click(view, "lv:clear-flash", %{})
        html = render_submit(view, "create", Map.merge(typed, forged))
        assert html =~ @not_offered, "#{inspect(forged)} was not refused"
        assert open_records(ctx) == [], "#{inspect(forged)} was asked for"
      end

      assert {:ok, []} = Sanctum.Vault.list(ctx)

      # A kind sent beside an offered choice is not read: the need's is.
      with_kind = Map.merge(typed, %{"need" => @openai, "kind" => "bundle"})
      render_submit(view, "create", with_kind)
      assert [%{ref: ref, operation: "vault.create"}] = open_records(ctx)
      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-create-form"}, 2_000)
      render_submit(view, "create", with_kind)

      assert {:ok, [%{kind: "api_key", provider_hint: "openai.com"}]} = Sanctum.Vault.list(ctx)
    end

    test "a create still asks a fresh confirmation, and nothing is stored until it is given",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()
      ctx = seated_ctx(user)
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      key = "sk-waiting-#{System.unique_integer([:positive])}"

      typed = %{
        "name" => "confirmed-#{System.unique_integer([:positive])}",
        "need" => @openai,
        "fields" => "OPENAI_API_KEY=#{key}",
        "destination_hosts" => "api.openai.com"
      }

      view |> form("#vault-create-form", typed) |> render_submit()

      assert [%{ref: ref, operation: "vault.create"}] = open_records(ctx)
      prompt_id = "confirmation-" <> ref

      assert_push_event(view, "system_layer:mark", %{
        form: "vault-create-form",
        prompt: ^prompt_id
      })

      assert {:ok, []} = Sanctum.Vault.list(ctx)
      refute page_state(view) =~ key

      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-create-form"}, 2_000)
      view |> form("#vault-create-form", typed) |> render_submit()

      assert {:ok, [entry]} = Sanctum.Vault.list(ctx)

      assert {entry.name, entry.kind, entry.provider_hint} ==
               {typed["name"], "api_key", "openai.com"}

      assert open_records(ctx) == []
      assert render(view) =~ "Entry created."
    end

    test "a component list that cannot be read is said as such, with no create, never as no " <>
           "need; plans refused all round name every component, with no create",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()
      install_needs!("vault-form-store", %{"store" => "bundle:supabase.com"})
      ctx = seated_ctx(user)
      {view, _html} = mount_athanor(conn, "/vault")

      # The component list cannot be read.
      hide_table!("components")
      render_click(view, "show_add", %{"mode" => "fields"})
      restore_table!("components")
      assert_needs_unread(view)
      render_click(view, "show_add", %{"mode" => "fields"})

      # The list reads, and every component's plan is refused: each is
      # named with its own plan's sentence, and nothing is offered.
      hide_table!("vault_entries")
      render_click(view, "show_add", %{"mode" => "fields"})
      openai = plan_sentence(ctx, "catalyst:local.openai")
      store = plan_sentence(ctx, "reagent:local.vault-form-store")
      restore_table!("vault_entries")

      assert texts(view, ~s([data-test="create-needs-refused"])) == [
               "The keys catalyst:local.openai needs could not be read: #{openai}",
               "The keys reagent:local.vault-form-store needs could not be read: #{store}"
             ]

      refute render(view) =~ @no_need
      refute render(view) =~ @needs_unread
      refute has_element?(view, "#vault-create-form")
      render_click(view, "show_add", %{"mode" => "fields"})

      # Read again once the store answers, the needs are offered.
      render_click(view, "show_add", %{"mode" => "fields"})
      refute has_element?(view, ~s([data-test="create-needs-refused"]))

      assert need_options(view) == [
               {"", "Choose a provider"},
               {@openai, "openai.com (api_key)"},
               {"bundle:supabase.com", "supabase.com (bundle)"}
             ]
    end

    test "a component whose plan is refused is named with its plan's sentence, beside the " <>
           "needs of the rest",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()
      install_needs!("vault-form-damaged", %{"key" => "api_key:damaged.example"})
      damage_manifest!("vault-form-damaged")
      ctx = seated_ctx(user)
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      damaged = plan_sentence(ctx, "reagent:local.vault-form-damaged")

      assert texts(view, ~s([data-test="create-needs-refused"])) == [
               "The keys reagent:local.vault-form-damaged needs could not be read: #{damaged}"
             ]

      assert has_element?(view, refused_line("reagent:local.vault-form-damaged"))

      assert need_options(view) == [{"", "Choose a provider"}, {@openai, "openai.com (api_key)"}]
      refute render(view) =~ @needs_unread
    end

    test "a dependency stored damaged is named through its own refused plan, though its " <>
           "dependent's plan answers without its needs",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      register!("reagent", "vault-form-dep", "1.0.0", needs(%{"key" => "api_key:dep.example"}))

      register!("reagent", "vault-form-app", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => "reagent:local.vault-form-dep:1.0.0"}]}
      })

      damage_manifest!("vault-form-dep")

      # The dependent's plan answers, and names none of the damaged
      # dependency's needs.
      assert {:ok, plan} =
               PrismWeb.Ops.call_tool(ctx, "profile/plan", %{
                 "ref" => "reagent:local.vault-form-app"
               })

      assert plan.dependency_needs == []

      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      dep = plan_sentence(ctx, "reagent:local.vault-form-dep")

      assert texts(view, ~s([data-test="create-needs-refused"])) == [
               "The keys reagent:local.vault-form-dep needs could not be read: #{dep}"
             ]

      # Nothing else names a key, so nothing is offered, and the page does
      # not say no component needs one.
      refute has_element?(view, "#vault-create-form")
      refute render(view) =~ @no_need
      refute render(view) =~ @needs_unread
    end

    test "a dependency's need at the version its dependent pins is offered, beside the need " <>
           "of the dependency's newest version",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      register!("reagent", "probe-dep", "1.0.0", needs(%{"key" => "api_key:old.example"}))
      register!("reagent", "probe-dep", "2.0.0", needs(%{"key" => "api_key:new.example"}))

      register!("reagent", "probe-app", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => "reagent:local.probe-dep:1.0.0"}]}
      })

      # The grant plan offers the pinned version's need, with nothing to
      # meet it: the sheet's "Connect your old.example account".
      {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: "reagent:local.probe-app"})

      assert [{"reagent:local.probe-dep", "api_key", "old.example", []}] ==
               for(
                 %{dep: dep, needs: rows} <- plan.dependency_needs,
                 row <- rows,
                 do: {dep, row.kind, row.provider, row.candidates}
               )

      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})

      assert need_options(view) == [
               {"", "Choose a provider"},
               {"api_key:new.example", "new.example (api_key)"},
               {"api_key:old.example", "old.example (api_key)"}
             ]
    end

    test "a list cut at the most one read answers says so beside the needs it read, naming " <>
           "the CLI for the rest",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()
      later_releases!("probe-filler", 1000, needs(%{"key" => "api_key:filler.example"}))
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})

      # The shipped OpenAI catalyst's row is past the cut, so its need is
      # not listed, and the page says the list may be missing one.
      assert texts(view, ~s([data-test="create-needs-cut"])) == [@cut]

      assert need_options(view) == [
               {"", "Choose a provider"},
               {"api_key:filler.example", "filler.example (api_key)"}
             ]

      refute render(view) =~ @no_need
    end

    test "a need the grant plan offers behind the newest 1000 component rows is never read " <>
           "as no need: the cut is said in place of installing one",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      install_openai!()
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      assert {@openai, "openai.com (api_key)"} in need_options(view)
      render_click(view, "show_add", %{"mode" => "fields"})

      later_releases!("probe-filler", 1000)

      {:ok, %{components: rows}} =
        PrismWeb.Ops.call_tool(ctx, "component/list", %{"limit" => 1000})

      assert length(rows) == 1000
      refute Enum.any?(rows, &(&1.name == "openai"))

      # The grant plan still offers the need, with nothing to meet it: the
      # sheet's "Connect your openai.com account".
      {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: "catalyst:local.openai"})
      need = Enum.find(plan.needs, &(&1.need == "api_key"))
      assert {need.kind, need.provider, need.candidates} == {"api_key", "openai.com", []}

      render_click(view, "show_add", %{"mode" => "fields"})

      assert texts(view, ~s([data-test="create-needs-cut"])) == [@cut]
      refute render(view) =~ @no_need
      refute has_element?(view, "#vault-create-form")
    end

    test "a choice from a list that changed while the form was open makes nothing, and the " <>
           "form is drawn again from the needs as they now read",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      register!("reagent", "probe-moved", "1.0.0", needs(%{"key" => "api_key:gone.example"}))
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      assert {"api_key:gone.example", "gone.example (api_key)"} in need_options(view)

      # A newer version names another provider.
      register!("reagent", "probe-moved", "2.0.0", needs(%{"key" => "api_key:other.example"}))

      typed = %{
        "name" => "stale-#{System.unique_integer([:positive])}",
        "need" => "api_key:gone.example",
        "fields" => "KEY=k",
        "destination_hosts" => "api.gone.example"
      }

      view |> form("#vault-create-form", typed) |> render_submit()

      assert open_records(ctx) == []
      assert made(ctx) == []
      assert texts(view, ~s([data-test="create-stale"])) == [@no_longer_needed]

      assert need_options(view) == [
               {"", "Choose a provider"},
               {"api_key:other.example", "other.example (api_key)"}
             ]
    end

    test "a choice for a component removed while the form was open makes nothing",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      install_openai!()
      register!("reagent", "probe-gone", "1.0.0", needs(%{"key" => "api_key:gone.example"}))
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      assert {"api_key:gone.example", "gone.example (api_key)"} in need_options(view)

      # The row ends as a removal ends it (the registry's own delete
      # refuses a shipped unit, which is how the fixture registers).
      Arca.ComponentStorage.delete_component(
        Sanctum.Context.actor(seed_ctx()),
        "probe-gone",
        "1.0.0",
        "local",
        "reagent"
      )

      Arca.Cache.delete_match(:_)

      typed = %{
        "name" => "gone-#{System.unique_integer([:positive])}",
        "need" => "api_key:gone.example",
        "fields" => "KEY=k",
        "destination_hosts" => "api.gone.example"
      }

      view |> form("#vault-create-form", typed) |> render_submit()

      assert open_records(ctx) == []
      assert made(ctx) == []
      assert texts(view, ~s([data-test="create-stale"])) == [@no_longer_needed]
      assert need_options(view) == [{"", "Choose a provider"}, {@openai, "openai.com (api_key)"}]
    end

    test "a confirmed choice the athanor no longer needs when the form is sent again makes " <>
           "nothing, its confirmation let go, and the form is drawn again",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      register!("reagent", "probe-moved", "1.0.0", needs(%{"key" => "api_key:gone.example"}))
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})

      typed = %{
        "name" => "resent-#{System.unique_integer([:positive])}",
        "need" => "api_key:gone.example",
        "fields" => "KEY=k",
        "destination_hosts" => "api.gone.example"
      }

      view |> form("#vault-create-form", typed) |> render_submit()
      assert [%{ref: ref, operation: "vault.create"}] = open_records(ctx)

      # The component changes while the confirmation waits.
      register!("reagent", "probe-moved", "2.0.0", needs(%{"key" => "api_key:other.example"}))

      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-create-form"}, 2_000)
      view |> form("#vault-create-form", typed) |> render_submit()

      assert made(ctx) == []
      assert record_state(ctx, ref) == "cancelled"

      refute page_state(view) =~ "cnf_",
             "the page still holds the secret of a change it will not make"

      assert texts(view, ~s([data-test="create-stale"])) == [@no_longer_needed]

      assert need_options(view) == [
               {"", "Choose a provider"},
               {"api_key:other.example", "other.example (api_key)"}
             ]
    end

    # A need missing from the needs as they read at the send is no longer
    # needed only when they read whole: with a plan refused, or the list
    # cut, the need may sit in what was not read, so the page says it cannot
    # tell, and makes nothing either way.
    test "a choice missing because a plan is refused at the send is not called no longer " <>
           "needed, and makes nothing",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      install_openai!()
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      assert {@openai, "openai.com (api_key)"} in need_options(view)

      typed = %{
        "name" => "refused-#{System.unique_integer([:positive])}",
        "need" => @openai,
        "fields" => "OPENAI_API_KEY=k",
        "destination_hosts" => "api.openai.com"
      }

      hide_table!("profiles")
      view |> form("#vault-create-form", typed) |> render_submit()
      stale = texts(view, ~s([data-test="create-stale"]))
      refused = texts(view, refused_line("catalyst:local.openai"))
      restore_table!("profiles")

      assert stale == [@unconfirmed]
      assert [_sentence] = refused
      assert open_records(ctx) == []
      assert made(ctx) == []
      # Once the store answers, the grant plan still names the need, with
      # no entry for it: it was never "no longer needed".
      assert openai_candidates(ctx) == []
    end

    test "a confirmed choice missing because a plan is refused at the resend is not called " <>
           "no longer needed; nothing is made and its confirmation is let go",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      install_openai!()
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})

      typed = %{
        "name" => "refused-resent-#{System.unique_integer([:positive])}",
        "need" => @openai,
        "fields" => "OPENAI_API_KEY=k",
        "destination_hosts" => "api.openai.com"
      }

      view |> form("#vault-create-form", typed) |> render_submit()
      assert [%{ref: ref, operation: "vault.create"}] = open_records(ctx)
      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-create-form"}, 2_000)

      hide_table!("profiles")
      view |> form("#vault-create-form", typed) |> render_submit()
      stale = texts(view, ~s([data-test="create-stale"]))
      restore_table!("profiles")

      assert stale == [@unconfirmed]
      assert made(ctx) == []
      assert record_state(ctx, ref) == "cancelled"

      refute page_state(view) =~ "cnf_",
             "the page still holds the secret of a change it will not make"
    end

    test "a choice missing because the list is cut at the send is not called no longer " <>
           "needed, and makes nothing",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      install_openai!()
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      assert {@openai, "openai.com (api_key)"} in need_options(view)

      later_releases!("probe-filler", 1000)

      typed = %{
        "name" => "cut-#{System.unique_integer([:positive])}",
        "need" => @openai,
        "fields" => "OPENAI_API_KEY=k",
        "destination_hosts" => "api.openai.com"
      }

      view |> form("#vault-create-form", typed) |> render_submit()

      assert texts(view, ~s([data-test="create-stale"])) == [@unconfirmed]
      assert texts(view, ~s([data-test="create-needs-cut"])) == [@cut]
      assert open_records(ctx) == []
      assert made(ctx) == []
    end

    test "an athanor whose components name no api_key or bundle need is told to install one, " <>
           "with no create",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_needs!("vault-form-oauth-only", %{"drive" => "oauth:google.com"})
      install_needs!("vault-form-none", %{})
      {view, _html} = mount_athanor(conn, "/vault")
      html = render_click(view, "show_add", %{"mode" => "fields"})

      assert has_element?(view, ~s([data-test="create-no-need"]), @no_need)
      refute html =~ @needs_unread
      refute has_element?(view, "#vault-create-form")
      refute has_element?(view, "button[type=submit]", "Create entry")
    end
  end

  defp assert_needs_unread(view) do
    assert has_element?(view, ~s([data-test="create-needs-unread"]), @needs_unread)
    refute render(view) =~ @no_need
    refute has_element?(view, "#vault-create-form")
    refute has_element?(view, "button[type=submit]", "Create entry")
  end

  # A store that cannot answer for `table`, in the test's sandbox alone.
  defp hide_table!(table),
    do: Arca.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unavailable")

  defp restore_table!(table),
    do: Arca.Repo.query!("ALTER TABLE #{table}_unavailable RENAME TO #{table}")

  describe "provided by this instance" do
    @inference ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"})
    @sealed "sealed-instance-material-sentinel"
    @keyed "reagent:local.vault-keyed"

    # An instance entry as its administrator left it, offered to `members`
    # when its audience is listed.
    defp offer!(over \\ %{}, members \\ []) do
      {:ok, entry} =
        Arca.InstanceEntries.put(
          Prima.Actor.system(),
          Map.merge(
            %{
              name: "offered-#{System.unique_integer([:positive])}",
              kind: "api_key",
              provider_hint: "openai.com",
              field_names: ~s(["OPENAI_API_KEY"]),
              destination: @inference,
              sealed_payload: @sealed,
              binding_digest: "sha256:offered",
              audience: "everyone",
              created_by: "usr_admin"
            },
            over
          ),
          members
        )

      entry
    end

    defp person_ctx(user, athanor_id) do
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: athanor_id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )
    end

    defp offered_row(entry), do: ~s([data-test="offered-entry"][data-id="#{entry.id}"])

    test "lists the entries offered to the person with their own use today, and never one " <>
           "they are not offered",
         %{conn: conn} do
      user = test_user()
      other = test_user()
      conn = log_in_user(conn, user)
      shared = offer!(%{name: "Shared OpenAI"})
      _theirs = offer!(%{name: "Listed for another", audience: "listed"}, [other.user_id])

      caps = %{person_daily: 100, total_daily: 1_000}
      claim = &Arca.InstanceEntryUsage.claim(Prima.Actor.system(), shared.id, &1, caps)

      for _ <- 1..2, do: {:ok, _} = claim.(user.user_id)
      {:ok, _} = claim.(other.user_id)

      {view, html} = mount_athanor(conn, "/vault")

      assert has_element?(view, offered_row(shared), "Shared OpenAI")
      assert has_element?(view, offered_row(shared), "openai.com")
      assert has_element?(view, offered_row(shared), "https://api.openai.com · POST · /v1/")
      assert has_element?(view, offered_row(shared), "Any consented component")

      # The person's own two requests today, not the entry's three.
      use = offered_row(shared) <> ~s( [data-test="offered-use"])
      assert has_element?(view, use, "2 requests today")
      assert html =~ "CYFR attaches it to requests bound for its"

      refute html =~ "Listed for another"
      refute html =~ @sealed
      section = view |> element(~s([data-test="instance-offered"])) |> render()
      assert length(Regex.scan(~r/data-test="offered-entry"/, section)) == 1
      refute has_element?(view, ~s([data-test="offered-cap-reached"]))
    end

    test "the person's own use says when it reached their daily limit and when that resets: " <>
           "at the cap, not below it",
         %{conn: conn} do
      user = test_user()
      other = test_user()
      conn = log_in_user(conn, user)
      capped = offer!(%{name: "Capped OpenAI", person_daily: 2, total_daily: 100})
      caps = %{person_daily: 2, total_daily: 100}
      claim = &Arca.InstanceEntryUsage.claim(Prima.Actor.system(), capped.id, &1, caps)
      use = offered_row(capped) <> ~s( [data-test="offered-use"])
      reached = "Your daily limit is reached; it resets at midnight UTC."

      # Below the cap: the count, and no limit.
      {:ok, _} = claim.(user.user_id)
      {view, html} = mount_athanor(conn, "/vault")
      assert has_element?(view, use, "1 request today")
      refute html =~ reached
      refute has_element?(view, ~s([data-test="offered-cap-reached"]))

      # At the cap: the limit, and when it resets.
      {:ok, _} = claim.(user.user_id)
      {view, _html} = mount_athanor(conn, "/vault")
      assert has_element?(view, use, "2 requests today")
      assert has_element?(view, use <> ~s( [data-test="offered-cap-reached"]), reached)

      # Another person's own use is theirs: below the cap the first reached.
      {:ok, _} = claim.(other.user_id)
      {other_view, other_html} = build_conn() |> log_in_user(other) |> mount_athanor("/vault")
      assert has_element?(other_view, use, "1 request today")
      refute other_html =~ reached
    end

    test "use by default makes the entry this athanor's default for its provider, which a " <>
           "need of that provider here suggests; another athanor's default is unchanged",
         %{conn: conn} do
      Cyfr.Test.SeedBundle.isolate!()
      user = test_user()
      conn = log_in_user(conn, user)
      home = seated_athanor()

      {:ok, group} =
        Sanctum.Tenancy.Athanors.create_group(user.user_id, "Second #{user.namespace}")

      for athanor_id <- [home.id, group.id] do
        seed_ctx =
          Sanctum.internal_context(user_id: "_test", athanor_id: athanor_id, scope: :athanor)

        {:ok, _} =
          Arca.Test.UnitFixtures.ship_and_register!(
            seed_ctx,
            "reagent",
            "local",
            "vault-keyed",
            "1.0.0",
            manifest: %{
              "needs" => %{
                "api_key" => %{
                  "type" => "api_key:openai.com",
                  "reason" => "to call the model with a key",
                  "fields" => ["OPENAI_API_KEY"],
                  "attach" => %{
                    "in" => "header",
                    "name" => "Authorization",
                    "template" => "Bearer {value}"
                  }
                }
              }
            },
            wasm: @wasm
          )
      end

      _first = offer!()
      second = offer!()

      suggested = fn athanor_id ->
        {:ok, plan} = Sanctum.Consent.Plan.plan(person_ctx(user, athanor_id), %{ref: @keyed})
        row = Enum.find(plan.needs, &(&1.need == "api_key"))
        {row.suggested, row.choice_required}
      end

      # Two offered and no default: the person is asked to choose, here and
      # in the group alike.
      assert suggested.(home.id) == {nil, true}
      assert suggested.(group.id) == {nil, true}

      {view, _html} = mount_athanor(conn, "/vault")
      refute has_element?(view, ~s([data-test="offered-default"]))

      view
      |> element(offered_row(second) <> ~s( [data-test="offered-use-by-default"]))
      |> render_click()

      assert render(view) =~ "Used by default for openai.com in this athanor."
      assert has_element?(view, offered_row(second) <> ~s( [data-test="offered-default"]))

      assert {:ok, %{"openai.com" => %{instance_entry_id: id}}} =
               Sanctum.Vault.defaults(person_ctx(user, home.id))

      assert id == second.id
      assert suggested.(home.id) == {%{instance_entry_id: second.id}, false}

      # The group's own default is untouched, so it still asks.
      assert {:ok, defaults} = Sanctum.Vault.defaults(person_ctx(user, group.id))
      refute Map.has_key?(defaults, "openai.com")
      assert suggested.(group.id) == {nil, true}
    end

    test "an offered read that fails says the instance's entries could not be read, not that " <>
           "none is offered",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      shared = offer!()
      {view, _html} = mount_athanor(conn, "/vault")
      assert has_element?(view, offered_row(shared))

      Arca.Repo.query!("ALTER TABLE instance_entries RENAME TO instance_entries_unavailable")
      send(view.pid, :load)

      assert has_element?(view, ~s([data-test="instance-offered-unread"]), "could not be read")
      refute render(view) =~ "This instance offers you no entry."
      refute has_element?(view, offered_row(shared))
    end

    test "a policy changed anywhere is shown again", %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      shared = offer!()
      {view, _html} = mount_athanor(conn, "/vault")
      policy = offered_row(shared) <> ~s( [data-test="offered-policy"])
      assert has_element?(view, policy, "Any consented component")

      ops = test_user()
      {:ok, _} = Sanctum.Tenancy.Members.ensure_platform(ops.user_id)
      admin = %{person_ctx(ops, Sanctum.TestContext.athanor_id()) | platform_admin: true}

      assert {:ok, :changed} =
               Sanctum.InstanceEntries.set_component_policy(admin, %{
                 entry_id: shared.id,
                 component_policy: "shipped"
               })

      wait_until(
        fn -> has_element?(view, policy, "Unmodified shipped components") end,
        2_000,
        "the policy shown again"
      )
    end
  end

  test "a new entry with no host to go to is refused, and nothing waits on a record",
       %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    install_openai!()
    {view, _html} = mount_athanor(conn, "/vault")
    render_click(view, "show_add", %{"mode" => "fields"})

    view
    |> form("#vault-create-form", %{
      "name" => "nowhere-#{System.unique_integer([:positive])}",
      "need" => @openai,
      "fields" => "TOKEN=t0k3n",
      "destination_hosts" => " "
    })
    |> render_submit()

    ctx = %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user.user_id}

    assert {:ok, []} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    assert {:ok, []} = Sanctum.Vault.list(ctx)
    Cyfr.Test.Sandbox.end_views()
  end

  test "OAuth client credentials are stored, listed by provider only, and removed", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {view, html} = mount_athanor(conn, "/vault")
    assert html =~ "OAuth client credentials"
    assert html =~ "No client credentials stored"

    render_click(view, "show_add", %{"mode" => "client"})

    typed = %{
      "provider" => "google",
      "client_id" => "abc.apps.googleusercontent.com",
      "client_secret" => @client_secret
    }

    view |> form("form[phx-submit=set_client]", typed) |> render_submit()

    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: seated_athanor().id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    # The change waits on its record, shown as this page's own; nothing is
    # stored, and neither the request's secret nor the client secret
    # appears in the page, its flash or its state.
    assert {:ok, [%{ref: ref, operation: "oauth.set_client"}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    wait_until(fn -> render(view) =~ ~s(data-ref="#{ref}") end, 2_000, "the page's prompt")

    # The form that typed it is marked, in the browser, with the prompt it
    # asks under.
    prompt_id = "confirmation-" <> ref
    assert_push_event(view, "system_layer:mark", %{form: "vault-client-form", prompt: ^prompt_id})

    state = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)
    refute state =~ @client_secret
    flash = inspect(:sys.get_state(view.pid).socket.assigns.flash)
    refute flash =~ "cnf_"
    refute flash =~ @client_secret
    rendered = render(view)
    assert rendered =~ "No client credentials stored"
    refute rendered =~ "cnf_"
    refute rendered =~ @client_secret
    assert {:error, _} = Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")

    # Confirmed, the browser is asked to submit the form again, as typed;
    # the page lists the provider alone.
    Sanctum.TestContext.prove!(ctx, ref)
    assert_push_event(view, "system_layer:resubmit", %{form: "vault-client-form"}, 2_000)
    view |> form("form[phx-submit=set_client]", typed) |> render_submit()

    # Completed: every form marked with its prompt is emptied.
    assert_push_event(
      view,
      "system_layer:clear",
      %{prompt: ^prompt_id, form: "vault-client-form"},
      2_000
    )

    rendered = render(view)
    assert rendered =~ "google"
    refute rendered =~ "No client credentials stored"
    refute rendered =~ @client_secret
    refute rendered =~ "abc.apps.googleusercontent.com"

    assert {:ok,
            %{"client_id" => "abc.apps.googleusercontent.com", "client_secret" => @client_secret}} =
             Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")

    assert {:ok, %{providers: [%{provider: "google"}]}} =
             Grimoire.call_external("oauth", ctx, %{"action" => "list"})

    view
    |> element("button[phx-click=delete_client][phx-value-provider=google]")
    |> render_click()

    assert render(view) =~ "No client credentials stored"
    assert {:error, _} = Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")

    # removing what is not there says so
    assert {:error, msg} =
             Grimoire.call_external("oauth", ctx, %{
               "action" => "delete_client",
               "provider" => "google"
             })

    assert msg =~ "No client credentials"
  end

  test "a request dismissed before its proof is cancelled, and its typed form emptied",
       %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {view, _html} = mount_athanor(conn, "/vault")
    render_click(view, "show_add", %{"mode" => "client"})

    view
    |> form("form[phx-submit=set_client]", %{
      "provider" => "github",
      "client_id" => "an-id",
      "client_secret" => @client_secret
    })
    |> render_submit()

    ctx = %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user.user_id}

    assert {:ok, [%{ref: ref}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    prompt_id = "confirmation-" <> ref
    assert_push_event(view, "system_layer:mark", %{form: "vault-client-form", prompt: ^prompt_id})

    # The person cancels their own waiting request from its prompt.
    view |> element(~s(#system-layer-dialog [data-test="prompt-dismiss"])) |> render_click()

    assert_push_event(view, "system_layer:clear", %{prompt: ^prompt_id, form: "vault-client-form"})

    assert {:ok, %{state: "cancelled"}} =
             Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), ref)

    assert {:error, _} = Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "github")
    Cyfr.Test.Sandbox.end_views()
  end

  test "a request nobody confirms ends on the page at its expiry, and its typed form is emptied",
       %{conn: conn} do
    Cyfr.Test.Settings.put("confirmation_seconds", 2)
    user = test_user()
    conn = log_in_user(conn, user)
    {view, _html} = mount_athanor(conn, "/vault")
    render_click(view, "show_add", %{"mode" => "client"})

    view
    |> form("form[phx-submit=set_client]", %{
      "provider" => "github",
      "client_id" => "an-id",
      "client_secret" => @client_secret
    })
    |> render_submit()

    ctx = %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user.user_id}

    assert {:ok, [%{ref: ref}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    prompt_id = "confirmation-" <> ref
    assert_push_event(view, "system_layer:mark", %{form: "vault-client-form", prompt: ^prompt_id})

    # Nothing repeats, so the home never announces the expiry: the page
    # ends the wait itself at the record's expiry and lets the form go.
    assert_push_event(
      view,
      "system_layer:clear",
      %{prompt: ^prompt_id, form: "vault-client-form"},
      5_000
    )

    assert render(view) =~ "This request expired"
    assert {:error, _} = Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "github")
    Cyfr.Test.Sandbox.end_views()
  end

  describe "a confirmed form sent again that no longer reads" do
    defp seated_ctx(user) do
      Sanctum.Context.build(
        user_id: user.user_id,
        athanor_id: seated_athanor().id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )
    end

    defp open_records(ctx) do
      {:ok, open} = Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)
      open
    end

    defp record_state(ctx, ref) do
      {:ok, row} = Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), ref)
      row.state
    end

    defp page_state(view),
      do: inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)

    test "create: the proof is let go, its record cancelled, and a later valid submit is " <>
           "asked afresh",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()
      {view, _html} = mount_athanor(conn, "/vault")
      ctx = seated_ctx(user)
      render_click(view, "show_add", %{"mode" => "fields"})

      typed = %{
        "name" => "resent-#{System.unique_integer([:positive])}",
        "need" => @openai,
        "fields" => "TOKEN=t0k3n",
        "destination_hosts" => "api.example.com"
      }

      view |> form("#vault-create-form", typed) |> render_submit()
      assert [%{ref: ref, operation: "vault.create"}] = open_records(ctx)
      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-create-form"}, 2_000)

      # The browser sends the form again, its values no longer reading.
      unreadable = %{typed | "fields" => "no equals sign"}
      html = view |> form("#vault-create-form", unreadable) |> render_submit()

      assert html =~ "Each line must be FIELD=value"
      assert record_state(ctx, ref) == "cancelled"

      refute page_state(view) =~ "cnf_",
             "the page still holds the secret of a change it will not make"

      # The prompt ends on the release's outcome, whichever of it and the
      # record's cancelled fact reached the layer first.
      render(view)
      prompt = render(view)

      assert prompt =~
               "The form sent again no longer reads, so the approval was withdrawn. " <>
                 "Nothing was changed."

      refute prompt =~ "Cancelled. Nothing was changed."

      {:ok, entries} = Sanctum.Vault.list(ctx)
      refute Enum.any?(entries, &(&1.name == typed["name"]))

      # The same change submitted again is asked for afresh.
      view |> form("#vault-create-form", typed) |> render_submit()
      assert [%{ref: again, operation: "vault.create"}] = open_records(ctx)
      refute again == ref
    end

    test "create: a choice the page did not offer, sent again, lets the proof go and makes " <>
           "nothing",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()
      {view, _html} = mount_athanor(conn, "/vault")
      ctx = seated_ctx(user)
      render_click(view, "show_add", %{"mode" => "fields"})

      typed = %{
        "name" => "resent-#{System.unique_integer([:positive])}",
        "need" => @openai,
        "fields" => "OPENAI_API_KEY=sk-resent",
        "destination_hosts" => "api.openai.com"
      }

      view |> form("#vault-create-form", typed) |> render_submit()
      assert [%{ref: ref, operation: "vault.create"}] = open_records(ctx)
      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-create-form"}, 2_000)

      html = render_submit(view, "create", %{typed | "need" => "api_key:evil.example"})

      assert html =~ @not_offered
      assert record_state(ctx, ref) == "cancelled"

      refute page_state(view) =~ "cnf_",
             "the page still holds the secret of a change it will not make"

      assert {:ok, []} = Sanctum.Vault.list(ctx)
    end

    defp hide_confirmations!,
      do:
        Arca.Repo.query!("ALTER TABLE pending_confirmations RENAME TO pending_confirmations_gone")

    defp restore_confirmations!,
      do:
        Arca.Repo.query!("ALTER TABLE pending_confirmations_gone RENAME TO pending_confirmations")

    @page_not_withdrawn "The approval could not be withdrawn; it ends when it expires."
    @prompt_not_withdrawn "The approval could not be withdrawn; it ends at its expiry."

    test "create: a cancel that fails is said with the form's error, on the page and in the prompt",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()
      {view, _html} = mount_athanor(conn, "/vault")
      ctx = seated_ctx(user)
      render_click(view, "show_add", %{"mode" => "fields"})

      typed = %{
        "name" => "resent-#{System.unique_integer([:positive])}",
        "need" => @openai,
        "fields" => "TOKEN=t0k3n",
        "destination_hosts" => "api.example.com"
      }

      view |> form("#vault-create-form", typed) |> render_submit()
      assert [%{ref: ref, operation: "vault.create"}] = open_records(ctx)
      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-create-form"}, 2_000)

      hide_confirmations!()

      view
      |> form("#vault-create-form", %{typed | "fields" => "no equals sign"})
      |> render_submit()

      html = render(view)
      holds = page_state(view) =~ "cnf_"
      restore_confirmations!()

      refute holds
      assert html =~ "Each line must be FIELD=value (line 1 is not). " <> @page_not_withdrawn
      assert html =~ @prompt_not_withdrawn
      refute html =~ "so the approval was withdrawn"
      assert record_state(ctx, ref) == "confirmed"
    end

    test "rotate: a cancel that fails is said with the form's error, on the page and in the prompt",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      name = "rotated-#{System.unique_integer([:positive])}"

      # The entry is made before the page opens, so the rotate's prompt is
      # the only one the page's layer shows.
      {:ok, _} =
        Sanctum.TestContext.confirming(
          ctx,
          &Grimoire.call_external("vault", &1, %{
            "action" => "create",
            "name" => name,
            "kind" => "api_key",
            "fields" => %{"TOKEN" => "first"},
            "destination" => %{"hosts" => ["api.example.com"]}
          })
        )

      {:ok, entries} = Sanctum.Vault.list(ctx)
      entry = Enum.find(entries, &(&1.name == name))
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_rotate", %{"id" => entry.id})
      rotate = "#vault-rotate-form-" <> entry.id

      view |> form(rotate, %{"fields" => "TOKEN=second"}) |> render_submit()
      assert [%{ref: ref, operation: "vault.rotate"}] = open_records(ctx)
      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-rotate-form-" <> _}, 2_000)

      hide_confirmations!()
      view |> form(rotate, %{"fields" => "no equals sign"}) |> render_submit()
      html = render(view)
      holds = page_state(view) =~ "cnf_"
      restore_confirmations!()

      refute holds
      assert html =~ "Each line must be FIELD=value (line 1 is not). " <> @page_not_withdrawn
      assert html =~ @prompt_not_withdrawn
      assert record_state(ctx, ref) == "confirmed"
    end

    test "a line that does not read is named by its number, never its content",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      pasted = "sk-pasted-#{System.unique_integer([:positive])}"

      html =
        view
        |> form("#vault-create-form", %{
          "name" => "pasted-#{System.unique_integer([:positive])}",
          "need" => @openai,
          "fields" => "TOKEN=ok\n#{pasted}",
          "destination_hosts" => "api.example.com"
        })
        |> render_submit()

      assert html =~ "Each line must be FIELD=value (line 2 is not)"
      refute html =~ pasted
      refute inspect(:sys.get_state(view.pid).socket.assigns.flash) =~ pasted
    end

    test "rotate: the proof is let go, its record cancelled, and a later valid submit is " <>
           "asked afresh",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_openai!()
      {view, _html} = mount_athanor(conn, "/vault")
      ctx = seated_ctx(user)

      entry =
        create_confirmed!(view, ctx, %{
          "name" => "rotated-#{System.unique_integer([:positive])}",
          "need" => @openai,
          "fields" => "TOKEN=first",
          "destination_hosts" => "api.example.com"
        })

      render_click(view, "show_rotate", %{"id" => entry.id})
      rotate = "#vault-rotate-form-" <> entry.id

      view |> form(rotate, %{"fields" => "TOKEN=second"}) |> render_submit()
      assert [%{ref: ref, operation: "vault.rotate"}] = open_records(ctx)
      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-rotate-form-" <> _}, 2_000)

      html = view |> form(rotate, %{"fields" => "no equals sign"}) |> render_submit()
      assert html =~ "Each line must be FIELD=value"
      assert record_state(ctx, ref) == "cancelled"

      refute page_state(view) =~ "cnf_",
             "the page still holds the secret of a change it will not make"

      view |> form(rotate, %{"fields" => "TOKEN=second"}) |> render_submit()
      assert [%{ref: again, operation: "vault.rotate"}] = open_records(ctx)
      refute again == ref
    end
  end
end
