# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ShellLiveTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for ShellLive's picker navigation logic. The frames it creates,
  their attributes, credentials and shell verbs are
  `PrismWeb.ShellFrameTest`'s.
  """

  describe "tincture selection" do
    test "initial state has no active tincture" do
      state = initial_state()

      assert state.active_tincture == nil
      assert state.opened_tinctures == []
    end

    test "selecting a tincture sets it as active and tracks it as opened" do
      state =
        initial_state()
        |> select_tincture("iframe_stock-dashboard")

      assert state.active_tincture == "iframe_stock-dashboard"
      assert state.opened_tinctures == ["iframe_stock-dashboard"]
    end

    test "selecting the same tincture twice does not duplicate in opened list" do
      state =
        initial_state()
        |> select_tincture("iframe_stock-dashboard")
        |> select_tincture("iframe_stock-dashboard")

      assert state.active_tincture == "iframe_stock-dashboard"
      assert state.opened_tinctures == ["iframe_stock-dashboard"]
    end

    test "selecting multiple tinctures tracks all as opened" do
      state =
        initial_state()
        |> select_tincture("iframe_stock-dashboard")
        |> select_tincture("iframe_weather")

      assert state.active_tincture == "iframe_weather"
      assert state.opened_tinctures == ["iframe_stock-dashboard", "iframe_weather"]
    end

    test "selecting an unknown tincture is ignored" do
      state =
        initial_state()
        |> select_tincture("iframe_nonexistent")

      assert state.active_tincture == nil
      assert state.opened_tinctures == []
    end
  end

  describe "tincture iframe URLs" do
    test "entry URL uses the canonical athanor-scoped route" do
      url = Prima.TinctureUrl.path("home", "local", "stock-dashboard")

      # Must use the index route (not asset route) for CSP headers
      assert url == "/t/home/local/stock-dashboard"
      refute String.contains?(url, "index.html")
    end
  end

  # -- Test helpers that mirror ShellLive logic --

  defp initial_state do
    %{
      active_tincture: nil,
      opened_tinctures: [],
      tinctures: [
        %{
          id: "iframe_stock-dashboard",
          name: "stock-dashboard",
          publisher: "local",
          title: "Stock Dashboard",
          icon: "chart-line",
          url: "/t/home/local/stock-dashboard"
        },
        %{
          id: "iframe_weather",
          name: "weather",
          publisher: "local",
          title: "Weather",
          icon: "cloud",
          url: "/t/home/local/weather"
        }
      ]
    }
  end

  defp select_tincture(state, tincture_id) do
    if Enum.any?(state.tinctures, &(&1.id == tincture_id)) do
      state
      |> Map.put(:active_tincture, tincture_id)
      |> maybe_track_tincture(tincture_id)
    else
      state
    end
  end

  defp maybe_track_tincture(state, tincture_id) do
    if tincture_id in state.opened_tinctures do
      state
    else
      Map.put(state, :opened_tinctures, state.opened_tinctures ++ [tincture_id])
    end
  end
end

defmodule PrismWeb.ShellLiveTest.GrantTest do
  @moduledoc """
  A frame refused for want of a grant is offered the grant prompt
  (`offer_grant`), which opens on the plan's suggestion for each required
  need: the entry is bound before the person does anything, and that is
  what the grant commits.
  """

  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | athanor_id: athanor.id}

    base = Path.join(System.tmp_dir!(), "shell_grant_#{System.unique_integer([:positive])}")
    original_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, original_path)
      File.rm_rf(base)
      reload_registry()
    end)

    {:ok, conn: conn, ctx: ctx}
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

  # A tincture version in the athanor's tree and its component row,
  # declaring `needs`.
  defp tincture!(ctx, name, needs) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html"},
      "needs" => needs
    }

    dir =
      Arca.Adapters.Local.build_path(
        Sanctum.Context.actor(ctx),
        ["components", "tinctures", "local", name, "1.0.0"]
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "index.html"), "<html><head></head><body>#{name}</body></html>")

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
  end

  # The tincture's one owner profile waits for the person to consent again.
  defp blocked!(ctx, name) do
    :ok =
      Sanctum.Test.ConsentFixtures.seed_head!(
        ctx,
        %{
          id: "prof_#{name}",
          kind: :owner,
          source_ref: "tincture:local.#{name}",
          label: "owner",
          status: :needs_consent
        },
        %{
          id: "cons_#{name}",
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

  defp assigns(%Phoenix.LiveViewTest.View{pid: pid}), do: :sys.get_state(pid).socket.assigns

  # The shell, once the canvas has read the layout and placed the desktop.
  defp shell!(conn) do
    {view, _html} = mount_athanor(conn, "/tinctures")
    wait_until(fn -> render(view) && assigns(view).desktop != :pending end, 2_000, "the desktop")
    view
  end

  test "the grant a refused frame is offered opens on the plan's suggestion, bound, and " <>
         "commits it",
       %{conn: conn, ctx: ctx} do
    name = "keyed-dash"

    tincture!(ctx, name, %{
      "api_key" => %{
        "type" => "api_key:dash.test",
        "reason" => "to read the dashboard's feed with your key",
        "fields" => ["DASH_KEY"]
      }
    })

    blocked!(ctx, name)

    # The component reads its key itself, so the entry is disclosed.
    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "dash key #{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: "dash.test",
        fields: %{"DASH_KEY" => "sk-dash"},
        destination: %{"hosts" => ["api.dash.example"]},
        disclose: true
      })

    view = shell!(conn)
    render_click(view, "select_tincture", %{"tincture" => "iframe_#{name}"})
    html = render(view)

    assert html =~ ~s(data-kind="grant")

    assert has_element?(
             view,
             ~s(#system-layer-dialog [data-test="grant-pick"][aria-pressed="true"]),
             entry.name
           )

    view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
    wait_until(fn -> assigns(view).grant_prompts == %{} end, 5_000, "the grant")

    {:ok, [%{id: profile_id} | _]} = Sanctum.Consent.profiles(ctx, "tincture:local.#{name}")
    {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)
    assert Enum.any?(head.vault_refs, &(&1.vault_entry_id == entry.id))
  end
end
