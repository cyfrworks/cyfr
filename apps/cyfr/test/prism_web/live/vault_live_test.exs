# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.VaultLiveTest do
  @moduledoc """
  Tests sign-in gating, vault-entry server references, the destination
  and disclosure a new entry names, and management of operator OAuth
  client credentials on the Vault page.

  Storing client credentials is a sensitive change: the page asks
  through its system layer, and nothing is stored until the person
  confirms the record; the browser then submits the same form again,
  which still holds what was typed, and the page stores it. The page
  holds no typed secret while it waits. Listing and removing them need
  the session alone.
  """
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

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
    {view, _html} = mount_athanor(conn, "/vault")
    render_click(view, "show_add", %{"mode" => "fields"})

    # No installed need stands behind this page, so the person types the
    # destination: no host is offered, and a component reading the value
    # is off until they turn it on.
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

  describe "provided by this instance" do
    @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))
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
      {view, _html} = conn |> log_in_user(user) |> mount_athanor("/vault")
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

      {:ok, entries} = Sanctum.Vault.list(ctx)
      refute Enum.any?(entries, &(&1.name == typed["name"]))

      # The same change submitted again is asked for afresh.
      view |> form("#vault-create-form", typed) |> render_submit()
      assert [%{ref: again, operation: "vault.create"}] = open_records(ctx)
      refute again == ref
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
      {view, _html} = conn |> log_in_user(user) |> mount_athanor("/vault")
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
      {view, _html} = conn |> log_in_user(user) |> mount_athanor("/vault")
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
      {view, _html} = conn |> log_in_user(user) |> mount_athanor("/vault")
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
