defmodule Sanctum.AuditTest do
  use ExUnit.Case, async: false

  alias Sanctum.Audit
  alias Sanctum.Context

  setup do
    # Use a temp directory for tests
    test_dir = Path.join(System.tmp_dir!(), "cyfr_audit_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)

    # Set the base path for tests
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_dir)

    # Checkout the Ecto sandbox to isolate SQLite data between tests
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    on_exit(fn ->
      File.rm_rf!(test_dir)
      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    ctx = %Context{
      user_id: "test_user",
      org_id: nil,
      permissions: MapSet.new([:*]),
      scope: :personal,
      auth_method: :local,
      request_id: "req_123",
      session_id: "sess_456"
    }

    {:ok, test_dir: test_dir, ctx: ctx}
  end

  describe "log/3" do
    test "logs an execution event", %{ctx: ctx} do
      assert :ok = Audit.log(ctx, "execution", %{component: "stripe-catalyst", duration_ms: 150})
    end

    test "logs an auth event", %{ctx: ctx} do
      assert :ok = Audit.log(ctx, "auth", %{action: "login", provider: "github"})
    end

    test "logs a policy event", %{ctx: ctx} do
      assert :ok = Audit.log(ctx, "policy", %{component: "test", allowed: true})
    end

    test "logs a secret_access event", %{ctx: ctx} do
      assert :ok = Audit.log(ctx, "secret_access", %{secret_name: "API_KEY", action: "read"})
    end
  end

  describe "list/2" do
    test "returns empty list when no events exist", %{ctx: ctx} do
      {:ok, events} = Audit.list(ctx)
      assert events == []
    end

    test "returns logged events", %{ctx: ctx} do
      Audit.log(ctx, "execution", %{component: "test-component"})
      Audit.log(ctx, "auth", %{action: "login"})

      {:ok, events} = Audit.list(ctx)

      assert length(events) >= 2
      event_types = Enum.map(events, & &1["event_type"])
      assert "execution" in event_types
      assert "auth" in event_types
    end

    test "includes timestamp in events", %{ctx: ctx} do
      Audit.log(ctx, "execution", %{test: true})

      {:ok, [event | _]} = Audit.list(ctx)

      assert event["timestamp"] != nil
      assert {:ok, _, _} = DateTime.from_iso8601(event["timestamp"])
    end

    test "includes context information", %{ctx: ctx} do
      Audit.log(ctx, "execution", %{test: true})

      {:ok, [event | _]} = Audit.list(ctx)

      assert event["user_id"] == "test_user"
      assert event["request_id"] == "req_123"
      assert event["session_id"] == "sess_456"
    end
  end

  describe "list/2 filtering" do
    setup %{ctx: ctx} do
      # Log some events
      Audit.log(ctx, "execution", %{component: "comp1"})
      Audit.log(ctx, "auth", %{action: "login"})
      Audit.log(ctx, "execution", %{component: "comp2"})
      Audit.log(ctx, "policy", %{allowed: true})

      :ok
    end

    test "filters by event_type", %{ctx: ctx} do
      {:ok, events} = Audit.list(ctx, %{event_type: "execution"})

      assert length(events) == 2
      assert Enum.all?(events, &(&1["event_type"] == "execution"))
    end

    test "filters by event_type (string key)", %{ctx: ctx} do
      {:ok, events} = Audit.list(ctx, %{"event_type" => "auth"})

      assert length(events) == 1
      assert hd(events)["event_type"] == "auth"
    end

    test "applies limit", %{ctx: ctx} do
      {:ok, events} = Audit.list(ctx, %{limit: 2})

      assert length(events) == 2
    end

    test "applies offset", %{ctx: ctx} do
      {:ok, all_events} = Audit.list(ctx, %{limit: 100})
      {:ok, offset_events} = Audit.list(ctx, %{offset: 1, limit: 100})

      assert length(offset_events) == length(all_events) - 1
    end

    test "returns events in descending timestamp order", %{ctx: ctx} do
      {:ok, events} = Audit.list(ctx, %{limit: 100})

      timestamps = Enum.map(events, & &1["timestamp"])
      assert timestamps == Enum.sort(timestamps, :desc)
    end
  end

  describe "list/2 date filtering" do
    test "filters by start_date", %{ctx: ctx} do
      Audit.log(ctx, "execution", %{test: true})

      # Filter from today - should include events
      today = Date.utc_today() |> Date.to_iso8601()
      {:ok, events} = Audit.list(ctx, %{start_date: today})

      assert length(events) >= 1
    end

    test "filters by end_date", %{ctx: ctx} do
      Audit.log(ctx, "execution", %{test: true})

      # Filter to today - should include events
      today = Date.utc_today() |> Date.to_iso8601()
      {:ok, events} = Audit.list(ctx, %{end_date: today})

      assert length(events) >= 1
    end

    test "filters by date range", %{ctx: ctx} do
      Audit.log(ctx, "execution", %{test: true})

      today = Date.utc_today() |> Date.to_iso8601()
      {:ok, events} = Audit.list(ctx, %{start_date: today, end_date: today})

      assert length(events) >= 1
    end

    test "returns empty for future date range", %{ctx: ctx} do
      Audit.log(ctx, "execution", %{test: true})

      future = Date.utc_today() |> Date.add(30) |> Date.to_iso8601()
      {:ok, events} = Audit.list(ctx, %{start_date: future})

      assert events == []
    end
  end

  describe "export/2" do
    setup %{ctx: ctx} do
      Audit.log(ctx, "execution", %{component: "test", duration_ms: 100})
      Audit.log(ctx, "auth", %{action: "login"})
      :ok
    end

    test "exports as JSON by default", %{ctx: ctx} do
      {:ok, json_output} = Audit.export(ctx)

      assert is_binary(json_output)
      assert {:ok, events} = Jason.decode(json_output)
      assert is_list(events)
      assert length(events) >= 2
    end

    test "exports as JSON when format specified", %{ctx: ctx} do
      {:ok, json_output} = Audit.export(ctx, %{format: "json"})

      {:ok, events} = Jason.decode(json_output)
      assert is_list(events)
    end

    test "exports as CSV", %{ctx: ctx} do
      {:ok, csv_output} = Audit.export(ctx, %{format: "csv"})

      assert is_binary(csv_output)
      lines = String.split(csv_output, "\n", trim: true)

      # Should have header + data rows
      assert length(lines) >= 3

      # Check header
      header = hd(lines)
      assert String.contains?(header, "timestamp")
      assert String.contains?(header, "event_type")
      assert String.contains?(header, "user_id")
    end

    test "CSV escapes values with commas", %{ctx: ctx} do
      Audit.log(ctx, "test", %{message: "hello, world"})

      {:ok, csv_output} = Audit.export(ctx, %{format: "csv"})

      # Value with comma should be quoted
      assert String.contains?(csv_output, "\"")
    end

    test "returns error for unknown format", %{ctx: ctx} do
      assert {:error, "Unknown format: xml"} = Audit.export(ctx, %{format: "xml"})
    end

    test "export respects filters", %{ctx: ctx} do
      {:ok, json_output} = Audit.export(ctx, %{format: "json", event_type: "execution"})

      {:ok, events} = Jason.decode(json_output)
      assert Enum.all?(events, &(&1["event_type"] == "execution"))
    end
  end

  describe "data integrity" do
    test "event data is preserved correctly", %{ctx: ctx} do
      original_data = %{
        "component" => "test-component",
        "duration_ms" => 150,
        "nested" => %{"key" => "value"},
        "array" => [1, 2, 3]
      }

      Audit.log(ctx, "execution", original_data)

      {:ok, [event | _]} = Audit.list(ctx, %{event_type: "execution"})

      assert event["data"]["component"] == "test-component"
      assert event["data"]["duration_ms"] == 150
      assert event["data"]["nested"]["key"] == "value"
      assert event["data"]["array"] == [1, 2, 3]
    end
  end
end
