# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.VaultLiveTest do
  @moduledoc """
  Tests sign-in gating, vault-entry server references, the create form
  and the entry it makes, the grants each row names, and management of
  operator OAuth client credentials on the Vault page.

  The create form makes an entry of whatever the person names, with no
  component installed: a kind it makes, an optional label the installed
  components' providers suggest, fields under any name, and a destination.
  A needs list that cannot be read suggests less and blocks nothing. Each
  row names the grants that bind its entry, or says nothing uses it, and
  says once when those grants cannot be read.

  Storing client credentials is a sensitive change: the page asks
  through its system layer, and nothing is stored until the person
  confirms the record; the browser then submits the same form again,
  which still holds what was typed, and the page stores it. The page
  holds no typed secret while it waits. Listing and removing them need
  the session alone.
  """
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  @wasm Cyfr.Test.Guests.wasm(:reagent)

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
        wasm: Cyfr.Test.Guests.wasm(type)
      )

    :ok
  end

  # A manifest's needs block, each need's type as given and calling the
  # host `api.<provider>`, which the manifest's egress names; an OAuth need
  # names the scopes it reads, as a grant plan requires of one.
  defp needs(needs) do
    declared =
      Map.new(needs, fn {need, type} ->
        [_kind, provider] = String.split(type, ":", parts: 2)

        declared = %{
          "type" => type,
          "reason" => "to test the create form",
          "fields" => ["KEY"],
          "hosts" => ["api.#{provider}"]
        }

        if String.starts_with?(type, "oauth:"),
          do: {need, Map.put(declared, "scopes", ["read"])},
          else: {need, declared}
      end)

    hosts = declared |> Map.values() |> Enum.flat_map(& &1["hosts"]) |> Enum.uniq()
    caps = if hosts == [], do: %{}, else: %{"caps" => %{"egress" => %{"domains" => hosts}}}
    Map.put(caps, "needs", declared)
  end

  # The text of each element `selector` finds, as a person reads it: its
  # words, one space apart.
  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp seed_ctx,
    do:
      Sanctum.Context.internal(user_id: "_test", athanor_id: seated_athanor().id, scope: :athanor)

  # The labels the create form suggests, as its list offers them.
  defp label_options(view) do
    view
    |> element("datalist#vault-create-labels")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> hd()))
  end

  # The create form's kinds, as `{value, words}` per option.
  defp kind_options(view) do
    view
    |> element(~s(#vault-create-form select[name="kind"]))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> Enum.map(fn option ->
      [value] = LazyHTML.attribute(option, "value")
      {value, option |> LazyHTML.text() |> String.trim()}
    end)
  end

  # The material an entry holds, unsealed as the vault reads it.
  defp material!(ctx, id) do
    {:ok, row} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), id)
    aad = Sanctum.CipherAAD.vault_entry(ctx.athanor_id, id, row.provider_hint)
    {:ok, plaintext} = Sanctum.Cipher.decrypt(row.sealed_payload, aad)
    {:ok, %{"fields" => fields}} = Sanctum.Vault.Payload.decode(plaintext)
    fields
  end

  @not_a_kind "Choose whether the entry is an API key or a bundle of fields"
  @uses_unread "Which grants use these entries could not be read right now."

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
        &Sanctum.Gate.call_external("vault", &1, %{
          "action" => "create",
          "name" => "bridge-token",
          "kind" => "api_key",
          "fields" => %{"TOKEN" => "t"},
          "destination" => %{"hosts" => ["example.com"]}
        })
      )

    {:ok, _} =
      Sanctum.Gate.call_external("mcp_servers", ctx, %{
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
             Sanctum.Gate.call_external("mcp_servers", ctx, %{"action" => "list"})

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
    {view, _html} = mount_athanor(conn, "/vault")
    render_click(view, "show_add", %{"mode" => "fields"})

    # The person types the destination: no host is offered, and a
    # component reading the value is off until they turn it on.
    hosts = ~s(#vault-create-form input[name="destination_hosts"])
    assert has_element?(view, hosts <> "[required]")
    refute view |> element(hosts) |> render() =~ ~r/value="[^"]+"/
    assert has_element?(view, ~s(#vault-create-form input[type="checkbox"][name="disclose"]))
    refute has_element?(view, ~s(#vault-create-form input[name="disclose"][checked]))

    ctx = seated_ctx(user)

    attached =
      create_confirmed!(view, ctx, %{
        "name" => "routed-#{System.unique_integer([:positive])}",
        "kind" => "api_key",
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
        "kind" => "api_key",
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

  describe "the create form" do
    test "the form creates an entry with no component installed", %{conn: conn} do
      Cyfr.Test.SeedBundle.isolate!()
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      assert {:ok, %{components: []}} = PrismWeb.Ops.call_tool(ctx, "component/list", %{})

      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})

      # Every input the form asks for, and nothing a need decides.
      assert has_element?(view, ~s(#vault-create-form input[name="name"][required]))
      assert has_element?(view, ~s(#vault-create-form select[name="kind"][required]))
      assert kind_options(view) == [{"api_key", "API key"}, {"bundle", "Bundle of fields"}]
      assert has_element?(view, ~s(#vault-create-form textarea[name="fields"][required]))
      refute has_element?(view, ~s(#vault-create-form [name="need"]))
      assert label_options(view) == []

      key =
        create_confirmed!(view, ctx, %{
          "name" => "free-#{System.unique_integer([:positive])}",
          "kind" => "api_key",
          "fields" => "KEY=k1",
          "destination_hosts" => "api.example.com"
        })

      bundle =
        create_confirmed!(view, ctx, %{
          "name" => "bundle-#{System.unique_integer([:positive])}",
          "kind" => "bundle",
          "fields" => "URL=https://x.example.com\nKEY=k2",
          "destination_hosts" => "x.example.com"
        })

      assert Map.take(key, [:kind, :provider_hint, :field_names, :status]) ==
               %{kind: "api_key", provider_hint: "", field_names: ["KEY"], status: "active"}

      assert Map.take(bundle, [:kind, :provider_hint, :field_names, :status]) ==
               %{kind: "bundle", provider_hint: "", field_names: ["KEY", "URL"], status: "active"}

      assert render(view) =~ "Entry created."
    end

    test "the label is optional and suggests the installed components' providers",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)

      install_needs!("vault-form-mixed", %{
        "model" => "api_key:openai.com",
        "store" => "bundle:supabase.com",
        "drive" => "oauth:google.com"
      })

      install_needs!("vault-form-again", %{"model" => "api_key:openai.com"})
      ctx = seated_ctx(user)
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})

      # Each provider of a kind the form makes once, sorted; an OAuth need's
      # is made through the OAuth form. The input takes them as suggestions
      # and requires none.
      assert label_options(view) == ["openai.com", "supabase.com"]

      assert has_element?(
               view,
               ~s(#vault-create-form input[name="provider_hint"][list="vault-create-labels"])
             )

      refute has_element?(view, ~s(#vault-create-form input[name="provider_hint"][required]))

      labelled =
        create_confirmed!(view, ctx, %{
          "name" => "labelled-#{System.unique_integer([:positive])}",
          "kind" => "api_key",
          "provider_hint" => " openai.com ",
          "fields" => "OPENAI_API_KEY=sk-1",
          "destination_hosts" => "api.openai.com"
        })

      unlabelled =
        create_confirmed!(view, ctx, %{
          "name" => "unlabelled-#{System.unique_integer([:positive])}",
          "kind" => "api_key",
          "provider_hint" => "",
          "fields" => "OPENAI_API_KEY=sk-2",
          "destination_hosts" => "api.openai.com"
        })

      assert {labelled.provider_hint, unlabelled.provider_hint} == {"openai.com", ""}

      # The labelled entry is its label's default, as the first of a label
      # is; the one with none is no provider's default.
      assert Sanctum.Vault.defaults(ctx) ==
               {:ok, %{"openai.com" => %{vault_entry_id: labelled.id}}}
    end

    test "a field named `API key` is stored as written", %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      {view, _html} = mount_athanor(conn, "/vault")
      key = "xai-#{System.unique_integer([:positive])}"

      entry =
        create_confirmed!(view, ctx, %{
          "name" => "My xAI key",
          "kind" => "api_key",
          "fields" => "API key=#{key}",
          "destination_hosts" => "api.x.ai"
        })

      assert entry.field_names == ["API key"]
      assert material!(ctx, entry.id) == %{"API key" => key}
      assert has_element?(view, "td", "API key")
    end

    test "an unread needs list blocks nothing", %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      install_needs!("vault-form-store", %{"store" => "bundle:supabase.com"})
      ctx = seated_ctx(user)
      {view, _html} = mount_athanor(conn, "/vault")

      # The component list cannot be read, then the plans meet a store that
      # cannot answer: the form is drawn whole each time, suggesting nothing.
      for table <- ~w(components vault_entries) do
        {_html, _log} =
          ExUnit.CaptureLog.with_log(fn ->
            hide_table!(table)
            html = render_click(view, "show_add", %{"mode" => "fields"})
            restore_table!(table)
            html
          end)

        assert has_element?(view, "#vault-create-form button[type=submit]", "Create entry"),
               table

        assert label_options(view) == [], table
        render_click(view, "show_add", %{"mode" => "fields"})
      end

      # An entry is made from the form drawn while nothing could be read.
      hide_table!("components")

      {_html, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          render_click(view, "show_add", %{"mode" => "fields"})
        end)

      restore_table!("components")

      made =
        create_confirmed!(view, ctx, %{
          "name" => "unread-#{System.unique_integer([:positive])}",
          "kind" => "bundle",
          "provider_hint" => "supabase.com",
          "fields" => "SUPABASE_URL=https://x.supabase.co\nSUPABASE_KEY=k",
          "destination_hosts" => "x.supabase.co"
        })

      assert {made.kind, made.provider_hint} == {"bundle", "supabase.com"}

      # Read again once the store answers, the label is suggested.
      render_click(view, "show_add", %{"mode" => "fields"})
      assert label_options(view) == ["supabase.com"]
    end

    test "a kind the form does not make is refused, and nothing is asked", %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})

      typed = %{
        "name" => "forged-#{System.unique_integer([:positive])}",
        "fields" => "KEY=k",
        "destination_hosts" => "api.example.com"
      }

      for forged <- [%{"kind" => "oauth"}, %{"kind" => "API key"}, %{"kind" => ""}, %{}] do
        render_click(view, "lv:clear-flash", %{})
        html = render_submit(view, "create", Map.merge(typed, forged))
        assert html =~ @not_a_kind, "#{inspect(forged)} was not refused"
        assert open_records(ctx) == [], "#{inspect(forged)} was asked for"
      end

      assert {:ok, []} = Sanctum.Vault.list(ctx)
    end

    test "a create still asks a fresh confirmation, and nothing is stored until it is given",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      key = "sk-waiting-#{System.unique_integer([:positive])}"

      typed = %{
        "name" => "confirmed-#{System.unique_integer([:positive])}",
        "kind" => "api_key",
        "fields" => "OPENAI_API_KEY=#{key}",
        "destination_hosts" => "api.openai.com"
      }

      view |> form("#vault-create-form", typed) |> render_submit()

      assert [%{ref: ref, operation: "vault.create"}] = open_records(ctx)
      prompt_id = "confirmation-" <> ref

      assert_push_event(
        view,
        "system_layer:mark",
        %{form: "vault-create-form", prompt: ^prompt_id},
        2_000
      )

      assert {:ok, []} = Sanctum.Vault.list(ctx)
      refute page_state(view) =~ key

      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-create-form"}, 2_000)
      view |> form("#vault-create-form", typed) |> render_submit()

      assert {:ok, [entry]} = Sanctum.Vault.list(ctx)
      assert {entry.name, entry.kind, entry.provider_hint} == {typed["name"], "api_key", ""}
      assert open_records(ctx) == []
      assert render(view) =~ "Entry created."
    end
  end

  describe "the grants that use an entry" do
    # A grant of `source` under `label` whose head binds `entry`, in
    # `status`.
    defp grant!(ctx, entry, source, label, status \\ "active") do
      {:ok, profile} =
        Arca.Test.Writers.put_profile(%{
          athanor_id: ctx.athanor_id,
          source_ref: source,
          kind: "owner",
          label: label,
          status: "active"
        })

      {:ok, _consent} =
        Arca.ConsentStorage.insert_revision(
          %{
            athanor_id: ctx.athanor_id,
            profile_id: profile.id,
            revision: 1,
            scope: "versionless",
            pinned_version: "",
            invoke_mode: "open_inert",
            shape_digest: "sha256:shape",
            commit_digest: "sha256:commit",
            blob_digest: Prima.Digest.sha256("{}"),
            resolved_policy: "{}",
            activation: "{}",
            admitted_origins: [:interactive],
            granted_by: "test",
            granted_via: "interactive"
          },
          [
            %{
              binding_key: source <> "|@ingress|default",
              scope: "athanor",
              vault_entry_id: entry.id,
              binding_digest: "sha256:bound"
            }
          ],
          nil
        )

      if status != "active",
        do:
          :ok =
            Arca.ProfileStorage.transition(Sanctum.Context.actor(ctx), profile.id, :any, status)

      profile
    end

    # An entry of the athanor, made before the page opens.
    defp entry!(ctx, name) do
      {:ok, _} =
        Sanctum.TestContext.confirming(
          ctx,
          &Sanctum.Gate.call_external("vault", &1, %{
            "action" => "create",
            "name" => name,
            "kind" => "api_key",
            "fields" => %{"API key" => "k"},
            "destination" => %{"hosts" => ["api.x.ai"]}
          })
        )

      {:ok, entries} = Sanctum.Vault.list(ctx)
      Enum.find(entries, &(&1.name == name))
    end

    # The entry's name cell: its name, its id and the grants that use it.
    defp row(entry), do: ~s([data-test="entry-name"][data-id="#{entry.id}"])

    test "a row names each grant that binds it", %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      grok = entry!(ctx, "My xAI key")
      other = entry!(ctx, "Spare xAI key")
      grant!(ctx, grok, "catalyst:local.grok", "default")
      grant!(ctx, grok, "catalyst:local.grok", "work")
      grant!(ctx, grok, "reagent:local.chat", "default")
      grant!(ctx, grok, "reagent:local.gone", "default", "revoked")
      grant!(ctx, other, "reagent:local.waiting", "default", "needs_consent")

      {view, _html} = mount_athanor(conn, "/vault")

      assert texts(view, row(grok) <> ~s( [data-test="entry-use"])) == [
               "Used by grok",
               "Used by grok (work)",
               "Used by chat"
             ]

      refute has_element?(view, row(grok) <> ~s( [data-test="entry-unused"]))

      # A grant waiting on consent again, or revoked, is no use.
      assert texts(view, row(other) <> ~s( [data-test="entry-use"])) == []

      assert texts(view, row(other) <> ~s( [data-test="entry-unused"])) == [
               "Nothing uses it yet."
             ]

      refute has_element?(view, ~s([data-test="entry-uses-unread"]))
    end

    test "a row nothing binds says so", %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      unused = entry!(ctx, "Unused key")

      {view, _html} = mount_athanor(conn, "/vault")

      assert texts(view, row(unused) <> ~s( [data-test="entry-unused"])) == [
               "Nothing uses it yet."
             ]

      assert texts(view, row(unused) <> ~s( [data-test="entry-use"])) == []
    end

    test "grants that cannot be read are said once above the rows, never as nothing using one",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      ctx = seated_ctx(user)
      bound = entry!(ctx, "Bound key")
      unused = entry!(ctx, "Unused key")
      grant!(ctx, bound, "catalyst:local.grok", "default")
      {view, _html} = mount_athanor(conn, "/vault")
      assert texts(view, row(bound) <> ~s( [data-test="entry-use"])) == ["Used by grok"]

      {_result, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          hide_table!("consent_vault_refs")
          send(view.pid, :load)
          html = render(view)
          restore_table!("consent_vault_refs")
          html
        end)

      assert texts(view, ~s([data-test="entry-uses-unread"])) == [@uses_unread]
      refute has_element?(view, ~s([data-test="entry-use"]))
      refute has_element?(view, ~s([data-test="entry-unused"]))
      assert has_element?(view, row(bound), "Bound key")
      assert has_element?(view, row(unused), "Unused key")
    end
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
          Sanctum.Context.internal(user_id: "_test", athanor_id: athanor_id, scope: :athanor)

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
                  },
                  "hosts" => ["api.openai.com"]
                }
              },
              "caps" => %{"egress" => %{"domains" => ["api.openai.com"]}}
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
      {:ok, _} = Sanctum.TestContext.ensure_platform(ops.user_id)
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
    {view, _html} = mount_athanor(conn, "/vault")
    render_click(view, "show_add", %{"mode" => "fields"})

    view
    |> form("#vault-create-form", %{
      "name" => "nowhere-#{System.unique_integer([:positive])}",
      "kind" => "api_key",
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

    assert_push_event(
      view,
      "system_layer:mark",
      %{form: "vault-client-form", prompt: ^prompt_id},
      2_000
    )

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
             Sanctum.Gate.call_external("oauth", ctx, %{"action" => "list"})

    view
    |> element("button[phx-click=delete_client][phx-value-provider=google]")
    |> render_click()

    assert render(view) =~ "No client credentials stored"
    assert {:error, _} = Sanctum.ProviderCredentials.fetch_for_oauth(ctx.athanor_id, "google")

    # removing what is not there says so
    assert {:error, msg} =
             Sanctum.Gate.call_external("oauth", ctx, %{
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

    assert_push_event(
      view,
      "system_layer:mark",
      %{form: "vault-client-form", prompt: ^prompt_id},
      2_000
    )

    # The person cancels their own waiting request from its prompt.
    view |> element(~s(#system-layer-dialog [data-test="prompt-dismiss"])) |> render_click()

    assert_push_event(
      view,
      "system_layer:clear",
      %{prompt: ^prompt_id, form: "vault-client-form"},
      2_000
    )

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

    assert_push_event(
      view,
      "system_layer:mark",
      %{form: "vault-client-form", prompt: ^prompt_id},
      2_000
    )

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

  # ---------------------------------------------------------------------------
  # Sharing a key
  # ---------------------------------------------------------------------------

  describe "sharing a key" do
    @market %{
      "hosts" => ["api.market.example"],
      "methods" => ["GET"],
      "paths" => ["/v1/quotes"]
    }

    # A person signed in to their own athanor, named as others read them.
    defp named!(name) do
      user = test_user()
      {:ok, _} = Arca.Users.update(Prima.Actor.system(), user.user_id, %{display_name: name})
      conn = log_in_user(build_conn(), user)
      {:ok, own} = Sanctum.Tenancy.Athanors.get_by_owner(user.user_id)

      ctx =
        Sanctum.Context.build(
          user_id: user.user_id,
          athanor_id: own.id,
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      %{user: user, conn: conn, own: own, ctx: Sanctum.TestContext.via(ctx, :prism)}
    end

    # Terry and Alice, each in their own athanor, seated together in Traders.
    defp traders! do
      terry = named!("Terry")
      alice = named!("Alice")
      {:ok, traders} = Sanctum.Tenancy.Athanors.create_group(terry.user.user_id, "Traders")

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(alice.user.user_id,
          scope: "athanor",
          athanor_id: traders.id
        )

      %{terry: terry, alice: alice, traders: traders}
    end

    # An entry of the person's own athanor, made under its confirmation.
    defp key!(%{ctx: ctx}, name, destination, disclose \\ false) do
      {:ok, %{entry: entry}} =
        Sanctum.TestContext.confirming(
          ctx,
          &Sanctum.Gate.call_external("vault", &1, %{
            "action" => "create",
            "name" => name,
            "kind" => "api_key",
            "fields" => %{"MARKET_KEY" => "mk-sentinel-#{name}"},
            "destination" => destination,
            "disclose" => disclose
          })
        )

      entry
    end

    defp share!(%{ctx: ctx}, entry, audience) do
      {:ok, %{share: share}} =
        Sanctum.TestContext.confirming(
          ctx,
          &Sanctum.Gate.call_external(
            "share",
            &1,
            Map.merge(%{"action" => "create", "entry_id" => entry.id}, audience)
          )
        )

      share
    end

    defp vault!(%{conn: conn, own: own}), do: mount_athanor(conn, "/vault", own)

    defp share_button(entry), do: ~s([data-test="entry-share"][phx-value-id="#{entry.id}"])
    defp by_you(share), do: ~s([data-test="shared-by-you-row"][data-id="#{share.id}"])
    defp with_you(share), do: ~s([data-test="shared-with-you-row"][data-id="#{share.id}"])

    defp shares_of(%{ctx: ctx}) do
      {:ok, %{shares: shares}} = Sanctum.Gate.call_external("share", ctx, %{"action" => "list"})
      shares
    end

    test "Share opens the system layer's sheet for a shareable key alone, the sheet's own " <>
           "confirmation makes the share, and Shared by you reads it" do
      %{terry: terry, traders: traders} = traders!()
      market = key!(terry, "market key", @market)
      disclosed = key!(terry, "read key", @market, true)
      open_ended = key!(terry, "open key", %{"hosts" => ["api.market.example"]})

      {view, _html} = vault!(terry)

      assert has_element?(view, share_button(market), "Share")
      refute has_element?(view, share_button(disclosed))
      refute has_element?(view, share_button(open_ended))
      assert has_element?(view, ~s([data-test="shared-by-you-none"]), "You share no key.")

      view |> element(share_button(market)) |> render_click()
      render(view)

      sheet = ~s(#system-layer-dialog [data-kind="share"] form#system-layer-share)
      assert has_element?(view, sheet)
      assert has_element?(view, "#system-layer-title", "Share market key")
      assert has_element?(view, sheet <> ~s( input[name="audience"][value="everyone"]))

      assert has_element?(
               view,
               sheet <> ~s( input[name="audience"][value="group:#{traders.id}"])
             )

      assert texts(view, sheet <> " fieldset[data-test=share-audience] label") ==
               ["Everyone on this CYFR", "Traders"]

      # The caps start empty, and the sheet says what empty, 0 and a number
      # mean, and what an uncapped share to everyone does.
      refute view |> element(sheet <> ~s( input[name="person_daily"])) |> render() =~ "value="
      refute view |> element(sheet <> ~s( input[name="total_daily"])) |> render() =~ "value="

      assert has_element?(
               view,
               ~s([data-test="share-caps-meaning"]),
               "An empty cap is no limit. 0 admits no use. A number is the most requests that day"
             )

      assert has_element?(
               view,
               ~s([data-test="share-uncapped"]),
               "Shared with everyone and no cap, anyone on this CYFR may use it without limit."
             )

      # No value of the key is asked for, and no component policy offered.
      refute has_element?(view, sheet <> ~s( input[type="password"]))
      refute render(view) =~ "component policy"

      view
      |> form(sheet, %{
        "audience" => "group:#{traders.id}",
        "person_daily" => "",
        "total_daily" => ""
      })
      |> render_submit()

      # The layer asked the share's own confirmation; nothing is shared yet.
      assert {:ok, [%{ref: ref, operation: "share.create"}]} =
               Arca.PendingConfirmations.list_open(
                 Sanctum.Context.actor(terry.ctx),
                 terry.user.user_id
               )

      assert shares_of(terry) == []

      Sanctum.TestContext.prove!(terry.ctx, ref)

      wait_until(fn -> shares_of(terry) != [] end, 2_000, "the share made once confirmed")
      [share] = shares_of(terry)
      assert %{audience: "group", group_id: group_id, person_daily: nil, total_daily: nil} = share
      assert group_id == traders.id

      wait_until(fn -> has_element?(view, by_you(share)) end, 2_000, "the row")

      assert texts(view, by_you(share) <> ~s( [data-test="share-line"])) ==
               ["market key, shared with Traders, 0 today, no cap"]

      refute has_element?(view, "#system-layer-dialog [data-kind=share]")
      refute render(view) =~ "mk-sentinel"
      Cyfr.Test.Sandbox.end_views()
    end

    test "a group's vault offers no Share and lists no shares: a key is shared, and a share " <>
           "granted, from the person's own athanor" do
      %{terry: terry, traders: traders} = traders!()
      market = key!(terry, "market key", @market)
      _share = share!(terry, market, %{"audience" => "group", "group_id" => traders.id})

      group_ctx = %{terry.ctx | athanor_id: traders.id}
      group_key = key!(%{ctx: group_ctx}, "group key", @market)

      conn = log_in_user(build_conn(), terry.user, athanor_id: traders.id)
      {view, html} = mount_athanor(conn, "/vault", traders)

      assert html =~ "group key"
      refute has_element?(view, share_button(group_key))
      refute has_element?(view, ~s([data-test="shared-by-you"]))
      refute has_element?(view, ~s([data-test="shared-with-you"]))
      refute html =~ "could not be read"
      Cyfr.Test.Sandbox.end_views()
    end

    test "a sheet's audience other than everyone or the person's own groups, or a cap that " <>
           "is no count, dispatches nothing" do
      %{terry: terry} = traders!()
      market = key!(terry, "market key", @market)
      {view, _html} = vault!(terry)

      view |> element(share_button(market)) |> render_click()
      sheet = "#system-layer-share"

      for {params, sentence} <- [
            {%{"audience" => "group:ath_elsewhere"}, "Choose who it is shared with"},
            {%{"audience" => "everyone", "person_daily" => "-1"}, "A cap is a whole number"},
            {%{"audience" => "everyone", "total_daily" => "1.5"}, "A cap is a whole number"}
          ] do
        view |> element(sheet) |> render_submit(params)
        assert has_element?(view, "#system-layer-dialog [role=alert]", sentence)
      end

      assert {:ok, []} =
               Arca.PendingConfirmations.list_open(
                 Sanctum.Context.actor(terry.ctx),
                 terry.user.user_id
               )

      assert shares_of(terry) == []
      Cyfr.Test.Sandbox.end_views()
    end

    test "Shared with you shows what is offered, by its owner's name and never its value, " <>
           "and loses it when the person leaves the group" do
      %{terry: terry, alice: alice, traders: traders} = traders!()
      market = key!(terry, "market key", @market)
      share = share!(terry, market, %{"audience" => "group", "group_id" => traders.id})

      {view, html} = vault!(alice)

      assert texts(view, with_you(share) <> ~s( [data-test="shared-by"])) == ["Shared by Terry"]

      assert texts(view, with_you(share) <> ~s( [data-test="shared-destination"])) ==
               ["https://api.market.example · GET · /v1/quotes"]

      assert texts(view, with_you(share) <> ~s( [data-test="shared-use"])) ==
               ["Your use: none today"]

      refute html =~ "mk-sentinel"
      refute html =~ "market key"

      # Leaving writes nothing to the share; the seat's change alone is read.
      :ok = Sanctum.Tenancy.Members.remove_member(traders, user_id: alice.user.user_id)

      wait_until(fn -> not has_element?(view, with_you(share)) end, 2_000, "the row gone")
      assert has_element?(view, ~s([data-test="shared-with-you-none"]), "No one shares a key")
      Cyfr.Test.Sandbox.end_views()
    end

    test "a share made, changed or revoked elsewhere is read again on both pages without a " <>
           "reload, and Revoke reads revoked" do
      %{terry: terry, alice: alice, traders: traders} = traders!()
      market = key!(terry, "market key", @market)

      {terry_view, _} = vault!(terry)
      {alice_view, _} = vault!(alice)

      share = share!(terry, market, %{"audience" => "group", "group_id" => traders.id})

      wait_until(fn -> has_element?(terry_view, by_you(share)) end, 2_000, "the owner's row")
      wait_until(fn -> has_element?(alice_view, with_you(share)) end, 2_000, "the offered row")

      {:ok, _} =
        Sanctum.Gate.call_external("share", terry.ctx, %{
          "action" => "set_caps",
          "share_id" => share.id,
          "person_daily" => 3
        })

      wait_until(
        fn ->
          texts(terry_view, by_you(share) <> ~s( [data-test="share-line"])) ==
            ["market key, shared with Traders, 0 today, at most 3 a person a day"]
        end,
        2_000,
        "the caps read again"
      )

      # Revoke is confirmed in the browser and needs the session alone.
      revoke = by_you(share) <> ~s( [data-test="share-revoke"])
      assert terry_view |> element(revoke) |> render() =~ "Revoke this share?"
      terry_view |> element(revoke) |> render_click()

      assert has_element?(terry_view, by_you(share) <> ~s([data-status="revoked"]))

      assert texts(terry_view, by_you(share) <> ~s( [data-test="share-line"])) ==
               ["market key, shared with Traders, revoked"]

      refute has_element?(terry_view, revoke)
      wait_until(fn -> not has_element?(alice_view, with_you(share)) end, 2_000, "gone")
      Cyfr.Test.Sandbox.end_views()
    end

    test "the caps are set on the row, and an audience widened asks a fresh confirmation " <>
           "naming the audience the row showed" do
      %{terry: terry, traders: traders} = traders!()
      market = key!(terry, "market key", @market)
      share = share!(terry, market, %{"audience" => "group", "group_id" => traders.id})
      {view, _} = vault!(terry)

      view
      |> element(by_you(share) <> ~s( form[data-test="share-caps-form"]))
      |> render_submit(%{"person_daily" => "0", "total_daily" => "10"})

      assert texts(view, by_you(share) <> ~s( [data-test="share-line"])) ==
               [
                 "market key, shared with Traders, 0 today, no use a person, at most 10 in all a day"
               ]

      view
      |> element(by_you(share) <> ~s( form[data-test="share-audience-form"]))
      |> render_submit(%{"audience" => "everyone"})

      assert {:ok, [%{ref: ref, operation: "share.set_audience"}]} =
               Arca.PendingConfirmations.list_open(
                 Sanctum.Context.actor(terry.ctx),
                 terry.user.user_id
               )

      Sanctum.TestContext.prove!(terry.ctx, ref)

      wait_until(
        fn ->
          texts(view, by_you(share) <> ~s( [data-test="share-line"])) ==
            [
              "market key, shared with everyone, 0 today, no use a person, at most 10 in all a day"
            ]
        end,
        2_000,
        "the widened audience"
      )

      Cyfr.Test.Sandbox.end_views()
    end

    test "after a declared restore the share reads revoked, and Share is offered again once " <>
           "the entry is rotated" do
      %{terry: terry, traders: traders} = traders!()
      market = key!(terry, "market key", @market)
      share = share!(terry, market, %{"audience" => "group", "group_id" => traders.id})

      {:ok, _marked} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
      {:ok, %{restore_id: _}} = Arca.SecurityTransitions.restore(slot: :none)

      terry = %{terry | conn: log_in_user(build_conn(), terry.user)}
      {view, _} = vault!(terry)

      assert texts(view, by_you(share) <> ~s( [data-test="share-line"])) ==
               ["market key, shared with Traders, revoked"]

      refute has_element?(view, share_button(market))

      # The person recovers their passkey, as a recovery re-enables it, and
      # rotates the key under its confirmation.
      passkey = Arca.Repo.get_by!(Arca.Schemas.Passkey, user_id: terry.user.user_id)

      {:ok, _} =
        Arca.Passkeys.reenable(Prima.Actor.system(), terry.user.user_id, passkey.id,
          verify: fn _passkey -> :ok end
        )

      {:ok, %{entries: [%{payload_rev: rev}]}} =
        Sanctum.Gate.call_external("vault", terry.ctx, %{"action" => "list"})

      {:ok, _} =
        Sanctum.TestContext.confirming(
          terry.ctx,
          &Sanctum.Gate.call_external("vault", &1, %{
            "action" => "rotate",
            "id" => market.id,
            "fields" => %{"MARKET_KEY" => "mk-sentinel-rotated"},
            "expected_payload_rev" => rev
          })
        )

      wait_until(fn -> has_element?(view, share_button(market)) end, 2_000, "Share again")
      Cyfr.Test.Sandbox.end_views()
    end
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
      {view, _html} = mount_athanor(conn, "/vault")
      ctx = seated_ctx(user)
      render_click(view, "show_add", %{"mode" => "fields"})

      typed = %{
        "name" => "resent-#{System.unique_integer([:positive])}",
        "kind" => "api_key",
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

    test "create: a kind the form does not make, sent again, lets the proof go and makes " <>
           "nothing",
         %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      {view, _html} = mount_athanor(conn, "/vault")
      ctx = seated_ctx(user)
      render_click(view, "show_add", %{"mode" => "fields"})

      typed = %{
        "name" => "resent-#{System.unique_integer([:positive])}",
        "kind" => "api_key",
        "fields" => "OPENAI_API_KEY=sk-resent",
        "destination_hosts" => "api.openai.com"
      }

      view |> form("#vault-create-form", typed) |> render_submit()
      assert [%{ref: ref, operation: "vault.create"}] = open_records(ctx)
      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "vault-create-form"}, 2_000)

      html = render_submit(view, "create", %{typed | "kind" => "oauth"})

      assert html =~ @not_a_kind
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
      {view, _html} = mount_athanor(conn, "/vault")
      ctx = seated_ctx(user)
      render_click(view, "show_add", %{"mode" => "fields"})

      typed = %{
        "name" => "resent-#{System.unique_integer([:positive])}",
        "kind" => "api_key",
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
          &Sanctum.Gate.call_external("vault", &1, %{
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
      {view, _html} = mount_athanor(conn, "/vault")
      render_click(view, "show_add", %{"mode" => "fields"})
      pasted = "sk-pasted-#{System.unique_integer([:positive])}"

      html =
        view
        |> form("#vault-create-form", %{
          "name" => "pasted-#{System.unique_integer([:positive])}",
          "kind" => "api_key",
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
      {view, _html} = mount_athanor(conn, "/vault")
      ctx = seated_ctx(user)

      entry =
        create_confirmed!(view, ctx, %{
          "name" => "rotated-#{System.unique_integer([:positive])}",
          "kind" => "api_key",
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
