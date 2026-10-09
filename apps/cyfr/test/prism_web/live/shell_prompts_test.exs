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
  it is confirmed.

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

  defp reload_registry do
    registry = Process.whereis(Prism.TinctureRegistry)

    case Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo) do
      :ok ->
        try do
          Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), registry)
          :ok = Prism.TinctureRegistry.reload()
        after
          Ecto.Adapters.SQL.Sandbox.checkin(Arca.Repo)
        end

      {:already, _} ->
        Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), registry)
        :ok = Prism.TinctureRegistry.reload()
    end
  end

  # A tincture version in the athanor's tree and its component row, with
  # `tincture` merged into its `tincture` block.
  defp lay!(ctx, name, tincture, files) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => tincture
    }

    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.Context.actor(ctx),
        ["components", "tinctures", "local", name, "1.0.0"]
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    for {file, bytes} <- files, do: File.write!(Path.join(dir, file), bytes)

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

    Prism.TinctureRegistry.reload_athanor(ctx.athanor_id)
    release_digest
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
        "frame" => %{"placement" => "canvas"},
        "canvas" => %{"module" => "canvas.js", "toolkit" => 1},
        "streams" => []
      },
      [{"canvas.js", "export default (canvas) => canvas.render({type: \"spacer\"})"}]
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

  # The person's layout, version 2: every tincture a full app over the
  # canvas `@placed` names, in both postures.
  defp layout!(user, athanor) do
    canvases =
      for {id, name} <- Enum.sort(@canvases) do
        apps =
          for {tincture, ^id} <- Enum.sort(@placed),
              do: %{"tincture" => "tincture:local.#{tincture}", "mode" => "full", "order" => 0}

        posture = %{"apps" => apps, "floating" => []}

        %{
          "id" => id,
          "tincture" => "tincture:local.#{name}",
          "postures" => %{"desk" => posture, "hand" => posture}
        }
      end

    {:ok, _} =
      Compendium.Providers.Layout.handle("layout", person(user, athanor), %{
        "action" => "edit",
        "document" => %{"version" => 2, "canvases" => canvases},
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
    |> form("#system-layer-credential", typed)
    |> render_submit()

    assert {:ok, [%{ref: ref, operation: "vault.create"}]} =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)

    wait_until(fn -> render(view) =~ ~s(data-ref="#{ref}") end, 2_000, "the waiting record")
    waiting.()

    Sanctum.TestContext.prove!(ctx, ref)
    assert_push_event(view, "system_layer:resubmit", %{form: "system-layer-credential"}, 2_000)

    view
    |> form("#system-layer-credential", typed)
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
    {view, _html} = mount_athanor(conn, "/tinctures")
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

        render_hook(view, "canvas_verb", %{
          "frame" => canvas.id,
          "message" =>
            Prima.CanvasWire.encode(%{verb: :open, frame: canvas.id, args: %{"ref" => ref}})
        })
    end
  end

  defp full(view, name),
    do: Frames.get(frames(view), {:app, Map.fetch!(@placed, name), "tincture:local.#{name}"})

  defp verb!(view, frame_id, verb, args),
    do:
      render_hook(view, "frame_verb", %{
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

      view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()
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

      view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()
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

      assert_push_event(view, "frame_credential", %{frame: ^keeper, saved: true} = payload)
      refute inspect(payload) =~ "v4lue-typed"
      refute render(view) =~ "v4lue-typed"

      assert {:ok, entries} = Sanctum.Vault.list(person(user, athanor))
      assert Enum.any?(entries, &(&1.name == "fresh-entry"))
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
      assert has_element?(view, ~s([data-test="pairing-begin"]), "Pair a device")
      [prompt_id] = Regex.run(~r/data-prompt-id="(pairing-[^"]+)"/, html, capture: :all_but_first)

      # Asked again while it is open: the same prompt, and keys typed into
      # it move nothing behind it.
      view |> element("#shell-devices") |> render_click()
      refute render(view) =~ "waiting."
      assert assigns(view).pairing_prompt == prompt_id

      view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()
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
            blob_digest: Prima.JCS.hash_binary("{}"),
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

      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()

      # The layer asks its sheet for the walk, commits, and reports.
      wait_until(fn -> assigns(view).grant_prompts == %{} end, 5_000, "the grant")

      assert %{state: :live} = full(view, "blocked-dash")
      assert assigns(view).grant_prompts == %{}
    end

    test "dismissed, the frame keeps showing its refusal", %{conn: conn, ctx: ctx} do
      tincture!(ctx, "blocked-dash")
      blocked!(ctx)

      view = shell!(conn)
      open!(view, "blocked-dash")
      view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()

      assert %{state: :refused, refusal: :ungranted} = full(view, "blocked-dash")

      assert render(view) =~ "asks for what you have not granted it yet"
      assert rows() == []
    end
  end
end
