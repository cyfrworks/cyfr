defmodule ArcaTest do
  use ExUnit.Case

  alias Sanctum.Context

  @test_base_path System.tmp_dir!() |> Path.join("arca_main_test_#{:rand.uniform(100_000)}")

  setup do
    Application.put_env(:arca, :base_path, @test_base_path)

    on_exit(fn ->
      File.rm_rf!(@test_base_path)
    end)

    {:ok, ctx: Context.local()}
  end

  describe "basic operations" do
    test "put and get", %{ctx: ctx} do
      assert :ok == Arca.put(ctx, ["api", "test.txt"], "content")
      assert {:ok, "content"} == Arca.get(ctx, ["api", "test.txt"])
    end

    test "exists?", %{ctx: ctx} do
      refute Arca.exists?(ctx, ["missing.txt"])
      Arca.put(ctx, ["exists.txt"], "yes")
      assert Arca.exists?(ctx, ["exists.txt"])
    end

    test "delete", %{ctx: ctx} do
      Arca.put(ctx, ["delete.txt"], "bye")
      assert :ok == Arca.delete(ctx, ["delete.txt"])
      refute Arca.exists?(ctx, ["delete.txt"])
    end

    test "list", %{ctx: ctx} do
      Arca.put(ctx, ["listdir", "a.txt"], "a")
      Arca.put(ctx, ["listdir", "b.txt"], "b")
      {:ok, files} = Arca.list(ctx, ["listdir"])
      assert Enum.sort(files) == ["a.txt", "b.txt"]
    end
  end

  describe "append" do
    test "append adds content without overwriting", %{ctx: ctx} do
      path = ["audit", "test.jsonl"]

      assert :ok == Arca.append(ctx, path, "line1\n")
      assert :ok == Arca.append(ctx, path, "line2\n")

      {:ok, content} = Arca.get(ctx, path)
      assert content == "line1\nline2\n"
    end
  end

  describe "JSON convenience functions" do
    test "put_json and get_json", %{ctx: ctx} do
      data = %{"execution_id" => "exec_123", "status" => "started"}
      path = ["executions", "exec_123", "started.json"]

      assert :ok == Arca.put_json(ctx, path, data)
      assert {:ok, ^data} = Arca.get_json(ctx, path)
    end

    test "get_json returns error for invalid JSON", %{ctx: ctx} do
      path = ["invalid.json"]
      Arca.put(ctx, path, "not valid json")

      assert {:error, _} = Arca.get_json(ctx, path)
    end

    test "get_json returns not_found for missing file", %{ctx: ctx} do
      assert {:error, :not_found} = Arca.get_json(ctx, ["missing.json"])
    end

    test "append_json adds newline automatically", %{ctx: ctx} do
      path = ["audit", "events.jsonl"]

      assert :ok == Arca.append_json(ctx, path, %{"event" => "login"})
      assert :ok == Arca.append_json(ctx, path, %{"event" => "logout"})

      {:ok, content} = Arca.get(ctx, path)
      lines = String.split(content, "\n", trim: true)

      assert length(lines) == 2
      assert {:ok, %{"event" => "login"}} = Jason.decode(Enum.at(lines, 0))
      assert {:ok, %{"event" => "logout"}} = Jason.decode(Enum.at(lines, 1))
    end
  end

  describe "global vs user-scoped paths" do
    test "mcp_logs is a global path", %{ctx: ctx} do
      path = ["mcp_logs", "req_123.json"]
      Arca.put(ctx, path, "test")

      # Verify it's at root, not under users/
      expected_path = Path.join([@test_base_path, "mcp_logs", "req_123.json"])
      assert File.exists?(expected_path)
    end

    test "cache is a global path", %{ctx: ctx} do
      path = ["cache", "oci", "sha256_abc"]
      Arca.put(ctx, path, "wasm")

      expected_path = Path.join([@test_base_path, "cache", "oci", "sha256_abc"])
      assert File.exists?(expected_path)
    end

    test "executions is a user-scoped path", %{ctx: ctx} do
      path = ["executions", "exec_123", "started.json"]
      Arca.put(ctx, path, "test")

      expected_path = Path.join([@test_base_path, "users", ctx.user_id, "executions", "exec_123", "started.json"])
      assert File.exists?(expected_path)
    end
  end
end
