# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SettingsLiveTest.LinkFlow do
  @moduledoc false
  # A device flow whose provider the suite plays: it starts with a code,
  # and its poll answers the link ticket a completed sign-in with the door
  # would, for the identity the test names (`:settings_link_identity`).
  def init_device_flow(provider, _client_ip) when provider in [:github, :google] do
    {:ok,
     %{
       device_code: "dc-settings-link",
       user_code: "LINK-2026",
       verification_uri: "https://github.com/login/device",
       interval: 5
     }}
  end

  def poll_for_link(provider, "dc-settings-link", _client_ip, ctx) do
    key = Application.fetch_env!(:sanctum, :settings_link_identity)

    with {:ok, ticket} <-
           Sanctum.SignIn.link_ticket(ctx, %{key: key, provider: provider, email: nil}) do
      {:ok, %{status: "complete", provider: to_string(provider), ticket: ticket}}
    end
  end
end

defmodule PrismWeb.SettingsLiveTest do
  @moduledoc """
  Settings: the door and the platform settings are the operator's
  sections and nobody else's; the lite/dev preference is every person's
  own.

  The person's identity, doors and passkeys are their own: read through
  `person.status` and `passkey.list`, each change an operation through the
  gate, each one that needs a fresh confirmation asked through the page's
  system layer and made again once confirmed, and every recovery prompt
  drawn in the layer alone.
  """
  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Arca.Schemas.PersonIdentity
  alias Prima.Identity
  alias Prima.Identity.Entry
  alias Sanctum.{Cipher, CipherAAD}
  alias Sanctum.TestContext.Authenticator

  test "the door section is shown to a platform admin and to nobody else", %{conn: conn} do
    person = test_user()
    {view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")
    refute html =~ "Server allowlist"
    refute has_element?(view, "button[phx-click=door_allow]")

    ops = test_user()
    {:ok, _} = Sanctum.Tenancy.Members.ensure_platform(ops.user_id)
    {admin_view, admin_html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
    assert admin_html =~ "Server allowlist"

    email = "letin-#{System.unique_integer([:positive])}@example.com"

    # The entry typed is what the Allow button carries; the click adds
    # nothing of its own.
    admin_view
    |> element(~s(form[phx-change="door_form_changed"]))
    |> render_change(%{"value" => email})

    assert has_element?(admin_view, ~s(button[phx-click="door_allow"][phx-value-door="#{email}"]))
    assert has_element?(admin_view, ~s(button[phx-click="door_deny"][phx-value-door="#{email}"]))

    admin_view
    |> element("button[phx-click=door_allow]")
    |> render_click()

    assert render(admin_view) =~ email
    assert {:ok, :allowed} = Sanctum.Door.admit("github|https://github.com|x", email, true)
  end

  test "the platform settings card is the operator's, saves against its revision, and shows a pin read-only",
       %{conn: conn} do
    pinned = Application.get_env(:cyfr, :deployment_pinned)

    on_exit(fn ->
      if pinned,
        do: Application.put_env(:cyfr, :deployment_pinned, pinned),
        else: Application.delete_env(:cyfr, :deployment_pinned)
    end)

    Application.put_env(:cyfr, :deployment_pinned, [{"max_athanors", 5}])

    person = test_user()
    {_view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")
    refute html =~ "Platform settings"

    ops = test_user()
    {:ok, _} = Sanctum.Tenancy.Members.ensure_platform(ops.user_id)
    {view, html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")

    assert html =~ "Platform settings"
    assert html =~ "reaches new and refreshed work"
    assert html =~ "within 30 s"

    # A pinned key is the deployment's: no form, and the card says so.
    refute has_element?(view, "#setting-max_athanors")
    assert html =~ "set by the deployment"

    view |> form("#setting-mcp_rate_limit_max", %{"value" => "240"}) |> render_submit()
    assert Arca.PlatformSettings.effective("mcp_rate_limit_max") == {:ok, 240}
    assert render(view) =~ "mcp_rate_limit_max saved."

    # A value under the floor is refused with its range, and nothing moves.
    view |> form("#setting-mcp_rate_limit_max", %{"value" => "0"}) |> render_submit()
    assert render(view) =~ "from 1 to 1000000000"
    assert Arca.PlatformSettings.effective("mcp_rate_limit_max") == {:ok, 240}

    # A write this card has not heard of since it listed refuses its next
    # change, and the card lists again, so the one after goes through.
    {:ok, %{revision: revision}} = Arca.PlatformSettings.all()
    {:ok, _} = Arca.PlatformSettings.put("device_label", "elsewhere", revision, "other")

    reset = "button[phx-click=setting_reset][phx-value-key=mcp_rate_limit_max]"
    view |> element(reset) |> render_click()
    assert render(view) =~ "changed since they were read"
    assert Arca.PlatformSettings.effective("mcp_rate_limit_max") == {:ok, 240}

    view |> element(reset) |> render_click()
    assert Arca.PlatformSettings.get("mcp_rate_limit_max") == {:error, :not_found}
  end

  # ---------------------------------------------------------------------------
  # The instance's own entries
  # ---------------------------------------------------------------------------

  describe "the instance-entry cards" do
    @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

    @create %{
      "name" => "shared-model",
      "provider_hint" => "example.com",
      "kind" => "api_key",
      "destination_hosts" => "api.example.com",
      "destination_scheme" => "https",
      "destination_methods" => "GET POST",
      "destination_paths" => "/v1/chat/completions /v1/models",
      "component_policy" => "any",
      "audience" => "everyone",
      "person_daily" => "",
      "total_daily" => ""
    }

    @destination %{
      "hosts" => ["api.example.com"],
      "scheme" => "https",
      "methods" => ["GET", "POST"],
      "paths" => ["/v1/chat/completions", "/v1/models"]
    }

    # A platform administrator, signed in to their own athanor, on the
    # Settings page; `ctx` is their context there.
    defp admin!(conn) do
      ops = test_user(%{name: "Ops Person"})
      {:ok, _} = Sanctum.Tenancy.Members.ensure_platform(ops.user_id)
      conn = log_in_user(conn, ops)
      ctx = admin_context(ops, seated_athanor().id)
      {view, html} = mount_athanor(conn, "/settings")
      %{view: view, html: html, ops: ops, ctx: ctx}
    end

    defp admin_context(ops, athanor_id) do
      Sanctum.Context.build(
        user_id: ops.user_id,
        athanor_id: athanor_id,
        permissions: Sanctum.Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true,
        platform_admin: true
      )
    end

    # An entry the administrator made, under its proven confirmation.
    defp entry!(ctx, over \\ %{}) do
      params =
        Map.merge(
          %{
            name: "entry-#{System.unique_integer([:positive])}",
            kind: "api_key",
            provider_hint: "example.com",
            fields: %{"API_KEY" => "sk-settings-entry"},
            destination: @destination,
            audience: "everyone"
          },
          over
        )

      confirmed =
        Sanctum.TestContext.confirmed(ctx, :credential_entry, %{
          operation: "instance_entry.create",
          arguments: params,
          resource: params.name
        })

      {:ok, entry} = Sanctum.InstanceEntries.create(confirmed, params)
      entry
    end

    defp stored(id) do
      {:ok, entries} = Arca.InstanceEntries.list(Prima.Actor.system())
      Enum.find(entries, &(&1.id == id))
    end

    defp open_records(ctx) do
      {:ok, open} = Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)
      open
    end

    defp state_of(view),
      do: inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)

    defp record_state(ctx, ref) do
      {:ok, row} = Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), ref)
      row.state
    end

    # Every admitted `instance_entry/set_audience` is told to the test.
    defp watch_saves do
      test_pid = self()
      handler = "settings-saves-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :grimoire, :decision, :admitted],
          fn _event, _measure, meta, _config ->
            if meta.tool == "instance_entry" and meta.action == "set_audience",
              do: send(test_pid, :save_admitted)
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    defp saves_admitted do
      receive do
        :save_admitted -> 1 + saves_admitted()
      after
        0 -> 0
      end
    end

    # The owner's sentence for an audience that moved since it was shown,
    # as the page's flash and the layer's prompt each show it.
    @conflict "The audience changed since it was shown, so nothing was saved."
    @page_conflict "Instance entries: " <> @conflict
    @prompt_conflict "Refused: " <> @conflict

    # Every audience the owner writes is told to the test: the store's own
    # writes announce nothing, so each one is a save that was made.
    defp watch_audience_writes do
      test_pid = self()
      handler = "settings-audience-writes-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :sanctum, :instance_entry, :audience],
          fn _event, _measure, meta, _config ->
            send(test_pid, {:audience_written, meta.entry_id})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    # A widening asked for and held, then made elsewhere before the proof:
    # the stored audience is now what the widening asks for, but not the
    # one it was decided against, so the proof's repeat, the confirmed
    # request with its `expected` audience, meets the owner's conflict.
    defp moot_repeat!(conn) do
      %{view: view, ctx: ctx} = admin!(conn)
      a = test_user(%{name: "A One"}).user_id
      b = test_user(%{name: "B Two"}).user_id
      entry = entry!(ctx, %{audience: "listed", members: [a]})
      send(view.pid, :load)
      form = "#instance-audience-#{entry.id}"
      assert has_element?(view, form <> ~s( input[name="members[]"][value="#{b}"]))
      watch_saves()

      view |> element(form) |> render_submit(%{"members" => [a, b]})
      assert saves_admitted() == 1
      assert [%{ref: ref}] = open_records(ctx)

      assert :ok =
               Arca.InstanceEntries.set_audience(
                 Prima.Actor.system(),
                 entry.id,
                 %{audience: "listed", members: [a]},
                 %{audience: "listed", members: Enum.sort([a, b])}
               )

      send(view.pid, %Cyfr.Bus.InstanceEntryChanged{kind: :audience, entry_id: entry.id})
      watch_audience_writes()
      prove_asked!(view, ctx, ref)
      wait_until(fn -> render(view) =~ @page_conflict end, 2_000, "the repeat answered")
      assert saves_admitted() == 1, "the repeat was not sent exactly once"
      refute_received {:audience_written, _}, "the conflicting repeat wrote an audience"
      %{view: view, ctx: ctx, a: a, b: b, entry: entry, form: form, ref: ref}
    end

    test "are the operator's: a member sees neither, and the operations refuse them regardless",
         %{conn: conn} do
      member = test_user()
      {view, html} = conn |> log_in_user(member) |> mount_athanor("/settings")

      refute has_element?(view, ~s([data-test="instance-entries"]))
      refute has_element?(view, ~s([data-test="instance-use"]))
      refute has_element?(view, "#instance-create")

      # Not even a card's title reaches a member's page, in a comment or
      # anywhere else.
      for title <- ["Instance entries", "A new instance entry", "Server allowlist"],
          do: refute(html =~ title, title)

      ctx = %{admin_context(member, seated_athanor().id) | platform_admin: false}

      for action <- ~w(list people) do
        assert {:error, refusal} =
                 Grimoire.call_external("instance_entry", ctx, %{"action" => action})

        assert Grimoire.render(refusal) =~ ~r/platform admin/i, action
      end
    end

    test "a new entry's key is typed in the layer's prompt alone, and the entry is made once " <>
           "its record is confirmed",
         %{conn: conn} do
      %{view: view, html: html, ctx: ctx} = admin!(conn)
      secret = "sk-settings-#{System.unique_integer([:positive])}-sentinel"
      name = "shared-#{System.unique_integer([:positive])}"

      assert html =~ "Instance entries"
      assert html =~ "creating one of kind oauth is refused"
      assert has_element?(view, ~s(#instance-create option[value="api_key"]))
      refute has_element?(view, ~s(#instance-create option[value="oauth"]))

      # The card has no field for the key.
      refute has_element?(view, ~s(#instance-create input[type="password"]))
      refute has_element?(view, ~s(#instance-create [name="fields"]))

      view |> form("#instance-create", Map.put(@create, "name", name)) |> render_submit()

      # The layer asks for the key, with everything else the card collected.
      assert has_element?(
               view,
               ~s(#system-layer form#system-layer-credential[data-target="instance"])
             )

      assert render(view) =~ "Enter the key for the instance entry #{name}"

      view
      |> form("#system-layer-credential", %{"secret" => secret})
      |> render_submit()

      assert [%{ref: ref, operation: "instance_entry.create"}] = open_records(ctx)
      refute state_of(view) =~ secret

      assert Enum.all?(
               Arca.InstanceEntries.list(Prima.Actor.system()) |> elem(1),
               &(&1.name != name)
             )

      Sanctum.TestContext.prove!(ctx, ref)
      assert_push_event(view, "system_layer:resubmit", %{form: "system-layer-credential"}, 2_000)
      view |> form("#system-layer-credential", %{"secret" => secret}) |> render_submit()

      wait_until(fn -> render(view) =~ "Instance entry created." end, 2_000, "the entry created")

      {:ok, entries} = Arca.InstanceEntries.list(Prima.Actor.system())
      entry = Enum.find(entries, &(&1.name == name))

      assert {entry.provider_hint, entry.component_policy, entry.audience} ==
               {"example.com", "any", "everyone"}

      assert Jason.decode!(entry.destination) == @destination
      assert has_element?(view, ~s([data-test="instance-entry"][data-id="#{entry.id}"]))

      refute state_of(view) =~ secret
      refute render(view) =~ secret
    end

    test "a create with no path, or no method, is refused, and the card says which",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)

      view |> form("#instance-create", %{@create | "destination_paths" => ""}) |> render_submit()

      assert has_element?(view, ~s([data-test="instance-error"]), "names no paths")
      refute has_element?(view, ~s(#system-layer-credential))

      view
      |> form("#instance-create", %{
        @create
        | "destination_paths" => "",
          "destination_methods" => ""
      })
      |> render_submit()

      assert has_element?(view, ~s([data-test="instance-error"]), "names no methods and no paths")
      refute has_element?(view, ~s(#system-layer-credential))
      assert open_records(ctx) == []
    end

    test "the component policy is one control, any at first, with its two options and its " <>
           "sentence and no component picker; anything else forged is refused",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)

      policy = ~s(#instance-create input[name="component_policy"])
      assert view |> element(policy <> ~s([value="any"][checked])) |> has_element?()
      refute view |> element(policy <> ~s([value="shipped"][checked])) |> has_element?()
      assert render(view) =~ "Any consented component"
      assert render(view) =~ "Unmodified shipped components"

      assert render(view) =~
               "Any component a person consents to can use this account within these " <>
                 "destination methods and paths, including operations shipped components do not use."

      # Two options of one control, and nothing that names a component.
      html = view |> element("#instance-create") |> render()
      assert length(Regex.scan(~r/name="component_policy"/, html)) == 2
      refute html =~ ~r/name="component[s]?(\[\])?"/

      # A value the control never offers is refused before any key is asked.
      view
      |> element("#instance-create")
      |> render_submit(%{@create | "component_policy" => "everything"})

      assert has_element?(
               view,
               ~s([data-test="instance-error"]),
               "Choose Any consented component"
             )

      refute has_element?(view, ~s(#system-layer-credential))

      # And an entry's own policy form refuses it, as the operation does
      # whoever sends it.
      entry = entry!(ctx)
      send(view.pid, :load)

      view
      |> element("#instance-policy-#{entry.id}")
      |> render_submit(%{"entry_id" => entry.id, "component_policy" => "everything"})

      assert render(view) =~ "Choose Any consented component or Unmodified shipped components."

      assert {:error, _refused} =
               Grimoire.call_external("instance_entry", ctx, %{
                 "action" => "set_component_policy",
                 "entry_id" => entry.id,
                 "component_policy" => "everything"
               })

      assert stored(entry.id).component_policy == "any"
    end

    test "a rotation asks for the key in the prompt and waits on its confirmation", %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      entry = entry!(ctx)
      send(view.pid, %Cyfr.Bus.InstanceEntryChanged{kind: :created, entry_id: entry.id})
      render(view)

      view
      |> element(~s(button[phx-click="instance_rotate"][phx-value-id="#{entry.id}"]))
      |> render_click()

      assert render(view) =~ "Rotate the instance entry #{entry.name}"

      view |> form("#system-layer-credential", %{"secret" => "sk-rotated"}) |> render_submit()

      assert [%{operation: "instance_entry.rotate"}] = open_records(ctx)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))
      assert stored(entry.id).payload_rev == entry.payload_rev
    end

    test "an audience that widens asks for a fresh confirmation; one that narrows is saved",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      alice = test_user(%{name: "Alice Listed"})
      bob = test_user(%{name: "Bob Listed"})
      entry = entry!(ctx, %{audience: "listed", members: [alice.user_id]})

      # The people the picker offers have signed in; someone who has not
      # cannot be added.
      send(view.pid, :load)
      html = render(view)
      assert html =~ "Alice Listed" and html =~ "Bob Listed"
      assert html =~ "A person who has not signed in yet cannot be added."
      assert has_element?(view, ~s(#instance-audience-#{entry.id} input[value="#{bob.user_id}"]))

      widen = %{
        "entry_id" => entry.id,
        "audience" => "listed",
        "members" => [alice.user_id, bob.user_id]
      }

      view |> element("#instance-audience-#{entry.id}") |> render_submit(widen)

      assert [%{ref: ref, operation: "instance_entry.set_audience"}] = open_records(ctx)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))
      assert stored(entry.id).members == [alice.user_id]

      Sanctum.TestContext.prove!(ctx, ref)
      wait_until(fn -> render(view) =~ "Audience saved." end, 2_000, "the widening made")
      assert Enum.sort(stored(entry.id).members) == Enum.sort([alice.user_id, bob.user_id])

      narrow = %{"entry_id" => entry.id, "audience" => "listed", "members" => [alice.user_id]}
      view |> element("#instance-audience-#{entry.id}") |> render_submit(narrow)

      assert open_records(ctx) == []
      assert stored(entry.id).members == [alice.user_id]
      assert render(view) =~ "Audience saved."

      # A typed email sent past the picker names no one: refused once its
      # widening is proven, and never stored.
      typed = "typed-#{System.unique_integer([:positive])}@example.com"
      forged = %{narrow | "members" => [alice.user_id, typed]}
      view |> element("#instance-audience-#{entry.id}") |> render_submit(forged)

      assert [%{ref: ref, operation: "instance_entry.set_audience"}] = open_records(ctx)
      Sanctum.TestContext.prove!(ctx, ref)
      wait_until(fn -> render(view) =~ "person_unknown" end, 2_000, "the refusal shown")

      assert render(view) =~ "members names someone who has not signed in"
      refute render(view) =~ typed
      assert stored(entry.id).members == [alice.user_id]

      # A person denied here is no one an audience can name, so the picker
      # does not offer them.
      {:ok, _} =
        Arca.SecurityTransitions.deny_user(Prima.Actor.system(), bob.user_id,
          verify: fn _rows -> :ok end
        )

      send(view.pid, :load)
      refute has_element?(view, ~s(#instance-audience-#{entry.id} input[value="#{bob.user_id}"]))

      assert has_element?(
               view,
               ~s(#instance-audience-#{entry.id} input[value="#{alice.user_id}"])
             )
    end

    test "shipped to any asks a fresh confirmation bound to the entry and the setting; any to " <>
           "shipped is saved with the session",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      entry = entry!(ctx)
      send(view.pid, :load)
      render(view)

      tighten = %{"entry_id" => entry.id, "component_policy" => "shipped"}
      view |> element("#instance-policy-#{entry.id}") |> render_submit(tighten)

      assert open_records(ctx) == []
      assert stored(entry.id).component_policy == "shipped"
      assert render(view) =~ "Component policy saved."

      widen = %{"entry_id" => entry.id, "component_policy" => "any"}
      view |> element("#instance-policy-#{entry.id}") |> render_submit(widen)

      assert [%{ref: ref, operation: "instance_entry.set_component_policy"}] = open_records(ctx)
      {:ok, record} = Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), ref)
      preview = inspect(record.preview)
      assert preview =~ entry.name
      assert preview =~ "shipped → any"
      assert stored(entry.id).component_policy == "shipped"

      Sanctum.TestContext.prove!(ctx, ref)
      wait_until(fn -> stored(entry.id).component_policy == "any" end, 2_000, "the widening made")
    end

    test "a policy changed anywhere is shown again", %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      entry = entry!(ctx)
      send(view.pid, :load)

      shown =
        ~s([data-test="instance-entry"][data-id="#{entry.id}"] [data-test="instance-policy-shown"])

      assert has_element?(view, shown, "Any consented component")

      # Changed by another page of the instance: the announcement alone
      # brings the page the new setting.
      {:ok, :changed} =
        Sanctum.InstanceEntries.set_component_policy(ctx, %{
          entry_id: entry.id,
          component_policy: "shipped"
        })

      wait_until(
        fn -> has_element?(view, shown, "Unmodified shipped components") end,
        2_000,
        "the policy shown again"
      )
    end

    test "a new entry's destination is prefilled from the newest shipped catalyst of the " <>
           "provider; what it does not declare is entered",
         %{conn: conn} do
      Cyfr.Test.SeedBundle.isolate!()
      ops = test_user()
      {:ok, _} = Sanctum.Tenancy.Members.ensure_platform(ops.user_id)
      conn = log_in_user(conn, ops)
      athanor_id = seated_athanor().id

      seed_ctx =
        Sanctum.internal_context(user_id: "_test", athanor_id: athanor_id, scope: :athanor)

      ship = fn name, version, provider, need ->
        {:ok, _} =
          Arca.Test.UnitFixtures.ship_and_register!(seed_ctx, "catalyst", "local", name, version,
            manifest: %{
              "name" => name,
              "type" => "catalyst",
              "version" => version,
              "publisher" => "local",
              "needs" => %{
                "api_key" =>
                  Map.merge(
                    %{
                      "type" => "api_key:#{provider}",
                      "reason" => "to call the model",
                      "fields" => ["API_KEY"],
                      "attach" => %{
                        "in" => "header",
                        "name" => "Authorization",
                        "template" => "Bearer {value}"
                      }
                    },
                    need
                  )
              },
              "caps" => %{"egress" => %{"domains" => ["api.example.com", "old.example.com"]}}
            },
            wasm: @wasm
          )
      end

      ship.("prefill-model", "1.0.0", "example.com", %{
        "hosts" => ["old.example.com"],
        "paths" => ["/v0/"]
      })

      ship.("prefill-model", "1.1.0", "example.com", %{
        "hosts" => ["api.example.com"],
        "paths" => ["/v1/chat/completions"]
      })

      ship.("prefill-hosts", "1.0.0", "hosts-only.example", %{"hosts" => ["api.example.com"]})

      {view, _html} = mount_athanor(conn, "/settings")
      assert has_element?(view, ~s(#instance-providers option[value="example.com"]))

      view |> form("#instance-create", %{"provider_hint" => "example.com"}) |> render_change()

      assert has_element?(
               view,
               ~s(#instance-create input[name="destination_hosts"][value="api.example.com"])
             )

      assert has_element?(
               view,
               ~s(#instance-create input[name="destination_paths"][value="/v1/chat/completions"])
             )

      # A need that declares no paths leaves them to be entered, and the
      # card refuses a create until they are.
      view
      |> form("#instance-create", %{
        "provider_hint" => "hosts-only.example",
        "destination_paths" => ""
      })
      |> render_change()

      assert has_element?(
               view,
               ~s(#instance-create input[name="destination_hosts"][value="api.example.com"])
             )

      refute has_element?(view, ~s(#instance-create input[name="destination_paths"][value^="/"]))

      view
      |> form("#instance-create", %{
        "name" => "hosts-only",
        "provider_hint" => "hosts-only.example",
        "destination_methods" => "POST",
        "destination_paths" => ""
      })
      |> render_submit()

      assert has_element?(view, ~s([data-test="instance-error"]), "names no paths")
    end

    test "a blank cap shows the platform default it takes, and 0 says that no use is admitted",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      {:ok, person_default} = Arca.PlatformSettings.effective("instance_entry_person_daily")
      {:ok, total_default} = Arca.PlatformSettings.effective("instance_entry_total_daily")

      assert has_element?(
               view,
               ~s(#instance-create [data-test="cap-person"]),
               "the platform default, #{person_default} a day"
             )

      assert has_element?(
               view,
               ~s(#instance-create [data-test="cap-total"]),
               "the platform default, #{total_default} a day"
             )

      view |> form("#instance-create", %{"person_daily" => "0"}) |> render_change()

      assert has_element?(
               view,
               ~s(#instance-create [data-test="cap-person"]),
               "no use is admitted"
             )

      entry = entry!(ctx, %{person_daily: 0})
      send(view.pid, :load)
      caps = ~s([data-test="instance-entry"][data-id="#{entry.id}"] [data-test="instance-caps"])
      assert has_element?(view, caps, "each person 0: no use is admitted")
      assert has_element?(view, caps, "the platform default, #{total_default} a day")

      # A blank is sent as the platform default, a 0 as no use.
      view
      |> element("#instance-caps-#{entry.id}")
      |> render_submit(%{"entry_id" => entry.id, "person_daily" => "", "total_daily" => "0"})

      assert %{person_daily: nil, total_daily: 0} = stored(entry.id)
    end

    test "two administrators changing the two caps: each form sends only the cap it changed, " <>
           "and both changes stand",
         %{conn: conn} do
      %{view: first, ctx: ctx} = admin!(conn)
      %{view: second} = admin!(build_conn())
      entry = entry!(ctx)

      for view <- [first, second], do: send(view.pid, :load)
      caps = "#instance-caps-#{entry.id}"
      assert has_element?(first, caps) and has_element?(second, caps)

      # Both forms were drawn with both caps unset. Each administrator
      # changes one, and submits the form as their browser still holds it.
      as_drawn = %{
        "entry_id" => entry.id,
        "person_daily_loaded" => "",
        "total_daily_loaded" => ""
      }

      first
      |> element(caps)
      |> render_submit(Map.merge(as_drawn, %{"person_daily" => "5", "total_daily" => ""}))

      second
      |> element(caps)
      |> render_submit(Map.merge(as_drawn, %{"person_daily" => "", "total_daily" => "7"}))

      assert %{person_daily: 5, total_daily: 7} = stored(entry.id)

      # A form submitted as drawn changed nothing, and sends nothing.
      send(first.pid, :load)
      first |> element(caps) |> render_submit(%{})
      assert render(first) =~ "Nothing changed."
      assert %{person_daily: 5, total_daily: 7} = stored(entry.id)
    end

    test "a people read that fails says so in the picker and saves no audience",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      entry = entry!(ctx, %{audience: "listed", members: [ctx.user_id]})
      send(view.pid, :load)
      save = ~s(#instance-audience-#{entry.id} button[data-test="instance-audience-save"])
      assert has_element?(view, save)
      refute has_element?(view, save <> "[disabled]")

      # The page's session stands on what it already checked, so only the
      # reads this card makes meet the store's refusal.
      keep_env(:sanctum, [:caller_memo_ttl_ms])
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 600_000)
      Arca.Repo.query!("ALTER TABLE users RENAME TO users_unavailable")
      send(view.pid, :load)

      assert has_element?(
               view,
               ~s(#instance-audience-#{entry.id} [data-test="people-error"]),
               "could not be read"
             )

      assert has_element?(view, save <> "[disabled]")

      # Whatever the form sends, no audience is saved.
      view
      |> element("#instance-audience-#{entry.id}")
      |> render_submit(%{"entry_id" => entry.id, "audience" => "everyone"})

      assert render(view) =~ "no one can be listed now"
      assert %{audience: "listed"} = stored(entry.id)
    end

    test "a person another client listed after the page loaded is never dropped by a save: " <>
           "the picker reloads, an unedited stale form sends nothing, and an edit made on it " <>
           "is a conflict",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      alice = test_user(%{name: "Alice First"})
      entry = entry!(ctx, %{audience: "listed", members: [alice.user_id]})
      send(view.pid, :load)
      form = "#instance-audience-#{entry.id}"
      assert has_element?(view, form <> ~s( input[value="#{alice.user_id}"][checked]))

      # A person signs in after this page loaded, and another client lists
      # them; the announcement reaches this page.
      bob = test_user(%{name: "Bob Later"})
      both = Enum.sort([alice.user_id, bob.user_id])

      args = %{
        entry_id: entry.id,
        audience: "listed",
        members: both,
        expected: %{audience: "listed", members: [alice.user_id]}
      }

      assert {:ok, :changed} =
               Sanctum.TestContext.confirming(
                 ctx,
                 &Sanctum.InstanceEntries.set_audience(&1, args)
               )

      wait_until(
        fn -> render(view) =~ bob.user_id end,
        2_000,
        "the listing reached the page"
      )

      # A form drawn before the listing, as a browser that never re-drew it
      # still holds it: Bob has no checkbox and Alice stays checked. Its
      # save is no edit, and drops no one.
      as_drawn = %{
        "entry_id" => entry.id,
        "audience" => "listed",
        "audience_shown" => "listed",
        "members" => [alice.user_id],
        "members_shown" => [alice.user_id]
      }

      view |> element(form) |> render_submit(as_drawn)

      assert Enum.sort(stored(entry.id).members) == both,
             "an unedited save dropped Bob, who had no checkbox"

      # The picker has the newcomer, checked as listed, under their name.
      assert has_element?(view, form <> ~s( input[value="#{bob.user_id}"][checked]))
      assert render(view) =~ "listed: Alice First, Bob Later"

      # The form saved as it stands changes nothing.
      view |> form(form) |> render_submit()
      assert render(view) =~ "Nothing changed."
      assert Enum.sort(stored(entry.id).members) == both

      # The administrator's own removal of Alice from the stale form was
      # decided against an audience without Bob: a conflict, nothing saved,
      # and the card shows the stored audience again.
      view |> element(form) |> render_submit(%{as_drawn | "members" => []})
      assert render(view) =~ @page_conflict
      assert Enum.sort(stored(entry.id).members) == both

      # Made on the form as it now shows, the removal takes Alice out, and
      # Bob stays.
      view |> element(form) |> render_submit(%{"members" => [bob.user_id]})
      assert stored(entry.id).members == [bob.user_id]
    end

    test "a save decided against an audience that moved since the card showed it is a " <>
           "conflict: nothing is saved or asked, and the card reloads and says why",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      alice = test_user(%{name: "Alice First"})
      bob = test_user(%{name: "Bob Unchecked"})
      carol = test_user(%{name: "Carol Elsewhere"})
      entry = entry!(ctx, %{audience: "listed", members: Enum.sort([alice.user_id, bob.user_id])})
      send(view.pid, :load)
      form = "#instance-audience-#{entry.id}"

      assert has_element?(
               view,
               form <> ~s( input[name="members_shown[]"][value="#{bob.user_id}"])
             )

      watch_audience_writes()

      # Carol is listed at the store; this page has not heard.
      assert :ok =
               Arca.InstanceEntries.set_audience(
                 Prima.Actor.system(),
                 entry.id,
                 %{audience: "listed", members: Enum.sort([alice.user_id, bob.user_id])},
                 %{
                   audience: "listed",
                   members: Enum.sort([alice.user_id, bob.user_id, carol.user_id])
                 }
               )

      refute has_element?(
               view,
               form <> ~s( input[name="members_shown[]"][value="#{carol.user_id}"])
             )

      # A narrowing, which would need no prompt, decided on the card as it
      # showed the audience.
      view |> element(form) |> render_submit(%{"members" => [alice.user_id]})

      assert render(view) =~ @page_conflict
      assert open_records(ctx) == []
      refute_received {:audience_written, _}

      assert Enum.sort(stored(entry.id).members) ==
               Enum.sort([alice.user_id, bob.user_id, carol.user_id])

      # The card reloaded the stored audience: Carol is listed, and checked.
      assert has_element?(
               view,
               form <> ~s( input[name="members[]"][value="#{carol.user_id}"][checked])
             )

      assert has_element?(view, ~s([data-test="instance-audience"]), "Carol Elsewhere")
    end

    # The page's widening waits on its proof while the audience moves
    # elsewhere; once the proof lands, the confirmed request is sent again
    # with the audience it was decided against, which is no longer the
    # stored one: the owner's conflict, after which the record is
    # cancelled, the page holds no secret and nothing more is asked.
    defp prove_into_conflict!(view, ctx, ref) do
      watch_audience_writes()
      prove_asked!(view, ctx, ref)
      wait_until(fn -> record_state(ctx, ref) == "cancelled" end, 2_000, "the repeat let go")
      wait_until(fn -> render(view) =~ @page_conflict end, 2_000, "the page told the conflict")
      refute_received {:audience_written, _}, "the conflicting repeat wrote an audience"
      assert open_records(ctx) == [], "something was asked afresh"
      refute state_of(view) =~ "cnf_", "the page still holds the secret of a refused repeat"
      assert render(view) =~ @prompt_conflict
    end

    # A request the page asked for is proven once the page holds it and
    # its layer has heard of it (the update the page sent its layer is
    # handled before the render that follows): a proof the layer never
    # heard of is one it never repeats.
    defp prove_asked!(view, ctx, ref) do
      wait_until(
        fn -> state_of(view) =~ "confirmation-" <> ref end,
        2_000,
        "the page holds its request"
      )

      render(view)
      Sanctum.TestContext.prove!(ctx, ref)
    end

    test "a person another administrator lists while this page's widening waits on its proof " <>
           "stays listed: the proof's repeat is a conflict, and nothing is written",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      %{ctx: other} = admin!(build_conn())
      alice = test_user(%{name: "Alice First"})
      bob = test_user(%{name: "Bob Checked"})
      carol = test_user(%{name: "Carol Elsewhere"})
      entry = entry!(ctx, %{audience: "listed", members: [alice.user_id]})
      send(view.pid, :load)
      form = "#instance-audience-#{entry.id}"
      assert has_element?(view, form <> ~s( input[name="members[]"][value="#{bob.user_id}"]))

      # This administrator checks Bob in the form as drawn: a widening,
      # asked in the layer.
      view |> element(form) |> render_submit(%{"members" => [alice.user_id, bob.user_id]})
      assert [%{ref: ref, operation: "instance_entry.set_audience"}] = open_records(ctx)
      assert stored(entry.id).members == [alice.user_id]

      # Before the proof, another administrator lists Carol under their own
      # confirmation, and the announcement reaches this page.
      both = Enum.sort([alice.user_id, carol.user_id])

      args = %{
        entry_id: entry.id,
        audience: "listed",
        members: both,
        expected: %{audience: "listed", members: [alice.user_id]}
      }

      assert {:ok, :changed} =
               Sanctum.TestContext.confirming(
                 other,
                 &Sanctum.InstanceEntries.set_audience(&1, args)
               )

      wait_until(
        fn ->
          has_element?(view, form <> ~s( input[name="members_shown[]"][value="#{carol.user_id}"]))
        end,
        2_000,
        "the listing reached the page"
      )

      prove_into_conflict!(view, ctx, ref)

      assert Enum.sort(stored(entry.id).members) == both,
             "the proof's repeat wrote over the audience another administrator set while it waited"
    end

    test "the same, the other write made at the store and announced", %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      alice = test_user(%{name: "Alice First"})
      bob = test_user(%{name: "Bob Checked"})
      carol = test_user(%{name: "Carol Elsewhere"})
      entry = entry!(ctx, %{audience: "listed", members: [alice.user_id]})
      send(view.pid, :load)
      form = "#instance-audience-#{entry.id}"
      assert has_element?(view, form <> ~s( input[name="members[]"][value="#{bob.user_id}"]))

      view |> element(form) |> render_submit(%{"members" => [alice.user_id, bob.user_id]})
      assert [%{ref: ref, operation: "instance_entry.set_audience"}] = open_records(ctx)

      assert :ok =
               Arca.InstanceEntries.set_audience(
                 Prima.Actor.system(),
                 entry.id,
                 %{audience: "listed", members: [alice.user_id]},
                 %{audience: "listed", members: Enum.sort([alice.user_id, carol.user_id])}
               )

      send(view.pid, %Cyfr.Bus.InstanceEntryChanged{kind: :audience, entry_id: entry.id})
      render(view)

      prove_into_conflict!(view, ctx, ref)

      assert Enum.sort(stored(entry.id).members) ==
               Enum.sort([alice.user_id, carol.user_id]),
             "the proof's repeat wrote over the audience set at the store while it waited"
    end

    test "a person another administrator removes while this page's widening waits is not put " <>
           "back: the proof's repeat is a conflict, and nothing is written",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      %{ctx: other} = admin!(build_conn())
      alice = test_user(%{name: "Alice First"})
      bob = test_user(%{name: "Bob Checked"})
      dave = test_user(%{name: "Dave Removed"})

      entry =
        entry!(ctx, %{audience: "listed", members: Enum.sort([alice.user_id, dave.user_id])})

      send(view.pid, :load)
      form = "#instance-audience-#{entry.id}"

      view
      |> element(form)
      |> render_submit(%{"members" => [alice.user_id, dave.user_id, bob.user_id]})

      assert [%{ref: ref, operation: "instance_entry.set_audience"}] = open_records(ctx)

      # Another administrator removes Dave: a narrowing, the session alone.
      narrowed = %{
        entry_id: entry.id,
        audience: "listed",
        members: [alice.user_id],
        expected: %{audience: "listed", members: Enum.sort([alice.user_id, dave.user_id])}
      }

      assert {:ok, :changed} = Sanctum.InstanceEntries.set_audience(other, narrowed)

      prove_into_conflict!(view, ctx, ref)

      assert stored(entry.id).members == [alice.user_id],
             "this administrator's save wrote over Dave's removal by another administrator"
    end

    test "a removal from a list the audience left for everyone elsewhere is a conflict and " <>
           "saves nothing; a removal from an everyone form says it changes nothing",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      alice = test_user(%{name: "Alice First"})
      bob = test_user(%{name: "Bob Unchecked"})
      entry = entry!(ctx, %{audience: "listed", members: Enum.sort([alice.user_id, bob.user_id])})
      send(view.pid, :load)
      form = "#instance-audience-#{entry.id}"
      assert has_element?(view, form <> ~s( input[value="#{bob.user_id}"][checked]))

      # The audience becomes everyone at the store; this page has not heard.
      assert :ok =
               Arca.InstanceEntries.set_audience(
                 Prima.Actor.system(),
                 entry.id,
                 %{audience: "listed", members: Enum.sort([alice.user_id, bob.user_id])},
                 %{audience: "everyone", members: []}
               )

      view |> element(form) |> render_submit(%{"members" => [alice.user_id]})

      assert render(view) =~ @page_conflict
      assert %{audience: "everyone"} = stored(entry.id)
      assert has_element?(view, form <> ~s( input[name="audience"][value="everyone"][checked]))

      # A removal sent from a form drawn as everyone has no list to remove
      # from: nothing is sent, and the sentence says why.
      watch_saves()

      view
      |> element(form)
      |> render_submit(%{
        "audience" => "everyone",
        "audience_shown" => "everyone",
        "members_shown" => [bob.user_id],
        "members" => []
      })

      assert render(view) =~
               "The audience is everyone now, set elsewhere, so removing someone from its list " <>
                 "changes nothing."

      assert saves_admitted() == 0
      assert %{audience: "everyone"} = stored(entry.id)
    end

    test "a save with no edit sends nothing, so a write landing before the owner's read stands",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      alice = test_user(%{name: "Alice First"})
      carol = test_user(%{name: "Carol Elsewhere"})
      entry = entry!(ctx, %{audience: "listed", members: [alice.user_id]})
      send(view.pid, :load)
      form = "#instance-audience-#{entry.id}"

      assert has_element?(
               view,
               form <> ~s( input[name="members[]"][value="#{alice.user_id}"][checked])
             )

      # Another administrator's listing of Carol lands the moment an audience
      # save is admitted: after the page's read, before the owner's.
      test_pid = self()
      handler = "settings-unedited-save-#{System.unique_integer([:positive])}"
      {id, alice_id, carol_id} = {entry.id, alice.user_id, carol.user_id}

      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :grimoire, :decision, :admitted],
          fn _event, _measure, meta, _config ->
            if meta.tool == "instance_entry" and meta.action == "set_audience" do
              :ok =
                Arca.InstanceEntries.set_audience(
                  Prima.Actor.system(),
                  id,
                  %{audience: "listed", members: [alice_id]},
                  %{audience: "listed", members: Enum.sort([alice_id, carol_id])}
                )

              send(test_pid, :listed_elsewhere)
            end
          end,
          nil
        )

      try do
        view |> element(form) |> render_submit(%{"members" => [alice.user_id]})
      after
        :telemetry.detach(handler)
      end

      refute_received :listed_elsewhere, "an unedited save sent the audience it read"
      assert render(view) =~ "Nothing changed."
      assert stored(entry.id).members == [alice.user_id]
    end

    test "a widening whose audience moved while its prompt was open is a conflict at the " <>
           "repeat: record cancelled, no secret kept, the prompt says so, nothing written, " <>
           "the next save asked afresh",
         %{conn: conn} do
      %{view: view, ctx: ctx, ref: ref, a: a, b: b, entry: entry, form: form} =
        moot_repeat!(conn)

      wait_until(fn -> record_state(ctx, ref) == "cancelled" end, 2_000, "the record cancelled")

      refute state_of(view) =~ "cnf_",
             "the page still holds the secret of a change it will not make"

      # The prompt ends on the refusal, whichever of it and the record's
      # cancelled fact reached the layer first.
      render(view)
      html = render(view)
      refute html =~ "Approved. Completing the change."
      assert html =~ @prompt_conflict
      refute html =~ "Cancelled. Nothing was changed."
      refute html =~ "could not be withdrawn"
      assert html =~ @page_conflict

      # The card shows the audience stored elsewhere; the next save, made on
      # it, asks afresh under a record of its own and writes nothing yet.
      assert has_element?(view, form <> ~s( input[name="members_shown[]"][value="#{b}"]))
      c = test_user(%{name: "C Three"}).user_id
      send(view.pid, :load)
      view |> element(form) |> render_submit(%{"members" => [a, b, c]})

      assert [%{ref: again, operation: "instance_entry.set_audience"}] = open_records(ctx)
      refute again == ref
      assert Enum.sort(stored(entry.id).members) == Enum.sort([a, b])
      refute_received {:audience_written, _}
    end

    test "the same edit saved after a refused repeat is asked afresh, never written on its proof",
         %{conn: conn} do
      %{view: view, ctx: ctx, a: a, b: b, entry: entry, form: form, ref: ref} =
        moot_repeat!(conn)

      # B is removed elsewhere, and the page draws B unchecked again.
      assert :ok =
               Arca.InstanceEntries.set_audience(
                 Prima.Actor.system(),
                 entry.id,
                 %{audience: "listed", members: Enum.sort([a, b])},
                 %{audience: "listed", members: [a]}
               )

      send(view.pid, %Cyfr.Bus.InstanceEntryChanged{kind: :audience, entry_id: entry.id})

      wait_until(
        fn ->
          not has_element?(view, form <> ~s( input[name="members_shown[]"][value="#{b}"]))
        end,
        2_000,
        "B unchecked on the page"
      )

      view |> element(form) |> render_submit(%{"members" => [a, b]})

      refute b in stored(entry.id).members, "a widening was written with no prompt"
      assert [%{ref: again}] = open_records(ctx)
      refute again == ref
      wait_until(fn -> record_state(ctx, ref) == "cancelled" end, 2_000, "the record cancelled")
    end

    defp hide_confirmations!,
      do:
        Arca.Repo.query!("ALTER TABLE pending_confirmations RENAME TO pending_confirmations_gone")

    defp restore_confirmations!,
      do:
        Arca.Repo.query!("ALTER TABLE pending_confirmations_gone RENAME TO pending_confirmations")

    # A held widening proven while the page is held still, its repeat then
    # run with `break!` done first.
    defp proven_with!(view, ctx, ref, break!) do
      wait_until(fn -> state_of(view) =~ "confirmation-" <> ref end, 2_000, "the page holds it")
      render(view)
      :sys.suspend(view.pid)
      Sanctum.TestContext.prove!(ctx, ref)
      break!.()
      :sys.resume(view.pid)
    end

    test "a conflicting repeat whose cancel fails shows the conflict on the page, and in the " <>
           "prompt with the approval's expiry",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      a = test_user(%{name: "A One"}).user_id
      b = test_user(%{name: "B Two"}).user_id
      entry = entry!(ctx, %{audience: "listed", members: [a]})
      send(view.pid, :load)
      form = "#instance-audience-#{entry.id}"
      assert has_element?(view, form <> ~s( input[name="members[]"][value="#{b}"]))

      view |> element(form) |> render_submit(%{"members" => [a, b]})
      assert [%{ref: ref}] = open_records(ctx)

      assert :ok =
               Arca.InstanceEntries.set_audience(
                 Prima.Actor.system(),
                 entry.id,
                 %{audience: "listed", members: [a]},
                 %{audience: "listed", members: Enum.sort([a, b])}
               )

      send(view.pid, %Cyfr.Bus.InstanceEntryChanged{kind: :audience, entry_id: entry.id})
      watch_audience_writes()
      proven_with!(view, ctx, ref, &hide_confirmations!/0)

      wait_until(
        fn -> render(view) =~ "it ends at its expiry" end,
        3_000,
        "the failed cancel said"
      )

      html = render(view)
      holds = state_of(view) =~ "cnf_"
      restore_confirmations!()

      refute holds

      # The page's own answer is the conflict's; the prompt, where the
      # approval was given, shows the conflict and then the approval's fate.
      assert html =~ @page_conflict

      assert html =~
               @prompt_conflict <> " The approval could not be withdrawn; it ends at its expiry."

      refute html =~ "so the approval was withdrawn"
      refute_received {:audience_written, _}
      assert Enum.sort(stored(entry.id).members) == Enum.sort([a, b])
      assert record_state(ctx, ref) == "confirmed"
    end

    # A widening asked for whose proof lands before the page's layer hears
    # the ask: the record is proven inside the very event that opens it, and
    # the event goes on only once the stream's `confirmed` fact is already in
    # the page's mailbox, ahead of the ask the event then makes. With
    # `:no_panel` the stream's `opened` fact is taken out first, so the
    # `confirmed` fact meets no panel at all; with `:stream_panel` it meets
    # the panel the stream opened, not yet the page's. The handler tells the
    # test once that order holds: `:telemetry` swallows a handler's failure,
    # so a bound that ran out shows as the missing message, never as a pass.
    defp proven_before_the_ask!(view, ctx, mode) do
      view_pid = view.pid
      test_pid = self()
      handler = "settings-proof-first-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :sanctum, :confirmation, :opened],
          fn _event, _measure, meta, _config ->
            if self() == view_pid and meta.operation == "instance_entry.set_audience" do
              ref = meta.ref
              Sanctum.TestContext.prove!(ctx, ref)
              wait_until(fn -> queued_fact(ref, "opened") end, 2_000, "the opened fact queued")

              wait_until(
                fn -> queued_fact(ref, "confirmed") end,
                2_000,
                "the confirmed fact queued"
              )

              if mode == :no_panel, do: take!(queued_fact(ref, "opened"))
              send(test_pid, {:proven_before_the_ask, ref})
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      handler
    end

    defp queued_fact(ref, kind) do
      {:messages, messages} = Process.info(self(), :messages)

      Enum.find(messages, fn
        {:phoenix, :send_update, {_target, %{fact: %{"ref" => ^ref, "kind" => fact_kind}}}} ->
          to_string(fact_kind) == kind

        _other ->
          false
      end)
    end

    defp take!(message) do
      receive do
        ^message -> :ok
      after
        0 -> raise "the message left the mailbox"
      end
    end

    for {mode, where} <- [
          no_panel: "meets no panel",
          stream_panel: "meets the panel the stream opened"
        ] do
      test "a proof that lands before the layer hears the ask, whose fact #{where}, is " <>
             "repeated once, and the record is spent",
           %{conn: conn} do
        %{view: view, ctx: ctx} = admin!(conn)
        a = test_user(%{name: "A One"}).user_id
        b = test_user(%{name: "B Two"}).user_id
        entry = entry!(ctx, %{audience: "listed", members: [a]})
        send(view.pid, :load)
        form = "#instance-audience-#{entry.id}"
        watch_saves()
        handler = proven_before_the_ask!(view, ctx, unquote(mode))

        view |> element(form) |> render_submit(%{"members" => [a, b]})
        assert_receive {:proven_before_the_ask, ref}, 5_000
        :ok = :telemetry.detach(handler)

        wait_until(fn -> b in stored(entry.id).members end, 2_000, "the proven change made")
        assert record_state(ctx, ref) == "consumed"
        render(view)
        assert saves_admitted() == 2, "the change was not repeated exactly once"
        refute state_of(view) =~ "cnf_"
      end
    end

    test "a proof given after the layer heard the ask is still repeated exactly once",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      a = test_user(%{name: "A One"}).user_id
      b = test_user(%{name: "B Two"}).user_id
      entry = entry!(ctx, %{audience: "listed", members: [a]})
      send(view.pid, :load)
      form = "#instance-audience-#{entry.id}"
      watch_saves()

      view |> element(form) |> render_submit(%{"members" => [a, b]})
      assert [%{ref: ref}] = open_records(ctx)
      prove_asked!(view, ctx, ref)

      wait_until(fn -> b in stored(entry.id).members end, 2_000, "the proven change made")
      assert record_state(ctx, ref) == "consumed"
      render(view)
      assert saves_admitted() == 2, "the change was not repeated exactly once"
      refute state_of(view) =~ "cnf_"
    end

    test "a usage read that fails says use could not be read, not that there was none",
         %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      entry = entry!(ctx)
      send(view.pid, :load)
      use = ~s([data-test="instance-use-entry"][data-id="#{entry.id}"])
      assert has_element?(view, use, "No use in these days.")

      Arca.Repo.query!("ALTER TABLE instance_entry_usage RENAME TO usage_unavailable")
      send(view.pid, :load)

      assert has_element?(
               view,
               use <> ~s( [data-test="instance-use-unread"]),
               "could not be read"
             )

      refute has_element?(view, use, "No use in these days.")
    end

    test "Use shows each entry's requests by person and day", %{conn: conn} do
      %{view: view, ctx: ctx} = admin!(conn)
      entry = entry!(ctx)
      reader = test_user(%{name: "Rita Reader"})

      person =
        Sanctum.Context.build(
          user_id: reader.user_id,
          athanor_id: ctx.athanor_id,
          permissions: Sanctum.Context.person_permissions(),
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )

      request = %{uri: URI.parse("https://api.example.com/v1/models"), method: "GET"}
      facts = %{node_ref: "catalyst:local.any-model:1.0.0", activation_digest: "sha256:any"}

      for _ <- 1..2,
          do: {:ok, _, _} = Sanctum.InstanceEntries.resolve(person, entry.id, request, facts)

      send(view.pid, :load)
      today = Date.to_iso8601(DateTime.to_date(Arca.ServerMetaStorage.now!()))
      row = ~s([data-test="instance-use-entry"][data-id="#{entry.id}"] tr[data-day="#{today}"])

      assert has_element?(view, row, "Rita Reader 2")
      assert view |> element(row) |> render() =~ ~r/<td>\s*2\s*<\/td>/
    end
  end

  test "the mode preference is written to the person's row", %{conn: conn} do
    person = test_user()
    {view, _} = conn |> log_in_user(person) |> mount_athanor("/settings")

    view |> element("button[phx-click=set_mode][phx-value-mode=lite]") |> render_click()
    {:ok, user} = Sanctum.Tenancy.Users.get(person.user_id)
    assert Sanctum.Tenancy.Users.prefs(user)["mode"] == "lite"

    view |> element("button[phx-click=set_mode][phx-value-mode=dev]") |> render_click()
    {:ok, user} = Sanctum.Tenancy.Users.get(person.user_id)
    assert Sanctum.Tenancy.Users.prefs(user)["mode"] == "dev"
  end

  # ---------------------------------------------------------------------------
  # The person's identity, doors and passkeys
  # ---------------------------------------------------------------------------

  # A directory this home cannot reach: nothing here reads one.
  @directory "https://dir.example"

  defp keep_env(app, keys) do
    prior = Map.new(keys, &{&1, Application.fetch_env(app, &1)})

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)
  end

  defp layer(view), do: with_target(view, "#system-layer")

  defp held_secret(view) do
    state = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)
    [secret] = Regex.run(~r/cnf_[A-Za-z0-9_-]{43}/, state)
    secret
  end

  # The page's own request, proven here with the person's passkey over the
  # record's digest, as the layer asks.
  defp prove_here!(view, authenticator) do
    ref = Prima.Confirmation.ref(held_secret(view))
    view |> element(~s([data-test="confirm-passkey"][phx-value-ref="#{ref}"])) |> render_click()

    assert_push_event(view, "webauthn:get", %{
      purpose: "confirmation",
      id: ^ref,
      public_key: %{"challenge" => challenge}
    })

    {:ok, digest} = Prima.Identity.Encoding.unb64(challenge, 32)

    view
    |> layer()
    |> render_hook("webauthn_result", %{
      "purpose" => "confirmation",
      "id" => ref,
      "credential" => Authenticator.assertion(authenticator, digest)
    })
  end

  # The person's enrollment, accepted, as a retry records the directory's
  # acceptance: their kit is not saved yet.
  defp enrolled!(person) do
    begun = pending!(person)
    as = %Prima.Actor{user_id: person.user_id}
    {:ok, _} = Arca.IdentityAttempts.advance(as, begun.attempt_id, "submitted", "accepted")
    begun
  end

  # The person's enrollment, submitted with no answer recorded: it waits on
  # the seed of the browser that began it.
  defp pending!(person) do
    keys = Arca.Repo.get_by!(PersonIdentity, user_id: person.user_id)

    {:ok, operational} =
      Cipher.decrypt(
        keys.operational_key_sealed,
        CipherAAD.person_key(person.user_id, :operational)
      )

    {recovery, _} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Entry.genesis(
        live_key: keys.live_public_key,
        operational_key: keys.operational_public_key,
        recovery_keys: [recovery],
        directory: @directory
      )

    genesis = Identity.sign(genesis, operational)
    as = %Prima.Actor{user_id: person.user_id}

    {:ok, attempt} =
      Arca.IdentityAttempts.open(as, %{
        kind: "enrollment",
        request_id: "req_#{System.unique_integer([:positive])}",
        user_id: person.user_id,
        identifier: Identity.identifier(genesis),
        directory_url: @directory,
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(as, attempt.id, "staged", "submitted")
    %{attempt_id: attempt.id, identifier: Identity.identifier(genesis)}
  end

  # `person`, signed in, made a person whose keys are at another home:
  # their identity row is `remote`, their head cached as verified now, and
  # the conn holds a session of theirs bound to that head's `key_epoch`.
  defp remote!(conn, person) do
    conn = log_in_user(conn, person)
    Arca.Repo.delete_all(from(p in PersonIdentity, where: p.user_id == ^person.user_id))

    {live, _} = :crypto.generate_key(:eddsa, :ed25519)
    {operational_public, operational} = :crypto.generate_key(:eddsa, :ed25519)
    {recovery, _} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, genesis} =
      Entry.genesis(
        live_key: live,
        operational_key: operational_public,
        recovery_keys: [recovery],
        directory: @directory
      )

    genesis = Identity.sign(genesis, operational)
    identifier = Identity.identifier(genesis)
    head = Identity.hash(genesis)

    {:ok, _} =
      Arca.PersonIdentities.create(Prima.Actor.system(), %{
        user_id: person.user_id,
        provenance: "remote",
        identifier: identifier,
        directory_url: @directory
      })

    {:ok, _} =
      Arca.DirectoryHeads.put(Prima.Actor.system(), %{
        identifier: identifier,
        genesis: Identity.canonical(genesis),
        directory_url: @directory,
        head_hash: head,
        key_epoch: head,
        recovery_epoch: head,
        state: ~s({"head":"#{head}"})
      })

    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now()

    Arca.Repo.insert_all(Arca.Schemas.Session, [
      %{
        id: Prima.UUID7.generate_id("ses"),
        token_hash: Sanctum.Session.token_hash(token),
        token_prefix: String.slice(token, 0, 8),
        user_id: person.user_id,
        provider: "cyfr",
        athanor_id: Process.get(:prism_test_athanor_id),
        identity_key_epoch: head,
        expires_at: DateTime.add(now, 30 * 86_400, :second),
        inserted_at: now
      }
    ])

    {Plug.Test.init_test_session(conn, %{session_key() => token}), identifier}
  end

  describe "your identity" do
    setup do
      keep_env(:sanctum, [:directory_url])
      :ok
    end

    test "with no directory pinned, enrolling names the setting the operator owes, and the rest stands",
         %{conn: conn} do
      Application.delete_env(:sanctum, :directory_url)
      person = test_user()
      {view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      assert has_element?(view, ~s([data-test="identity"][data-provenance="local"]))
      assert has_element?(view, ~s([data-test="identity"][data-enrollment="none"]))
      assert has_element?(view, ~s([data-test="identity-no-directory"]), "CYFR_DIRECTORY_URL")
      refute has_element?(view, ~s([data-test="identity-enroll"]))
      assert html =~ "local pairing included"

      # The doors and passkeys stand without a directory.
      assert has_element?(view, ~s([data-test="door"][data-key="#{person.identity}"]))
      assert has_element?(view, ~s([data-test="passkey-register"]))
    end

    test "Enroll opens the enrollment prompt in the page's layer, naming the pinned directory",
         %{conn: conn} do
      Application.put_env(:sanctum, :directory_url, @directory)
      person = test_user()
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      assert has_element?(view, ~s([data-test="identity-directory"]), @directory)
      view |> element(~s([data-test="identity-enroll"])) |> render_click()
      render(view)

      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="enrollment"]))
      assert has_element?(view, ~s(#system-layer [data-test="recovery-directory"]), @directory)
      assert has_element?(view, ~s(#system-layer form[data-recovery="enrollment"]))
    end

    test "a kit not yet saved is offered again; another kit and the rotation are offered once enrolled",
         %{conn: conn} do
      Application.put_env(:sanctum, :directory_url, @directory)
      person = test_user()
      enrolled = enrolled!(person)
      {view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      assert has_element?(view, ~s([data-test="identity"][data-enrollment="enrolled"]))
      assert has_element?(view, ~s([data-test="identity-identifier"]), enrolled.identifier)
      refute html =~ "sealed-kit-seed"

      kit = ~s([data-test="identity-kit"][data-attempt="#{enrolled.attempt_id}"])
      assert has_element?(view, kit)

      view |> element(~s([data-test="identity-kit-show"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="kit"]))
      view |> element(~s([data-test="prompt-dismiss"])) |> render_click()

      view |> element(~s([data-test="identity-add-kit"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="holder"]))
      view |> element(~s([data-test="prompt-dismiss"])) |> render_click()

      # Rotating the live key asks for its fresh confirmation in the layer,
      # as this page's own request, and rotates nothing before it.
      view |> element(~s([data-test="identity-rotate"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))

      ctx = %{Sanctum.TestContext.local() | user_id: person.user_id}

      assert [%{action: "key_rotation", state: "pending"}] =
               Arca.Repo.all(
                 from(c in "pending_confirmations",
                   where: c.user_id == ^ctx.user_id,
                   select: %{action: c.action, state: c.state}
                 )
               )

      assert Arca.Repo.all(
               from(a in Arca.Schemas.IdentityAttempt,
                 where: a.user_id == ^person.user_id and a.kind == "rotation"
               )
             ) == []
    end

    test "an enrollment no prompt here holds is abandoned and begun again under a new kit",
         %{conn: conn} do
      Application.put_env(:sanctum, :directory_url, @directory)
      person = test_user()
      pending = pending!(person)
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      assert has_element?(view, ~s([data-test="identity"][data-enrollment="pending"]))
      refute has_element?(view, ~s([data-test="identity-enroll"]))

      # No confirmation is asked: it discards an unfinished attempt and
      # mints nothing.
      view |> element(~s([data-test="identity-abandon"])) |> render_click()
      render(view)

      assert %{phase: "superseded", kit_seed_sealed: nil} =
               Arca.Repo.get!(Arca.Schemas.IdentityAttempt, pending.attempt_id)

      assert Arca.Repo.all(
               from(c in "pending_confirmations",
                 where: c.user_id == ^person.user_id,
                 select: c.action
               )
             ) == []

      assert has_element?(view, ~s([data-test="identity"][data-enrollment="none"]))
      assert render(view) =~ "The unfinished enrollment was abandoned."

      # Begun again: the enrollment prompt is open in the layer, its seed
      # the browser's to draw.
      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="enrollment"]))
      assert has_element?(view, ~s(#system-layer form[data-recovery="enrollment"]))
    end

    test "no abandonment is offered while the page's own enrollment prompt holds its seed",
         %{conn: conn} do
      Application.put_env(:sanctum, :directory_url, @directory)
      person = test_user()
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      view |> element(~s([data-test="identity-enroll"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="recovery"][data-kind="enrollment"]))

      # The prompt's submission stands at the directory, unanswered, and
      # the page reads the identity again with the prompt still open.
      _pending = pending!(person)
      send(view.pid, :load)
      render(view)

      assert has_element?(view, ~s([data-test="identity"][data-enrollment="pending"]))
      refute has_element?(view, ~s([data-test="identity-abandon"]))

      # Dismissed, the prompt and the seed it held are gone.
      view |> element(~s([data-test="prompt-dismiss"])) |> render_click()
      render(view)
      assert has_element?(view, ~s([data-test="identity-abandon"]))
    end

    test "a person whose keys another home holds is told to change them there, and offered nothing",
         %{conn: conn} do
      Application.put_env(:sanctum, :directory_url, @directory)
      person = test_user()
      {conn, identifier} = remote!(conn, person)
      {view, _html} = mount_athanor(conn, "/settings")

      assert has_element?(view, ~s([data-test="identity"][data-provenance="remote"]))
      assert has_element?(view, ~s([data-test="identity-remote"]), "held at another home")
      assert has_element?(view, ~s([data-test="identity-identifier"]), identifier)

      for control <-
            ~w(identity-enroll identity-abandon identity-no-directory identity-kit identity-add-kit identity-rotate) do
        refute has_element?(view, ~s([data-test="#{control}"])), control
      end
    end
  end

  describe "sign-in doors" do
    test "the last door stays while the person holds no passkey here, said in its sentence",
         %{conn: conn} do
      person = test_user()
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      view |> element(~s([data-test="door-unlink"])) |> render_click()
      html = render(view)

      assert html =~ "hold no passkey"
      assert html =~ "link another door"
      assert {:ok, [_door]} = Arca.Users.identities(Prima.Actor.system(), person.user_id)
    end

    test "a GitHub door is linked through a device flow's ticket, under a fresh confirmation",
         %{conn: conn} do
      keep_env(:sanctum, [:device_flow, :github_client_id, :settings_link_identity])
      Application.put_env(:sanctum, :device_flow, PrismWeb.SettingsLiveTest.LinkFlow)
      Application.put_env(:sanctum, :github_client_id, "settings-test-client")

      person = test_user()
      authenticator = Sanctum.TestContext.passkey!(person.user_id)
      key = "github|https://github.com|linked-#{System.unique_integer([:positive])}"
      {:ok, _} = Sanctum.Door.Store.allow("user_id", key, "test")
      Application.put_env(:sanctum, :settings_link_identity, key)

      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")
      view |> element(~s([data-test="door-link-github"])) |> render_click()
      assert has_element?(view, ~s([data-test="door-link-code"]), "LINK-2026")

      # The provider authorized it: the poll answers a ticket, which the
      # page presents, and the link waits on its fresh confirmation.
      send(view.pid, :link_poll)
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))
      assert {:ok, [_one]} = Arca.Users.identities(Prima.Actor.system(), person.user_id)

      prove_here!(view, authenticator)

      wait_until(fn -> render(view) =~ "Linked github sign-in" end, 2_000, "the door linked")

      assert has_element?(view, ~s([data-test="door"][data-key="#{key}"]))
      assert {:ok, [_, _]} = Arca.Users.identities(Prima.Actor.system(), person.user_id)
    end

    test "an OpenID Connect door's ticket left in the session is presented as the page loads; a stale one says nothing",
         %{conn: conn} do
      person = test_user()
      authenticator = Sanctum.TestContext.passkey!(person.user_id)
      conn = log_in_user(conn, person)
      {:ok, ctx} = Sanctum.Caller.establish(get_session(conn, session_key()))

      key = "oidcc|https://issuer.example|sub-#{System.unique_integer([:positive])}"
      {:ok, _} = Sanctum.Door.Store.allow("user_id", key, "test")
      {:ok, ticket} = Sanctum.SignIn.link_ticket(ctx, %{key: key, provider: "oidcc", email: nil})

      linked =
        Plug.Test.init_test_session(conn, %{
          PrismWeb.AuthController.link_ticket_key() => %{
            "provider" => "oidcc",
            "ticket" => ticket
          }
        })

      {view, _html} = mount_athanor(linked, "/settings")
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))

      prove_here!(view, authenticator)

      wait_until(fn -> render(view) =~ "Linked oidcc sign-in" end, 2_000, "the door linked")

      assert has_element?(view, ~s([data-test="door"][data-key="#{key}"]))

      # Loaded again, the spent ticket the session still holds says nothing.
      {view, html} = mount_athanor(linked, "/settings")
      render(view)
      refute html =~ "Door:"
      refute render(view) =~ "Door:"
      refute has_element?(view, ~s(#system-layer [data-test="confirmation"]))
    end
  end

  describe "passkeys" do
    # The page's registration ceremony, answered by the person's software
    # authenticator and handed to the layer: answers the authenticator.
    defp ceremony!(view, person) do
      view |> element(~s([data-test="passkey-register"])) |> render_click()

      assert_push_event(view, "webauthn:create", %{
        layer: "system-layer",
        purpose: "passkey",
        public_key: public_key,
        registration: registration
      })

      authenticator = Authenticator.for_person(person.user_id)

      credential =
        Authenticator.registration(authenticator, %{
          public_key: public_key,
          registration: registration
        })

      view
      |> layer()
      |> render_hook("webauthn_result", %{"purpose" => "passkey", "credential" => credential})

      authenticator
    end

    test "one is registered through the layer's ceremony, then revoked under a fresh confirmation",
         %{conn: conn} do
      # No email, so no fresh method here: a first passkey, right after the
      # sign-in, needs no other proof.
      person = test_user(%{email: nil})
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")
      assert render(view) =~ "No passkey is registered here."

      authenticator = ceremony!(view, person)

      html = render(view)
      assert html =~ "Passkey registered."
      assert has_element?(view, ~s([data-test="passkey"][data-state="active"]))

      # Revoking it needs a fresh proof; the door the person keeps lets it go.
      view |> element(~s([data-test="passkey-revoke"])) |> render_click()
      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))
      assert has_element?(view, ~s([data-test="passkey"][data-state="active"]))

      prove_here!(view, authenticator)

      wait_until(fn -> render(view) =~ "Passkey revoked." end, 2_000, "the passkey revoked")

      refute has_element?(view, ~s([data-test="passkey"]))
    end

    test "a person with a verified email is asked by the layer to confirm their first passkey, and the code mailed to them registers it",
         %{conn: conn} do
      # A verified email the suite's transport reaches: a fresh method, so
      # a recent sign-in alone registers nothing.
      person = test_user()
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")
      ceremony!(view, person)

      render(view)
      assert has_element?(view, ~s(#system-layer [data-test="confirmation"][data-own="true"]))
      refute render(view) =~ "Passkey registered."
      refute has_element?(view, ~s([data-test="passkey"]))
      assert {:ok, %{passkeys: []}} = passkeys(person)

      view |> element(~s([data-test="confirm-email"])) |> render_click()
      assert_receive {:confirmation_code_mail, mail}, 2_000

      view
      |> form("#system-layer-code", %{"code" => Sanctum.TestContext.MailSink.code(mail)})
      |> render_submit()

      # Confirmed, the page makes the registration again under the record.
      wait_until(fn -> render(view) =~ "Passkey registered." end, 2_000, "the passkey registered")
      assert has_element?(view, ~s([data-test="passkey"][data-state="active"]))
    end

    test "a ceremony the browser did not finish registers nothing, and says so", %{conn: conn} do
      person = test_user()
      {view, _html} = conn |> log_in_user(person) |> mount_athanor("/settings")

      view |> element(~s([data-test="passkey-register"])) |> render_click()
      view |> layer() |> render_hook("webauthn_error", %{"purpose" => "passkey"})

      assert render(view) =~ "Nothing was registered."
      assert {:ok, %{passkeys: []}} = passkeys(person)
    end
  end

  defp passkeys(person) do
    ctx = %{
      Sanctum.TestContext.local()
      | user_id: person.user_id,
        auth_method: :oidc
    }

    case Sanctum.Passkeys.list(ctx) do
      {:ok, passkeys} -> {:ok, %{passkeys: passkeys}}
      other -> other
    end
  end
end
