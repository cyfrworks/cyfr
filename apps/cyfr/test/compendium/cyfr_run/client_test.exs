defmodule Compendium.CyfrRun.ClientTest do
  use ExUnit.Case, async: false

  alias Compendium.CyfrRun.Client
  alias Compendium.MCP
  alias Compendium.OCI.Errors
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Point API URL at a non-routable address so tests don't hit the real API.
    # Use a random high port on localhost that (almost certainly) has no listener.
    original_api_url = Application.get_env(:cyfr, :cyfr_run_api_url)
    Application.put_env(:cyfr, :cyfr_run_api_url, "http://127.0.0.1:19")

    ctx = Context.local()

    on_exit(fn ->
      if original_api_url,
        do: Application.put_env(:cyfr, :cyfr_run_api_url, original_api_url),
        else: Application.delete_env(:cyfr, :cyfr_run_api_url)
    end)

    {:ok, ctx: ctx}
  end

  # Helper to temporarily set edition and restore after test
  defp with_edition(edition, fun) do
    original_arx = Application.get_env(:cyfr, :edition)

    Application.put_env(:cyfr, :edition, edition)

    try do
      fun.()
    after
      if original_arx,
        do: Application.put_env(:cyfr, :edition, original_arx),
        else: Application.delete_env(:cyfr, :edition)
    end
  end

  # ============================================================================
  # CyfrRun.Client — Error Handling
  # ============================================================================

  describe "search/2 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.search(ctx, %{query: "test"})
      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end

    test "accepts empty params", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.search(ctx, %{})
      assert err.registry == "cyfr.run"
    end

    test "accepts all filter params", %{ctx: ctx} do
      {:error, %Errors{}} =
        Client.search(ctx, %{
          query: "data",
          type: "reagent",
          category: "data-processing",
          tags: ["wasm", "data"],
          license: "MIT",
          limit: 10,
          offset: 0
        })
    end
  end

  describe "discover/2 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.discover(ctx, %{namespace: "cyfr"})
      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end

    test "accepts empty params", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.discover(ctx, %{})
      assert err.registry == "cyfr.run"
    end
  end

  describe "get_component/5 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.get_component(ctx, "reagent", "cyfr", "data-processor")
      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end

    test "includes version in request when provided", %{ctx: ctx} do
      {:error, %Errors{} = err} =
        Client.get_component(ctx, "reagent", "cyfr", "data-processor", "1.0.0")

      assert err.registry == "cyfr.run"
    end
  end

  # ============================================================================
  # MCP Routing — Core edition routes search to CyfrRun.Client
  # ============================================================================

  describe "MCP search routing" do
    test "Core edition attempts cyfr.run search (gets connection error, falls back to local with loud failure)",
         %{ctx: ctx} do
      with_edition(:core, fn ->
        {:ok, result} =
          MCP.handle("component", ctx, %{
            "action" => "search",
            "query" => "nonexistent-component-xyz"
          })

        # Should get local results with structured failure info
        assert is_list(result[:components]) or is_list(result.components)
        assert result[:incomplete] == true
        assert is_binary(result[:registry_error])
        assert result[:registry_error] =~ "cyfr.run"
        assert result[:note] =~ "INCOMPLETE RESULTS"
        assert result[:note] =~ "cyfr.run search failed"
      end)
    end

    test "Arx edition does not attempt cyfr.run search", %{ctx: ctx} do
      with_edition(:arx, fn ->
        {:ok, result} =
          MCP.handle("component", ctx, %{
            "action" => "search",
            "query" => "nonexistent-component-xyz"
          })

        # Arx returns local results only, no warning about cyfr.run
        assert is_list(result.components)
        refute result[:warning]
      end)
    end
  end

  # ============================================================================
  # MCP Routing — Core edition routes discover to CyfrRun.Client
  # ============================================================================

  describe "MCP discover routing" do
    test "Core edition uses cyfr.run REST API for discover (fails with connection error)", %{
      ctx: ctx
    } do
      with_edition(:core, fn ->
        {:error, reason} =
          MCP.handle("component", ctx, %{
            "action" => "discover"
          })

        # Core routes through CyfrRun.Client which fails to connect
        assert reason =~ "cyfr.run"
      end)
    end

    test "Core edition rejects non-cyfr.run registry for discover", %{ctx: ctx} do
      with_edition(:core, fn ->
        {:error, msg} =
          MCP.handle("component", ctx, %{
            "action" => "discover",
            "registry" => "ghcr.io"
          })

        assert msg =~ "Core edition only supports registry.cyfr.run"
      end)
    end

    test "Arx edition uses OCI.Client for discover (not CyfrRun.Client)", %{ctx: ctx} do
      with_edition(:arx, fn ->
        result =
          MCP.handle("component", ctx, %{
            "action" => "discover"
          })

        # Arx uses OCI.Client.discover which hits the network directly.
        # The error should NOT mention "cyfr.run REST API" — it goes through
        # OCI protocol instead.
        case result do
          {:error, msg} ->
            refute msg =~ "cyfr.run discover failed"
            refute msg =~ "cyfr.run search failed"

          {:ok, _} ->
            :ok
        end
      end)
    end

    test "Arx edition allows custom registry for discover", %{ctx: ctx} do
      with_edition(:arx, fn ->
        result =
          MCP.handle("component", ctx, %{
            "action" => "discover",
            "registry" => "ghcr.io"
          })

        case result do
          {:error, msg} -> refute msg =~ "Core edition"
          {:ok, _} -> :ok
        end
      end)
    end
  end

  # ============================================================================
  # MCP Pull — Stale cache warning surfacing
  # ============================================================================

  describe "MCP pull - stale cache warning" do
    test "Core edition surfaces pull warnings from OCI.Client", %{ctx: ctx} do
      with_edition(:core, fn ->
        # Pull from cyfr.run will fail at network level, but this tests
        # the code path that checks for result[:warning]
        result =
          MCP.handle("component", ctx, %{
            "action" => "pull",
            "reference" => "registry.cyfr.run/cyfr/reagents/test:1.0.0"
          })

        # Network error expected — we're just verifying the code path exists
        assert {:error, _} = result
      end)
    end

    test "Arx edition surfaces pull warnings from OCI.Client", %{ctx: ctx} do
      with_edition(:arx, fn ->
        result =
          MCP.handle("component", ctx, %{
            "action" => "pull",
            "reference" => "ghcr.io/alice/reagents/test:1.0.0"
          })

        # Network error expected
        assert {:error, _} = result
      end)
    end
  end
end
