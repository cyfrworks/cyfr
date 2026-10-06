# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentsLiveTest do
  @moduledoc """
  Provenance in the Components page: a bundled copy wears its badge,
  offers Reset and no Remove (it isn't the athanor's to delete); Reset
  restores the shipped bytes over an edit; a newer shipped version is
  offered as Update and pulled in beside the copy. A consent whose head
  or profile row is damaged, or that the store cannot answer, is said as
  such and never offered a grant over a consent that exists. A setup plan
  the call is refused is said in the refusal's sentence, on the expand and
  on the refresh after a grant, in place of the plan, its badge and the
  grant.
  """

  use PrismWeb.ConnCase, async: false

  require Ecto.Query

  alias Sanctum.Test.ConsentFixtures

  @ref "reagent:local.shelf-tool"
  @profile "prof_shelf_tool"

  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  @version_dir ["components", "reagents", "local", "shelf-tool", "1.0.0"]

  setup %{conn: conn} do
    # A private seed tree shipping one component; the suite's shared seed
    # stays untouched.
    base = Path.join(System.tmp_dir!(), "components_live_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")
    shipped = Path.join([seed, "components", "reagents", "local", "shelf-tool", "1.0.0"])
    File.mkdir_p!(shipped)

    File.write!(
      Path.join(shipped, "cyfr-manifest.json"),
      Jason.encode!(%{"type" => "reagent", "version" => "1.0.0", "description" => "shipped"})
    )

    File.write!(Path.join(shipped, "reagent.wasm"), @valid_wasm)

    prev_seed = Application.fetch_env!(:arca, :seed_path)
    Application.put_env(:arca, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:arca, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    user = test_user()
    conn = log_in_user(conn, user)

    # Signing in copied the shipped version into the athanor the view
    # will mount; the scan mints its row.
    ctx =
      Sanctum.internal_context(
        user_id: "_test",
        athanor_id: seated_athanor().id,
        scope: :athanor
      )

    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)

    {:ok, conn: conn, ctx: ctx, seed: seed}
  end

  defp expanded_html(conn) do
    {view, _html} = mount_athanor(conn, "/components")
    render_click(view, "toggle_expand", %{"ref" => "reagent:local.shelf-tool"})
    {view, render(view)}
  end

  test "a bundled copy wears its badge, offers Reset and no Remove", %{conn: conn} do
    {_view, html} = expanded_html(conn)

    assert html =~ "shelf-tool"
    assert html =~ ~r/>\s*bundled\s*</
    assert html =~ "Reset reagent:local.shelf-tool:1.0.0 to the shipped version?"
    refute html =~ "Remove reagent:local.shelf-tool:1.0.0?"
  end

  test "Reset restores the shipped bytes over an edit", %{conn: conn, ctx: ctx} do
    :ok = Arca.put(Sanctum.Context.actor(ctx), @version_dir ++ ["notes.txt"], "edited")
    assert {:ok, true} = Arca.Overlay.edited?(Sanctum.Context.actor(ctx), @version_dir)

    {view, _html} = expanded_html(conn)
    render_click(view, "reset", %{"ref" => "reagent:local.shelf-tool:1.0.0"})

    # The edit is gone; the copy matches the shipped version again, and a
    # fresh mount agrees.
    refute Arca.exists?(Sanctum.Context.actor(ctx), @version_dir ++ ["notes.txt"])
    assert {:ok, false} = Arca.Overlay.edited?(Sanctum.Context.actor(ctx), @version_dir)

    {_view, html} = expanded_html(conn)
    assert html =~ ~r/>\s*bundled\s*</
  end

  test "a grant is asked in the page's system layer, not drawn on the page, and the plan is read again once granted",
       %{conn: conn, ctx: ctx} do
    {view, _html} = expanded_html(conn)

    view |> element("button[phx-click=open_consent]", "Grant access") |> render_click()
    html = render(view)

    assert html =~ ~s(data-kind="grant")
    assert html =~ "Grant reagent:local.shelf-tool:1.0.0"
    assert has_element?(view, ~s(#system-layer-dialog [data-test="grant-sheet"]))
    refute has_element?(view, "#consent-sheet-dialog")

    view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()

    # The layer asks its sheet for the walk, commits, and reports.
    Prima.Test.Wait.wait_until(
      fn -> :sys.get_state(view.pid).socket.assigns.grant_prompt == nil end,
      5_000,
      "the grant"
    )

    html = render(view)
    refute html =~ ~s(data-kind="grant")
    assert :sys.get_state(view.pid).socket.assigns.grant_prompt == nil
    assert {:ok, [_profile | _]} = Sanctum.Consent.profiles(ctx, "reagent:local.shelf-tool")
  end

  test "a grant asked here opens on the plan's suggestion, and a need the component reads " <>
         "itself links to the update this page offers",
       %{conn: conn, ctx: ctx} do
    manifest = fn version ->
      %{
        "name" => "shelf-model",
        "type" => "catalyst",
        "version" => version,
        "publisher" => "local",
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:shelf.example",
            "reason" => "to call the shelf's model",
            "fields" => ["SHELF_KEY"]
          }
        }
      }
    end

    # A shipped catalyst that reads its key itself, and a newer version
    # shipped since.
    {:ok, _} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, "catalyst", "local", "shelf-model", "1.0.0",
        manifest: manifest.("1.0.0"),
        wasm: @valid_wasm
      )

    Arca.Test.UnitFixtures.seed_component!("catalyst", "local", "shelf-model", "1.1.0",
      manifest: manifest.("1.1.0"),
      wasm: @valid_wasm
    )

    grant = fn ->
      {view, _html} = mount_athanor(conn, "/components")
      render_click(view, "toggle_expand", %{"ref" => "catalyst:local.shelf-model"})
      render(view)
      view |> element("button[phx-click=open_consent]", "Grant access") |> render_click()
      render(view)
      view
    end

    # No entry it may read: the sheet names the newer version, linking to
    # this page's entry for the component, where Update is.
    view = grant.()

    assert has_element?(
             view,
             ~s(#system-layer-dialog a[data-test="grant-update"]),
             "Update catalyst:local.shelf-model to 1.1.0"
           )

    [href] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(a[data-test="grant-update"]))
      |> LazyHTML.attribute("href")

    assert href =~ "/components?"

    assert URI.decode_query(URI.parse(href).query) == %{
             "ref" => "catalyst:local.shelf-model",
             "setup" => "true"
           }

    # An entry it may read: the grant opens with it bound.
    person = %{Sanctum.TestContext.local() | athanor_id: ctx.athanor_id}

    {:ok, entry} =
      Sanctum.TestContext.create_vault(person, %{
        name: "shelf key",
        kind: "api_key",
        provider_hint: "shelf.example",
        fields: %{"SHELF_KEY" => "sk-shelf"},
        destination: %{"hosts" => ["api.shelf.example"]},
        disclose: true
      })

    view = grant.()

    assert has_element?(
             view,
             ~s(#system-layer-dialog [data-test="grant-pick"][aria-pressed="true"]),
             entry.name
           )
  end

  test "a newer shipped version is offered as Update and pulled in beside the copy", %{
    conn: conn,
    ctx: ctx,
    seed: seed
  } do
    newer = Path.join([seed, "components", "reagents", "local", "shelf-tool", "1.1.0"])
    File.mkdir_p!(newer)

    File.write!(
      Path.join(newer, "cyfr-manifest.json"),
      Jason.encode!(%{"type" => "reagent", "version" => "1.1.0", "description" => "shipped"})
    )

    File.write!(Path.join(newer, "reagent.wasm"), @valid_wasm)

    {view, html} = expanded_html(conn)
    assert html =~ "Update to 1.1.0"
    refute html =~ "1.1.0</span>"

    render_click(view, "pull", %{"ref" => "reagent:local.shelf-tool:1.1.0"})

    # The copy lands, registered, and the page shows it as the latest
    # version with nothing left to update to.
    Prima.Test.Wait.wait_until(fn ->
      render(view) =~ "Pulled reagent:local.shelf-tool:1.1.0"
    end)

    html = render(view)
    refute html =~ "Update to"
    assert html =~ "1.1.0"

    newer_dir = ["components", "reagents", "local", "shelf-tool", "1.1.0"]
    assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), newer_dir) == {:ok, :shipped}
    assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), @version_dir) == {:ok, :shipped}

    assert {:ok, %{version: "1.1.0"}} =
             Compendium.Registry.get_latest(ctx, "shelf-tool", "local", "reagent")
  end

  describe "the consent section over a head it cannot read" do
    # A damaged head or profile row, or one the store cannot answer, is
    # said in the section's own sentence and offered no grant, which could
    # not repair it; a head never granted is still a grant to make.

    test "a damaged head is said in its own sentence, and no grant is offered over it",
         %{conn: conn, ctx: ctx} do
      grant_head!(ctx)
      :ok = ConsentFixtures.hand_edit_head!(ctx, @profile, scope: "sideways")

      {view, _html} = expanded_html(conn)

      assert has_element?(
               view,
               ~s([data-test="consent-unreadable"]),
               "this profile's consent is damaged and cannot be used — " <>
                 "revoke profile #{@profile} and grant it again"
             )

      refute render(view) =~ "Needs grant"
      refute has_element?(view, "button[phx-click=open_consent]", "Grant access")

      Cyfr.Test.Sandbox.end_views()
    end

    @tag :capture_log
    test "a head the store cannot answer is said in its own sentence, and no grant is offered",
         %{conn: conn, ctx: ctx} do
      grant_head!(ctx)
      {view, _html} = mount_athanor(conn, "/components")
      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")
      render_click(view, "toggle_expand", %{"ref" => @ref})

      assert has_element?(
               view,
               ~s([data-test="consent-unreadable"]),
               "this profile's consent cannot be read right now — try again"
             )

      refute render(view) =~ "Needs grant"
      refute has_element?(view, "button[phx-click=open_consent]", "Grant access")

      Cyfr.Test.Sandbox.end_views()
    end

    test "a profile row that does not decode is said in its own sentence, and no grant is offered",
         %{conn: conn, ctx: ctx} do
      :ok =
        ConsentFixtures.seed_profile!(ctx, %{
          id: @profile,
          source_ref: @ref,
          kind: :owner,
          label: "default",
          status: :active
        })

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(p in Arca.Schemas.Profile,
            where: p.athanor_id == ^ctx.athanor_id and p.id == @profile
          ),
          set: [kind: "sideways"]
        )

      {view, _html} = expanded_html(conn)

      assert has_element?(
               view,
               ~s([data-test="consent-unreadable"]),
               "this profile is damaged and cannot be used — " <>
                 "revoke profile #{@profile} and grant it again"
             )

      refute render(view) =~ "Needs grant"
      refute has_element?(view, "button[phx-click=open_consent]", "Grant access")

      Cyfr.Test.Sandbox.end_views()
    end

    @tag :capture_log
    test "a profile list the store cannot answer is said in its own sentence, and no grant is offered",
         %{conn: conn, ctx: ctx} do
      grant_head!(ctx)
      {view, _html} = mount_athanor(conn, "/components")
      Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")
      render_click(view, "toggle_expand", %{"ref" => @ref})

      assert has_element?(
               view,
               ~s([data-test="consent-unreadable"]),
               "this component's consent cannot be read right now — try again"
             )

      refute render(view) =~ "Needs grant"
      refute has_element?(view, "button[phx-click=open_consent]", "Grant access")

      Cyfr.Test.Sandbox.end_views()
    end

    test "a head never granted is still a grant to make", %{conn: conn, ctx: ctx} do
      :ok =
        ConsentFixtures.seed_profile!(ctx, %{
          id: @profile,
          source_ref: @ref,
          kind: :owner,
          label: "default",
          status: :active
        })

      {view, html} = expanded_html(conn)

      assert html =~ "Needs grant"
      assert has_element?(view, "button[phx-click=open_consent]", "Grant access")
      refute has_element?(view, ~s([data-test="consent-unreadable"]))

      Cyfr.Test.Sandbox.end_views()
    end
  end

  describe "a component whose lender is damaged" do
    # A borrower whose dependency's lending profile has a head whose bytes
    # fail their digest, or do not parse, is not ready; the grant the page
    # offers to ask is refused in the damage's own sentence, and no grant
    # sheet opens offering that lender again.
    @lend_dep "reagent:local.shelf-lend-dep"
    @borrower "reagent:local.shelf-borrower"

    test "a lender head failing its digest or not parsing is refused in its own sentence, " <>
           "and no grant sheet offers it",
         %{conn: conn, ctx: ctx} do
      person = %{Sanctum.TestContext.local() | athanor_id: ctx.athanor_id}

      ship_component!(ctx, "shelf-lend-dep", %{
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:example.com",
            "reason" => "to call the example API",
            "fields" => ["KEY"],
            "attach" => %{
              "in" => "header",
              "name" => "Authorization",
              "template" => "Bearer {value}"
            }
          }
        }
      })

      ship_component!(ctx, "shelf-borrower", %{
        "dependencies" => %{"static" => [%{"ref" => @lend_dep}]}
      })

      {:ok, entry} =
        Sanctum.TestContext.create_vault(person, %{
          name: "shelf-lend-key",
          kind: "api_key",
          provider_hint: "example.com",
          fields: %{"KEY" => "k"},
          destination: %{"hosts" => ["api.example.com"]}
        })

      walk!(person, %{ref: @lend_dep, bindings: [%{need: "api_key", entry_id: entry.id}]})
      walk!(person, %{ref: @borrower, selections: [%{dep: @lend_dep, label: "default"}]})
      {:ok, [%{id: lender}]} = Sanctum.Consent.profiles(person, @lend_dep)

      # Whole, the lender is offered.
      assert {:ok, %{dependency_needs: [%{candidates: [%{profile_id: ^lender}]}]}} =
               Sanctum.Consent.Plan.plan(person, %{ref: @borrower})

      refused =
        "Cannot ask for this grant: A profile that lends a key here is damaged and cannot " <>
          "lend its key — revoke profile #{lender} and grant it again."

      :ok =
        ConsentFixtures.hand_edit_head!(person, lender,
          blob_digest: "sha256:" <> String.duplicate("0", 64)
        )

      assert_grant_refused(conn, refused)

      :ok =
        ConsentFixtures.hand_edit_head!(person, lender,
          resolved_policy: "not a blob",
          blob_digest: Prima.JCS.hash_binary("not a blob")
        )

      assert_grant_refused(conn, refused)

      Cyfr.Test.Sandbox.end_views()
    end
  end

  describe "a component whose dependency is stored damaged" do
    # The page's setup plan reads the component's own manifest, so it
    # still offers to ask for the grant; the grant plan reads the closure,
    # finds the dependency's stored manifest damaged, and the sheet opens
    # naming that damage, with no rows and nothing to confirm. A commit
    # over it is refused too (`Sanctum.Consent.PlanTest`).
    @damaged_dep "reagent:local.shelf-damaged-dep"
    @damaged_app "reagent:local.shelf-damaged-app"

    test "the grant opens naming the damaged dependency, with nothing to confirm",
         %{conn: conn, ctx: ctx} do
      ship_component!(ctx, "shelf-damaged-dep", %{
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:example.com",
            "reason" => "to call the example API",
            "fields" => ["KEY"],
            "attach" => %{
              "in" => "header",
              "name" => "Authorization",
              "template" => "Bearer {value}"
            }
          }
        }
      })

      ship_component!(ctx, "shelf-damaged-app", %{
        "dependencies" => %{"static" => [%{"ref" => @damaged_dep}]}
      })

      Arca.Repo.query!(
        "UPDATE components SET manifest = '{not json' WHERE name = 'shelf-damaged-dep'"
      )

      Arca.Cache.delete_match(:_)

      {view, _html} = mount_athanor(conn, "/components")
      render_click(view, "toggle_expand", %{"ref" => @damaged_app})
      view |> element("button[phx-click=open_consent]", "Grant access") |> render_click()
      render(view)

      assert has_element?(
               view,
               ~s(#system-layer-dialog [data-test="grant-unresolved"]),
               "The dependency #{@damaged_dep} is stored damaged and cannot be granted."
             )

      refute has_element?(view, ~s(#system-layer-dialog [data-test="grant-rows"]))
      assert has_element?(view, ~s(#system-layer-dialog [data-test="prompt-confirm"][disabled]))
      assert {:ok, []} = Sanctum.Consent.profiles(ctx, @damaged_app)

      Cyfr.Test.Sandbox.end_views()
    end
  end

  # The borrower expanded: not ready, and the grant it offers to ask is
  # refused in `refused`, with no grant sheet.
  defp assert_grant_refused(conn, refused) do
    {view, _html} = mount_athanor(conn, "/components")
    render_click(view, "toggle_expand", %{"ref" => @borrower})
    assert render(view) =~ "Needs grant"

    view |> element("button[phx-click=open_consent]", "Grant access") |> render_click()

    assert render(view) =~ refused
    refute has_element?(view, ~s(#system-layer-dialog [data-test="grant-sheet"]))
  end

  defp ship_component!(ctx, name, manifest) do
    {:ok, _} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, "reagent", "local", name, "1.0.0",
        manifest:
          Map.merge(manifest, %{
            "name" => name,
            "type" => "reagent",
            "version" => "1.0.0",
            "publisher" => "local"
          }),
        wasm: @valid_wasm
      )
  end

  # The consent walk a person makes: plan, preview, commit.
  defp walk!(ctx, decisions) do
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: decisions.ref})
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _committed} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })
  end

  describe "a setup plan the call is refused" do
    # A refused `setup_plan` call is said in its own sentence where the
    # plan, its badge and the grant would be, on the expand and on the
    # refresh after a grant alike: never as a component with no plan, and
    # never as the plan read before the grant.

    @tag :capture_log
    test "on expand, the refusal is said in place of the plan, its badge and the grant",
         %{conn: conn, ctx: ctx} do
      seed_headless_profile!(ctx)
      {view, _html} = mount_athanor(conn, "/components")
      refuse_next_setup_plan!(view)
      render_click(view, "toggle_expand", %{"ref" => @ref})

      # The expand's other read answered: the row is open on its versions.
      assert render(view) =~ "Reset reagent:local.shelf-tool:1.0.0 to the shipped version?"
      assert_plan_refused(view)

      Cyfr.Test.Sandbox.end_views()
    end

    @tag :capture_log
    test "on the refresh after a grant, the refusal is said in place of the plan read before it",
         %{conn: conn, ctx: ctx} do
      seed_headless_profile!(ctx)
      {view, html} = expanded_html(conn)

      assert html =~ "Needs grant"
      refute has_element?(view, ~s([data-test="setup-plan-refused"]))

      view |> element("button[phx-click=open_consent]", "Grant access") |> render_click()
      refuse_next_setup_plan!(view)
      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()

      Prima.Test.Wait.wait_until(
        fn -> :sys.get_state(view.pid).socket.assigns.grant_prompt == nil end,
        5_000,
        "the grant"
      )

      # The grant was made; the plan that said it was needed is gone.
      assert {:ok, %{revision: 1}} = Sanctum.Consent.head_consent(ctx, @profile)
      assert_plan_refused(view)

      Cyfr.Test.Sandbox.end_views()
    end
  end

  # What the person reads where the consent section's plan would be: the
  # refusal's sentence, and neither a badge, a grant nor the sentence for
  # a component with no plan.
  defp assert_plan_refused(view) do
    assert has_element?(
             view,
             ~s([data-test="setup-plan-refused"]),
             "Failed to resolve component reagent:local.shelf-tool:1.0.0: " <>
               "The store could not answer — retry shortly"
           )

    html = render(view)
    refute html =~ "Needs grant"
    refute html =~ ~r/>\s*Ready\s*</
    refute html =~ "No setup plan available for this component."
    refute has_element?(view, "button[phx-click=open_consent]", "Grant access")
  end

  # The next `setup_plan` call `view` makes is refused as a store that
  # cannot answer refuses it: once the gate has admitted that call, and
  # before its handler reads the component, the registry's table is
  # renamed in the test's sandbox. The view's reads before it, the
  # expand's inspect among them, answer as they would.
  defp refuse_next_setup_plan!(view) do
    pid = view.pid
    handler = "components-live-refused-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :grimoire, :decision, :admitted],
        fn _event, _measurements, meta, _config ->
          if self() == pid and meta[:tool] == "component" and meta[:action] == "setup_plan" do
            :telemetry.detach(handler)
            Arca.Repo.query!("ALTER TABLE components RENAME TO components_unavailable")
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # The shelf tool's owner profile with no head: a grant to make.
  defp seed_headless_profile!(ctx) do
    :ok =
      ConsentFixtures.seed_profile!(ctx, %{
        id: @profile,
        source_ref: @ref,
        kind: :owner,
        label: "default",
        status: :active
      })
  end

  # The shelf tool's owner profile with a head, as a commit leaves it.
  defp grant_head!(ctx) do
    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{id: @profile, source_ref: @ref, kind: :owner, label: "default", status: :active},
        %{
          id: "cons_shelf_tool",
          revision: 1,
          scope: :versionless,
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          resolved_policy: "{}",
          activation: %{@ref => "sha256:act"},
          vault_refs: []
        }
      )
  end
end
