# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellPromptsTest do
  @moduledoc """
  The shell's prompts for the frames it opens: the credential verb, the
  devices control and the grant prompt.

  A frame's `credential` verb is honoured only for a live, visible frame
  whose version declares `vault.create`, and the frame learns only whether
  an entry was saved; the entry waits on its fresh confirmation, and the
  browser types the value again once its record is confirmed. The shell's
  `Devices` control opens the system layer's pairing prompt. A frame
  refused for want of a grant is offered the grant prompt, and opens once
  it is confirmed. While a Dashboard page covers the desktop, its layer
  draws none of these prompts and keeps each as it stands.

  The frames open as the layout places them: each tincture is a `full` app
  over one of two canvases, opened by its canvas's `open`, so a frame
  shown over one canvas is hidden once the other is shown.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Prism.Frames

  # Which canvas each tincture is a full app over.
  @placed %{
    "plain-dash" => "one",
    "blocked-dash" => "one",
    "keeper-dash" => "two",
    "radio-dash" => "two"
  }

  @canvases %{"one" => "markets", "two" => "notes-canvas"}

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "shell_prompts_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      reload_registry()
    end)

    for {_id, name} <- @canvases do
      canvas!(ctx, name)
      working!(ctx, name)
    end

    layout!(user, athanor)

    {:ok, conn: conn, user: user, athanor: athanor, ctx: ctx}
  end

  # A tincture version in the athanor's tree and its component row, with
  # `tincture` merged into its `tincture` block, granted as the person
  # would grant it (`Sanctum.Test.ConsentFixtures.grant_tincture!/3`).
  defp lay!(ctx, name, tincture, files) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => tincture
    }

    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", name, "1.0.0",
      manifest: manifest,
      files: files
    )

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        component_type: "tincture",
        description: name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|#{ctx.namespace}",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    acknowledged!(ctx)
    Sanctum.Test.ConsentFixtures.grant_tincture!(ctx, "tincture:local.#{name}")
    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
    release_digest
  end

  # The rows these fixtures write are the registry's, as a commit would
  # have written them: the root's projection is told it holds them after a
  # row is written and after a unit is laid, so a read derives nothing
  # over them from the units the fixtures commit.
  defp acknowledged!(ctx) do
    actor = Sanctum.Context.actor(ctx)
    {:ok, token} = Arca.StorageProjectionChanges.snapshot(actor, "components")

    {:ok, :acknowledged} =
      Arca.StorageProjectionChanges.replace(actor, "components", token, fn -> :acknowledged end)

    :ok
  end

  defp tincture!(ctx, name, tincture \\ %{}) do
    lay!(ctx, name, Map.merge(%{"entry" => "index.html"}, tincture), [
      {"index.html", "<html><head></head><body>#{name}</body></html>"}
    ])
  end

  defp canvas!(ctx, name) do
    lay!(
      ctx,
      name,
      %{
        "entry" => "index.html",
        "desktop" => %{}
      },
      [{"index.html", "<html><head></head><body>canvas</body></html>"}]
    )
  end

  # The canvas's working version, as its validation left it.
  defp working!(ctx, name) do
    {:ok, _} =
      Arca.CanvasVersions.publish(
        Sanctum.Context.actor(ctx),
        name,
        %{Arca.CanvasVersions.empty() | working: "1.0.0"},
        0
      )
  end

  # The person's layout: every tincture a minimised full app over the
  # canvas `@placed` names, in both postures, so the canvas opens it.
  defp layout!(user, athanor) do
    canvases =
      for {id, name} <- Enum.sort(@canvases) do
        apps =
          for {tincture, ^id} <- Enum.sort(@placed),
              do: %{
                "tincture" => "tincture:local.#{tincture}",
                "placement" => "full",
                "order" => 0,
                "minimised" => true
              }

        posture = %{"apps" => apps}

        %{
          "id" => id,
          "tincture" => "tincture:local.#{name}",
          "postures" => %{"desk" => posture, "hand" => posture}
        }
      end

    {:ok, _} =
      Compendium.Providers.Layout.handle("layout", person(user, athanor), %{
        "action" => "edit",
        "document" => %{"version" => 3, "canvases" => canvases},
        "revision" => 0
      })
  end

  # Type `secret` into the credential prompt, with the host it may go to,
  # have the person confirm the record it waits on (by its ref, as another
  # of their clients would), and type it again when the layer asks: the
  # browser's resubmission. `waiting` runs while the record waits for its
  # proof.
  defp enter_confirmed!(view, prompt_id, secret, ctx, waiting \\ fn -> :ok end) do
    typed = %{
      "prompt_id" => prompt_id,
      "secret" => secret,
      "destination_hosts" => "api.example.com"
    }

    view
    |> form("#system-layer-desktop-credential", typed)
    |> render_submit()

    assert {:ok, [%{ref: ref, operation: "vault.create"}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    wait_until(fn -> render(view) =~ ~s(data-ref="#{ref}") end, 2_000, "the waiting record")
    waiting.()

    Sanctum.TestContext.prove!(ctx, ref)

    assert_push_event(
      view,
      "system_layer:resubmit",
      %{form: "system-layer-desktop-credential"},
      2_000
    )

    view
    |> form("#system-layer-desktop-credential", typed)
    |> render_submit()
  end

  # The person's own context, as another of their sessions holds it.
  defp person(user, athanor) do
    Sanctum.Context.build(
      user_id: user.user_id,
      athanor_id: athanor.id,
      permissions: Sanctum.Context.person_permissions(),
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  defp shell!(conn) do
    {view, _html} = mount_desktop(conn)
    Process.put(:view, view)
    # The canvas's read and the shell's placing are messages to the view.
    wait_until(fn -> render(view) && assigns(view).showing == :canvas end, 2_000, "the canvas")
    view
  end

  defp assigns(%Phoenix.LiveViewTest.View{pid: pid}), do: :sys.get_state(pid).socket.assigns
  defp frames(view), do: assigns(view).frames
  defp dropped(view), do: Frames.dropped(frames(view))

  # The rows of the frames a test opens: every frame credential but the
  # canvases' own.
  defp rows do
    canvases = Map.values(@canvases)
    Arca.Repo.all(from(f in Arca.Schemas.FrameCredential, where: f.name not in ^canvases))
  end

  # Open `name` as the layout places it: its canvas shown, then the
  # canvas's `open`, unless its frame shows already. Answers the page.
  defp open!(view, name) do
    canvas_id = Map.fetch!(@placed, name)
    render_hook(view, "switch_canvas", %{"canvas" => canvas_id})

    case full(view, name) do
      %{visible: true} ->
        render(view)

      _not_shown ->
        canvas = Frames.get(frames(view), {:canvas, canvas_id})
        ref = "tincture:local.#{name}"

        render_hook(view, "frame_verb", %{
          "input" => System.unique_integer([:positive, :monotonic]),
          "frame" => canvas.id,
          "message" => Prima.TinctureWire.shell_message(:open, canvas.id, %{"ref" => ref})
        })
    end
  end

  defp full(view, name),
    do: Frames.get(frames(view), {:app, Map.fetch!(@placed, name), "tincture:local.#{name}"})

  defp verb!(view, frame_id, verb, args),
    do:
      render_hook(view, "frame_verb", %{
        "input" => System.unique_integer([:positive, :monotonic]),
        "frame" => frame_id,
        "message" => Prima.TinctureWire.shell_message(verb, frame_id, args)
      })

  describe "the credential verb" do
    setup %{ctx: ctx} do
      tincture!(ctx, "keeper-dash", %{"actions" => ["vault.create", "vault.list"]})
      tincture!(ctx, "plain-dash", %{"actions" => ["vault.list"]})
      :ok
    end

    test "from a frame that does not declare vault.create, a hidden frame or a frame this shell did not create, is dropped",
         %{conn: conn} do
      view = shell!(conn)
      open!(view, "plain-dash")
      plain = full(view, "plain-dash").id
      verb!(view, plain, :credential, %{"name" => "api"})
      assert dropped(view) == 1

      open!(view, "keeper-dash")
      keeper = full(view, "keeper-dash").id
      open!(view, "plain-dash")
      # keeper-dash is hidden now: a frozen frame attributes nothing.
      verb!(view, keeper, :credential, %{"name" => "api"})
      assert dropped(view) == 2

      verb!(view, "frm_not_this_shells", :credential, %{"name" => "api"})
      assert dropped(view) == 3

      assert assigns(view).credential_prompts == %{}
      refute render(view) =~ ~s(data-kind="credential_entry")
    end

    test "a hidden frame with a background grant is not asked for either", %{conn: conn, ctx: ctx} do
      tincture!(ctx, "radio-dash", %{
        "actions" => ["vault.create"],
        "frame" => %{"background" => true}
      })

      view = shell!(conn)
      open!(view, "radio-dash")
      radio = full(view, "radio-dash").id
      open!(view, "plain-dash")
      assert %{state: :live, visible: false} = full(view, "radio-dash")

      verb!(view, radio, :credential, %{"name" => "api"})
      assert dropped(view) == 1
      assert assigns(view).credential_prompts == %{}
    end

    test "dismissed, the frame is told only that nothing was saved", %{conn: conn} do
      view = shell!(conn)
      open!(view, "keeper-dash")
      keeper = full(view, "keeper-dash").id

      verb!(view, keeper, :credential, %{"name" => "weather-api"})
      html = render(view)
      assert html =~ ~s(data-kind="credential_entry")
      assert html =~ "weather-api"

      # One prompt per frame at a time.
      verb!(view, keeper, :credential, %{"name" => "another"})
      assert dropped(view) == 1

      view
      |> element(~s(#system-layer-desktop-dialog button[phx-click="dismiss"]))
      |> render_click()

      _ = render(view)

      assert_push_event(view, "frame_credential", payload)
      assert payload == %{frame: keeper, saved: false}
      assert assigns(view).credential_prompts == %{}
    end

    test "refused, the prompt stays open; closed, the frame is told saved: false and nothing else",
         %{conn: conn, user: user, athanor: athanor} do
      {:ok, _} =
        Sanctum.TestContext.create_vault(person(user, athanor), %{
          name: "taken",
          kind: "api_key",
          fields: %{"API_KEY" => "first"},
          destination: %{"hosts" => ["api.example.com"]}
        })

      view = shell!(conn)
      open!(view, "keeper-dash")
      keeper = full(view, "keeper-dash").id
      verb!(view, keeper, :credential, %{"name" => "taken"})
      [{prompt_id, ^keeper}] = Map.to_list(assigns(view).credential_prompts)

      # Confirmed, then typed again: the vault refuses the taken name.
      enter_confirmed!(view, prompt_id, "s3c0nd-v4lue", person(user, athanor))

      html = render(view)
      assert html =~ "Not done:"
      refute html =~ "s3c0nd-v4lue"
      refute_push_event(view, "frame_credential", _payload, 50)

      view
      |> element(~s(#system-layer-desktop-dialog button[phx-click="dismiss"]))
      |> render_click()

      _ = render(view)
      assert_push_event(view, "frame_credential", %{frame: ^keeper, saved: false} = payload)
      assert Map.keys(payload) |> Enum.sort() == [:frame, :saved]
    end

    # Entering a credential is a sensitive change: the entry waits on its
    # record, unsaved and unheard of by the frame, until the person
    # confirms it; the browser then types the value again and it is saved.
    test "confirmed, the entry is saved and the frame is told saved: true, never the value",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      open!(view, "keeper-dash")
      keeper = full(view, "keeper-dash").id
      verb!(view, keeper, :credential, %{"name" => "fresh-entry"})
      [{prompt_id, ^keeper}] = Map.to_list(assigns(view).credential_prompts)

      enter_confirmed!(view, prompt_id, "v4lue-typed", person(user, athanor), fn ->
        # Waiting on the record: nothing saved, the frame told nothing.
        html = render(view)
        assert html =~ ~s(data-status="waiting")
        refute html =~ "cnf_"
        refute html =~ "v4lue-typed"
        refute_push_event(view, "frame_credential", _payload, 50)
        assert {:ok, entries} = Sanctum.Vault.list(person(user, athanor))
        refute Enum.any?(entries, &(&1.name == "fresh-entry"))
      end)

      assert_push_event(view, "frame_credential", %{frame: ^keeper, saved: true} = payload, 2_000)
      refute inspect(payload) =~ "v4lue-typed"
      refute render(view) =~ "v4lue-typed"

      assert {:ok, entries} = Sanctum.Vault.list(person(user, athanor))
      assert Enum.any?(entries, &(&1.name == "fresh-entry"))
      Cyfr.Test.Sandbox.end_views()
    end
  end

  # The desktop and the desktop page, the credential prompt of a frame's
  # `credential` typed and submitted in the desktop's layer: its record
  # waits, drawn as the desktop's own and, by the page's layer, as another
  # client's request.
  defp waiting_in_both!(conn, ctx) do
    view = shell!(conn)
    {:ok, page, _html} = live(conn, "/")
    open!(view, "keeper-dash")
    keeper = full(view, "keeper-dash").id
    verb!(view, keeper, :credential, %{"name" => "both-#{System.unique_integer([:positive])}"})
    [{prompt_id, ^keeper}] = Map.to_list(assigns(view).credential_prompts)

    typed = %{
      "prompt_id" => prompt_id,
      "secret" => "b0th-value",
      "destination_hosts" => "api.example.com"
    }

    view |> form("#system-layer-desktop-credential", typed) |> render_submit()

    assert {:ok, [%{ref: ref}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    wait_until(
      fn -> render(view) =~ ~s(data-ref="#{ref}") end,
      2_000,
      "the desktop's own wait"
    )

    wait_until(
      fn -> page |> element("#system-layer") |> render() =~ ~s(data-ref="#{ref}") end,
      2_000,
      "the page's layer drawing the same record"
    )

    assert page |> element("#system-layer") |> render() =~ ~s(data-own="false")
    %{view: view, page: page, typed: typed, keeper: keeper, ref: ref}
  end

  # A record the desktop's own change waits on is drawn twice in the
  # document: in the desktop's prompt as its own, and by the page's layer as
  # another client's request (`PrismWeb.SystemLayer`, `shows_others?/1`).
  # Both follow the one record, so a decision in either clears both.
  describe "a record the desktop waits on, beside the page's layer" do
    setup %{ctx: ctx} do
      tincture!(ctx, "keeper-dash", %{"actions" => ["vault.create", "vault.list"]})
      :ok
    end

    test "a proof given for it ends the wait in both", %{conn: conn, user: user, athanor: athanor} do
      ctx = person(user, athanor)

      %{view: view, page: page, typed: typed, keeper: keeper, ref: ref} =
        waiting_in_both!(conn, ctx)

      Sanctum.TestContext.prove!(ctx, ref)

      assert_push_event(
        view,
        "system_layer:resubmit",
        %{form: "system-layer-desktop-credential"},
        2_000
      )

      view |> form("#system-layer-desktop-credential", typed) |> render_submit()
      assert_push_event(view, "frame_credential", %{frame: ^keeper, saved: true}, 2_000)

      wait_until(
        fn -> not (page |> element("#system-layer") |> render() =~ ~s(data-ref="#{ref}")) end,
        2_000,
        "the page's prompt gone once the record was consumed"
      )

      Cyfr.Test.Sandbox.end_views()
    end

    test "cancelled from the desktop's prompt, it ends in the page's too",
         %{conn: conn, user: user, athanor: athanor} do
      ctx = person(user, athanor)
      %{view: view, page: page, keeper: keeper, ref: ref} = waiting_in_both!(conn, ctx)

      view
      |> element(~s(#system-layer-desktop-dialog button[phx-click="dismiss"]))
      |> render_click()

      assert_push_event(view, "frame_credential", %{frame: ^keeper, saved: false}, 2_000)

      wait_until(
        fn -> not (page |> element("#system-layer") |> render() =~ ~s(data-ref="#{ref}")) end,
        2_000,
        "the page's prompt gone once the record was cancelled"
      )

      assert {:ok, []} =
               Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

      Cyfr.Test.Sandbox.end_views()
    end
  end

  describe "the devices control" do
    test "opens the pairing prompt, once, listing the person's paired devices", %{conn: conn} do
      view = shell!(conn)

      view |> element("#shell-devices") |> render_click()
      html = render(view)

      assert html =~ ~s(data-kind="pairing")
      assert has_element?(view, ~s([data-test="pairing-none"]))
      refute has_element?(view, ~s([data-test="pairing-begin"]))
      [prompt_id] = Regex.run(~r/data-prompt-id="(pairing-[^"]+)"/, html, capture: :all_but_first)

      # Asked again while it is open: the same prompt, and keys typed into
      # it move nothing behind it.
      view |> element("#shell-devices") |> render_click()
      refute render(view) =~ "waiting."
      assert assigns(view).pairing_prompt == prompt_id

      view
      |> element(~s(#system-layer-desktop-dialog button[phx-click="dismiss"]))
      |> render_click()

      _ = render(view)
      assert assigns(view).pairing_prompt == nil
      refute render(view) =~ ~s(data-kind="pairing")
    end
  end

  describe "the grant prompt" do
    # The tincture's one owner profile waits for the person to consent again.
    defp blocked!(ctx) do
      :ok =
        Sanctum.Test.ConsentFixtures.seed_head!(
          ctx,
          %{
            id: "prof_blocked_dash",
            kind: :owner,
            source_ref: "tincture:local.blocked-dash",
            label: "owner",
            status: :needs_consent
          },
          %{
            id: "cons_blocked_dash",
            revision: 1,
            scope: :versionless,
            pinned_version: "",
            invoke_mode: :open_inert,
            shape_digest: "sha256:shape",
            commit_digest: "sha256:commit",
            blob_digest: Prima.Digest.sha256("{}"),
            resolved_policy: "{}",
            activation: %{}
          }
        )
    end

    test "a frame refused for want of a grant is offered the grant prompt, and opens once it is confirmed",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "blocked-dash")
      blocked!(ctx)

      view = shell!(conn)
      html = open!(view, "blocked-dash")

      assert %{state: :refused, refusal: :ungranted} = full(view, "blocked-dash")

      assert html =~ ~s(data-tincture-state="ungranted")
      assert rows() == []

      html = render(view)
      assert html =~ ~s(data-kind="grant")
      assert html =~ "Grant tincture:local.blocked-dash"

      view
      |> element(~s(#system-layer-desktop-dialog button[phx-click="confirm"]))
      |> render_click()

      # The layer asks its sheet for the walk, commits, and reports.
      wait_until(fn -> assigns(view).grant_prompts == %{} end, 5_000, "the grant")

      assert %{state: :live} = full(view, "blocked-dash")
      assert assigns(view).grant_prompts == %{}
    end

    # A Dashboard page drawn over the desktop (`page_shown`, from the
    # desktop's hook): the prompt the desktop raised on its own waits
    # behind the page, so the desktop's layer stands modal over none of the
    # page's asks, and is drawn again once the desktop is shown.
    test "while a page is over the desktop, its grant prompt waits behind the page and is drawn again after",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "blocked-dash")
      blocked!(ctx)

      view = shell!(conn)
      open!(view, "blocked-dash")
      assert render(view) =~ ~s(data-kind="grant")

      render_hook(view, "page_shown", %{"desktop" => false})
      html = view |> element("#system-layer-desktop") |> render()
      refute html =~ ~s(data-kind="grant")
      refute html =~ ~s(data-open="true")
      assert map_size(assigns(view).grant_prompts) == 1

      # The page's own asks stand alone: the page's layer and form, with
      # nothing of the desktop's open over them.
      {:ok, page, _html} = live(conn, athanor_path("/settings"))
      assert has_element?(page, "#settings-overlay")
      refute page |> element("#system-layer") |> render() =~ ~s(data-open="true")

      render_hook(view, "page_shown", %{"desktop" => true})
      assert render(view) =~ ~s(data-kind="grant")

      view
      |> element(~s(#system-layer-desktop-dialog button[phx-click="confirm"]))
      |> render_click()

      wait_until(fn -> assigns(view).grant_prompts == %{} end, 5_000, "the grant")
      assert %{state: :live} = full(view, "blocked-dash")
    end

    test "a desktop that joins under a page draws none of its own prompts until it is shown",
         %{conn: conn, ctx: ctx} do
      tincture!(ctx, "blocked-dash")
      blocked!(ctx)

      conn =
        Phoenix.LiveViewTest.put_connect_params(conn, %{"_path" => athanor_path("/settings")})

      view = shell!(conn)
      open!(view, "blocked-dash")

      assert %{state: :refused, refusal: :ungranted} = full(view, "blocked-dash")
      refute render(view) =~ ~s(data-kind="grant")
      assert map_size(assigns(view).grant_prompts) == 1

      render_hook(view, "page_shown", %{"desktop" => true})
      assert render(view) =~ ~s(data-kind="grant")
    end

    test "dismissed, the frame keeps showing its refusal", %{conn: conn, ctx: ctx} do
      tincture!(ctx, "blocked-dash")
      blocked!(ctx)

      view = shell!(conn)
      open!(view, "blocked-dash")

      view
      |> element(~s(#system-layer-desktop-dialog button[phx-click="dismiss"]))
      |> render_click()

      assert %{state: :refused, refusal: :ungranted} = full(view, "blocked-dash")

      assert render(view) =~ "asks for what you have not granted it yet"
      assert rows() == []
    end
  end

  # A Dashboard page drawn over the desktop (`page_shown`, from the
  # desktop's hook) covers it: the desktop's layer draws none of its
  # prompts, whatever raised them, and keeps each as it stands, drawn again
  # once the desktop is shown. An app keeps running under the page, and its
  # bridge forwards a verb without the person's input.
  describe "a page over the desktop" do
    setup %{ctx: ctx} do
      tincture!(ctx, "keeper-dash", %{"actions" => ["vault.create", "vault.list"]})
      :ok
    end

    defp layer(view), do: view |> element("#system-layer-desktop") |> render()

    defp covered!(view) do
      render_hook(view, "page_shown", %{"desktop" => false})
      assert assigns(view).covered
    end

    test "a covered app cannot raise a credential modal over a Dashboard page", %{conn: conn} do
      view = shell!(conn)
      open!(view, "keeper-dash")
      keeper = full(view, "keeper-dash")
      assert keeper.visible
      covered!(view)
      assert %{state: :live, visible: true} = full(view, "keeper-dash")
      {:ok, page, _html} = live(conn, athanor_path("/settings"))
      assert has_element?(page, "#settings-overlay")

      render_hook(view, "frame_verb", %{
        "frame" => keeper.id,
        "message" =>
          Prima.TinctureWire.shell_message(:credential, keeper.id, %{"name" => "timer-key"})
      })

      _ = render(view)

      refute has_element?(view, ~s(#system-layer-desktop-dialog [data-kind="credential_entry"])),
             "a still-running app raised its own modal above Settings without input"

      refute layer(view) =~ ~s(data-open="true")
      Cyfr.Test.Sandbox.end_views()
    end

    test "the credential an app asks for under a page is drawn once the page closes, and the frame hears its answer",
         %{conn: conn, user: user, athanor: athanor} do
      view = shell!(conn)
      open!(view, "keeper-dash")
      keeper = full(view, "keeper-dash").id
      covered!(view)

      verb!(view, keeper, :credential, %{"name" => "under-page"})
      refute layer(view) =~ ~s(data-kind="credential_entry")
      [{prompt_id, ^keeper}] = Map.to_list(assigns(view).credential_prompts)

      render_hook(view, "page_shown", %{"desktop" => true})
      assert layer(view) =~ ~s(data-open="true")
      assert layer(view) =~ ~s(data-kind="credential_entry")
      assert layer(view) =~ "under-page"

      enter_confirmed!(view, prompt_id, "und3r-value", person(user, athanor))
      assert_push_event(view, "frame_credential", %{frame: ^keeper, saved: true}, 2_000)
      assert {:ok, entries} = Sanctum.Vault.list(person(user, athanor))
      assert Enum.any?(entries, &(&1.name == "under-page"))
      Cyfr.Test.Sandbox.end_views()
    end

    test "a credential entry waiting on its record keeps it under a page: confirmed meanwhile, it is drawn again and saves",
         %{conn: conn, user: user, athanor: athanor} do
      ctx = person(user, athanor)
      view = shell!(conn)
      open!(view, "keeper-dash")
      keeper = full(view, "keeper-dash").id
      verb!(view, keeper, :credential, %{"name" => "kept-wait"})
      [{prompt_id, ^keeper}] = Map.to_list(assigns(view).credential_prompts)

      typed = %{
        "prompt_id" => prompt_id,
        "secret" => "k3pt-value",
        "destination_hosts" => "api.example.com"
      }

      view |> form("#system-layer-desktop-credential", typed) |> render_submit()

      assert {:ok, [%{ref: ref}]} =
               Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

      wait_until(fn -> layer(view) =~ ~s(data-ref="#{ref}") end, 2_000, "the waiting record")

      covered!(view)
      refute layer(view) =~ ~s(data-ref="#{ref}")
      refute layer(view) =~ ~s(data-open="true")

      # Covered, the entry lets go of nothing: its record still waits.
      assert {:ok, [%{ref: ^ref}]} =
               Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

      # The person confirms it meanwhile, as another of their clients would.
      Sanctum.TestContext.prove!(ctx, ref)

      assert_push_event(
        view,
        "system_layer:resubmit",
        %{form: "system-layer-desktop-credential"},
        2_000
      )

      render_hook(view, "page_shown", %{"desktop" => true})
      assert layer(view) =~ ~s(data-open="true")
      assert layer(view) =~ ~s(data-ref="#{ref}")
      assert has_element?(view, "#system-layer-desktop-credential")

      # The value is typed again, the browser having cleared the closed
      # prompt's form, and the confirmed record saves it.
      view |> form("#system-layer-desktop-credential", typed) |> render_submit()
      assert_push_event(view, "frame_credential", %{frame: ^keeper, saved: true}, 2_000)
      assert {:ok, entries} = Sanctum.Vault.list(ctx)
      assert Enum.any?(entries, &(&1.name == "kept-wait"))
      Cyfr.Test.Sandbox.end_views()
    end
  end
end
