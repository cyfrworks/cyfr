# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.StorageHandlerTest do
  use ExUnit.Case, async: false

  alias Opus.StorageHandler
  alias Opus.Test.EdgeFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    test_dir = Path.join(System.tmp_dir!(), "storage_handler_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    ctx = Sanctum.TestContext.local()
    component_ref = "catalyst:local.files:0.1.0"

    on_exit(fn ->
      File.rm_rf!(test_dir)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, component_ref: component_ref, test_dir: test_dir}
  end

  # ============================================================================
  # Build Imports
  # ============================================================================

  describe "build_storage_imports/3" do
    test "returns correct namespace structure", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      imports = StorageHandler.build_storage_imports(edge, nil, ctx, ref)

      assert Map.has_key?(imports, "cyfr:storage/files@0.1.0")
      assert Map.has_key?(imports["cyfr:storage/files@0.1.0"], "call")
      assert match?({:fn, _}, imports["cyfr:storage/files@0.1.0"]["call"])
    end

    test "closure executes storage operations", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      imports = StorageHandler.build_storage_imports(edge, nil, ctx, ref)
      {:fn, call_fn} = imports["cyfr:storage/files@0.1.0"]["call"]

      # Write a file first
      write_req =
        Jason.encode!(%{
          "action" => "write",
          "path" => "data/test.txt",
          "content" => Base.encode64("hello")
        })

      write_result = call_fn.(write_req)
      decoded = Jason.decode!(write_result)
      assert decoded["status"] == "ok"
      assert decoded["written"] == true
    end
  end

  # ============================================================================
  # Bare-root listing
  # ============================================================================

  describe "bare-root listing" do
    test "empty path answers the two scopes, never the athanor's data root", %{
      ctx: ctx,
      component_ref: ref
    } do
      # The widest grant there is — the synthetic answer must hold even here.
      edge = EdgeFixtures.edge(paths: ["*"], actions: ["read", "write", "list", "exists"])
      imports = StorageHandler.build_storage_imports(edge, nil, ctx, ref)
      {:fn, call_fn} = imports["cyfr:storage/files@0.1.0"]["call"]

      # Host state a raw root walk would have surfaced to the guest.
      :ok = Arca.put(ctx, ["aqua", "agent.json"], "{}")

      list = call_fn.(Jason.encode!(%{"action" => "list", "path" => ""})) |> Jason.decode!()
      assert list["status"] == "ok"
      assert Enum.sort(list["files"]) == ["components/", "data/"]

      exists = call_fn.(Jason.encode!(%{"action" => "exists", "path" => ""})) |> Jason.decode!()
      assert exists["status"] == "ok"
      assert exists["exists"] == true
    end
  end

  # ============================================================================
  # Read Action
  # ============================================================================

  describe "execute/5 - read" do
    test "reads a file and returns base64 content", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      # Write file via Arca directly
      :ok = Arca.put(ctx, ["guest", "test.txt"], "hello world")

      request = Jason.encode!(%{"action" => "read", "path" => "data/test.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
      assert decoded["path"] == "data/test.txt"
      assert decoded["encoding"] == "base64"
      assert Base.decode64!(decoded["content"]) == "hello world"
      assert decoded["size"] == 11
    end

    test "returns error for missing file", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      request = Jason.encode!(%{"action" => "read", "path" => "data/missing.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "not_found"
      assert decoded["error"]["message"] =~ "not found"
    end
  end

  # ============================================================================
  # Write Action
  # ============================================================================

  describe "execute/5 - write" do
    test "writes base64 content to file", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      content = Base.encode64("hello world")

      request =
        Jason.encode!(%{"action" => "write", "path" => "data/test.txt", "content" => content})

      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
      assert decoded["written"] == true
      assert decoded["size"] == 11
      assert decoded["path"] == "data/test.txt"

      # Verify via Arca
      {:ok, stored} = Arca.get(ctx, ["guest", "test.txt"])
      assert stored == "hello world"
    end

    test "returns error for invalid base64 content", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      request =
        Jason.encode!(%{
          "action" => "write",
          "path" => "data/test.txt",
          "content" => "not-valid-base64!!!"
        })

      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_base64"
      assert decoded["error"]["message"] =~ "Invalid base64"
    end

    test "returns error for missing content field", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      request = Jason.encode!(%{"action" => "write", "path" => "data/test.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
      assert decoded["error"]["message"] =~ "content"
    end
  end

  # ============================================================================
  # List Action
  # ============================================================================

  describe "execute/5 - list" do
    test "lists files in a directory", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      # Write some files
      :ok = Arca.put(ctx, ["guest", "a.txt"], "aaa")
      :ok = Arca.put(ctx, ["guest", "b.txt"], "bbb")

      request = Jason.encode!(%{"action" => "list", "path" => "data"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
      assert is_list(decoded["files"])
    end

    test "marks directories with trailing slash", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      # Write a file and a nested file (which creates the subdirectory)
      :ok = Arca.put(ctx, ["guest", "file.txt"], "content")
      :ok = Arca.put(ctx, ["guest", "subdir", "nested.txt"], "nested")

      request = Jason.encode!(%{"action" => "list", "path" => "data"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
      files = decoded["files"]

      # Directories should end with /
      dir_entries = Enum.filter(files, &String.ends_with?(&1, "/"))
      file_entries = Enum.reject(files, &String.ends_with?(&1, "/"))

      assert "subdir/" in dir_entries
      assert "file.txt" in file_entries
      refute "subdir" in file_entries
    end
  end

  # ============================================================================
  # Delete Action
  # ============================================================================

  describe "execute/5 - delete" do
    test "deletes a file", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      :ok = Arca.put(ctx, ["guest", "to-delete.txt"], "content")

      request = Jason.encode!(%{"action" => "delete", "path" => "data/to-delete.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
      assert decoded["deleted"] == true

      # Verify deleted
      assert {:error, :not_found} = Arca.get(ctx, ["guest", "to-delete.txt"])
    end
  end

  # ============================================================================
  # Exists Action
  # ============================================================================

  describe "execute/5 - exists" do
    test "returns true for existing file", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      :ok = Arca.put(ctx, ["guest", "exists.txt"], "content")

      request = Jason.encode!(%{"action" => "exists", "path" => "data/exists.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
      assert decoded["exists"] == true
    end

    test "returns false for missing file", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      request = Jason.encode!(%{"action" => "exists", "path" => "data/nope.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
      assert decoded["exists"] == false
    end
  end

  # ============================================================================
  # Unknown Action
  # ============================================================================

  describe "execute/5 - unknown action" do
    test "returns error for unknown action", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      request = Jason.encode!(%{"action" => "truncate", "path" => "data/test.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "unknown_action"
      assert decoded["error"]["message"] =~ "Unknown storage action: truncate"
    end
  end

  # ============================================================================
  # Path Traversal Rejection
  # ============================================================================

  describe "execute/5 - path safety" do
    test "rejects path traversal with '..'", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      request = Jason.encode!(%{"action" => "read", "path" => "data/../secrets/key.json"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "storage_path_denied"
      assert decoded["error"]["message"] =~ "Path traversal"
    end

    test "rejects absolute paths", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      request = Jason.encode!(%{"action" => "read", "path" => "/etc/passwd"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "storage_path_denied"
    end

    test "rejects traversal in write", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      request =
        Jason.encode!(%{
          "action" => "write",
          "path" => "data/../../evil.txt",
          "content" => Base.encode64("bad")
        })

      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "storage_path_denied"
    end

    test "rejects traversal in delete", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      request = Jason.encode!(%{"action" => "delete", "path" => "data/../secrets/key.json"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "storage_path_denied"
    end
  end

  # ============================================================================
  # allowed_paths Enforcement
  # ============================================================================

  describe "execute/5 - allowed_paths enforcement" do
    test "denies when allowed_paths is empty", %{ctx: ctx, component_ref: ref} do
      edge = EdgeFixtures.edge(paths: [], actions: ["read"])

      request = Jason.encode!(%{"action" => "read", "path" => "data/test.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "storage_path_denied"
      assert decoded["error"]["message"] =~ "not allowed by policy"
    end

    test "denies path outside allowed prefixes but within valid scope", %{
      ctx: ctx,
      component_ref: ref
    } do
      edge = EdgeFixtures.edge(paths: ["data/reports/"], actions: ["read"])

      request = Jason.encode!(%{"action" => "read", "path" => "data/secrets/key.json"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "storage_path_denied"
      assert decoded["error"]["message"] =~ "not allowed by policy"
    end

    test "allows path within allowed prefixes", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      :ok = Arca.put(ctx, ["guest", "test.txt"], "content")

      request = Jason.encode!(%{"action" => "read", "path" => "data/test.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
    end

    test "supports multiple allowed path prefixes", %{ctx: ctx, component_ref: ref} do
      edge = EdgeFixtures.edge(paths: ["data/", "components/catalysts/"], actions: ["read"])

      # Component paths are tenant-relative — the guest's spelling IS the
      # host's spelling, and the context supplies the athanor.
      :ok =
        Arca.put(
          ctx,
          ["components", "catalysts", "test", "0.1.0", "output.json"],
          "{}"
        )

      request =
        Jason.encode!(%{
          "action" => "read",
          "path" => "components/catalysts/test/0.1.0/output.json"
        })

      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
    end
  end

  # ============================================================================
  # Request Parsing
  # ============================================================================

  describe "execute/5 - request parsing" do
    test "returns error for invalid JSON", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      result = StorageHandler.execute("not json", edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_json"
    end

    test "returns error for missing action", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      result = StorageHandler.execute(~s({"path": "data/test.txt"}), edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
    end

    test "returns error for missing path on read", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      result = StorageHandler.execute(~s({"action": "read"}), edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
      assert decoded["error"]["message"] =~ "path"
    end
  end

  # ============================================================================
  # Telemetry
  # ============================================================================

  describe "execute/5 - telemetry" do
    test "emits telemetry event on storage call", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      test_pid = self()
      handler_ref = make_ref()

      :telemetry.attach(
        "test-storage-#{inspect(handler_ref)}",
        [:cyfr, :opus, :storage, :call],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      :ok = Arca.put(ctx, ["guest", "telemetry-test.txt"], "content")

      request = Jason.encode!(%{"action" => "read", "path" => "data/telemetry-test.txt"})
      _result = StorageHandler.execute(request, edge, nil, ctx, ref)

      assert_receive {:telemetry_event, [:cyfr, :opus, :storage, :call], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.component_ref == ref
      assert metadata.action == "read"
      assert metadata.status == :ok

      :telemetry.detach("test-storage-#{inspect(handler_ref)}")
    end

    test "emits telemetry with error status on denied path", %{ctx: ctx, component_ref: ref} do
      edge = EdgeFixtures.edge(paths: [])

      test_pid = self()
      handler_ref = make_ref()

      :telemetry.attach(
        "test-storage-denied-#{inspect(handler_ref)}",
        [:cyfr, :opus, :storage, :call],
        fn _event_name, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_status, metadata.status})
        end,
        nil
      )

      request = Jason.encode!(%{"action" => "read", "path" => "data/test.txt"})
      _result = StorageHandler.execute(request, edge, nil, ctx, ref)

      assert_receive {:telemetry_status, :error}

      :telemetry.detach("test-storage-denied-#{inspect(handler_ref)}")
    end
  end

  # ============================================================================
  # allowed_actions Enforcement
  # ============================================================================

  describe "execute/5 - allowed_actions enforcement" do
    test "denies action not in allowed_actions", %{ctx: ctx, component_ref: ref} do
      edge = EdgeFixtures.edge(paths: ["data/"], actions: ["read", "list", "exists"])

      :ok = Arca.put(ctx, ["guest", "test.txt"], "content")

      request =
        Jason.encode!(%{
          "action" => "write",
          "path" => "data/test.txt",
          "content" => Base.encode64("new")
        })

      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "action_denied"
      assert decoded["error"]["message"] =~ "Storage action 'write' is not allowed by policy."
    end

    test "allows action in allowed_actions", %{ctx: ctx, component_ref: ref} do
      edge = EdgeFixtures.edge(paths: ["data/"], actions: ["read", "list", "exists"])

      :ok = Arca.put(ctx, ["guest", "test.txt"], "content")

      request = Jason.encode!(%{"action" => "read", "path" => "data/test.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
    end

    test "denies all actions when default (empty list)", %{ctx: ctx, component_ref: ref} do
      edge = EdgeFixtures.edge(paths: ["data/"])

      :ok = Arca.put(ctx, ["guest", "test.txt"], "content")

      request = Jason.encode!(%{"action" => "read", "path" => "data/test.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "action_denied"
    end

    test "allows all actions when explicitly set", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      :ok = Arca.put(ctx, ["guest", "test.txt"], "content")

      # Read
      request = Jason.encode!(%{"action" => "read", "path" => "data/test.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      assert Jason.decode!(result)["status"] == "ok"

      # Write
      request =
        Jason.encode!(%{
          "action" => "write",
          "path" => "data/new.txt",
          "content" => Base.encode64("new")
        })

      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      assert Jason.decode!(result)["status"] == "ok"

      # Delete
      request = Jason.encode!(%{"action" => "delete", "path" => "data/new.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      assert Jason.decode!(result)["status"] == "ok"
    end

    test "denies delete when only read allowed", %{ctx: ctx, component_ref: ref} do
      edge = EdgeFixtures.edge(paths: ["data/"], actions: ["read"])

      :ok = Arca.put(ctx, ["guest", "test.txt"], "content")

      request = Jason.encode!(%{"action" => "delete", "path" => "data/test.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "action_denied"
    end
  end

  # ============================================================================
  # validate_path_safe/1
  # ============================================================================

  describe "validate_path_safe/1" do
    test "allows normal paths" do
      assert :ok = StorageHandler.validate_path_safe("data/file.txt")

      assert :ok =
               StorageHandler.validate_path_safe("components/catalysts/test/0.1.0/catalyst.wasm")
    end

    test "rejects absolute paths" do
      assert {:error, :storage_path_denied, _} = StorageHandler.validate_path_safe("/etc/passwd")

      assert {:error, :storage_path_denied, _} =
               StorageHandler.validate_path_safe("/data/file.txt")
    end

    test "rejects path traversal" do
      assert {:error, :storage_path_denied, _} =
               StorageHandler.validate_path_safe("data/../secret")

      assert {:error, :storage_path_denied, _} = StorageHandler.validate_path_safe("../escape")

      assert {:error, :storage_path_denied, _} =
               StorageHandler.validate_path_safe("data/a/../../c")
    end

    test "allows empty path" do
      assert :ok = StorageHandler.validate_path_safe("")
    end
  end

  # ============================================================================
  # validate_path_scope/1
  # ============================================================================

  describe "validate_path_scope/1" do
    test "allows data/ paths" do
      assert :ok = StorageHandler.validate_path_scope("data/file.txt")
      assert :ok = StorageHandler.validate_path_scope("data/reports/2024.json")
    end

    test "allows components/ paths" do
      assert :ok =
               StorageHandler.validate_path_scope("components/catalysts/test/0.1.0/catalyst.wasm")

      assert :ok = StorageHandler.validate_path_scope("components/reagents/agent/data.json")
    end

    test "allows empty path" do
      assert :ok = StorageHandler.validate_path_scope("")
    end

    test "rejects paths outside valid scopes" do
      assert {:error, :storage_path_denied, msg} =
               StorageHandler.validate_path_scope("secrets/key.json")

      assert msg =~ "must start with 'data/' or 'components/'"

      assert {:error, :storage_path_denied, _} =
               StorageHandler.validate_path_scope("agent/file.txt")

      assert {:error, :storage_path_denied, _} =
               StorageHandler.validate_path_scope("artifacts/build.wasm")
    end
  end

  # ============================================================================
  # Append Action
  # ============================================================================

  describe "execute/5 - append" do
    test "appends base64 content to a file", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "append", "list", "delete", "exists"]
        )

      :ok = Arca.put(ctx, ["guest", "log.txt"], "line1\n")

      request =
        Jason.encode!(%{
          "action" => "append",
          "path" => "data/log.txt",
          "content" => Base.encode64("line2\n")
        })

      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
      assert decoded["appended"] == true
      assert decoded["size"] == 6

      # Verify content was appended
      {:ok, content} = Arca.get(ctx, ["guest", "log.txt"])
      assert content == "line1\nline2\n"
    end

    test "creates file if it does not exist", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "append", "list", "delete", "exists"]
        )

      request =
        Jason.encode!(%{
          "action" => "append",
          "path" => "data/new-log.txt",
          "content" => Base.encode64("first line\n")
        })

      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["status"] == "ok"
      assert decoded["appended"] == true
    end

    test "rejects append without content", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "append", "list", "delete", "exists"]
        )

      request = Jason.encode!(%{"action" => "append", "path" => "data/log.txt"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
    end

    test "rejects invalid base64 content", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "append", "list", "delete", "exists"]
        )

      request =
        Jason.encode!(%{
          "action" => "append",
          "path" => "data/log.txt",
          "content" => "not valid base64!!!"
        })

      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_base64"
    end

    test "denied when append not in allowed_actions", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      request =
        Jason.encode!(%{
          "action" => "append",
          "path" => "data/log.txt",
          "content" => Base.encode64("data")
        })

      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "action_denied"
    end
  end

  # ============================================================================
  # Scope Validation Integration
  # ============================================================================

  describe "execute/5 - scope validation" do
    test "rejects paths outside data/ and components/ scopes", %{ctx: ctx, component_ref: ref} do
      edge =
        EdgeFixtures.edge(
          paths: ["data/"],
          actions: ["read", "write", "list", "delete", "exists"]
        )

      request = Jason.encode!(%{"action" => "read", "path" => "secrets/key.json"})
      result = StorageHandler.execute(request, edge, nil, ctx, ref)
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "storage_path_denied"
      assert decoded["error"]["message"] =~ "must start with 'data/' or 'components/'"
    end
  end

  # ============================================================================
  # Size ceilings (node limits) and the public quota
  # ============================================================================

  describe "size ceilings from node limits" do
    defp small_limits do
      %Sanctum.Limits{max_request_size: 16, max_response_size: 16}
    end

    defp rw_edge do
      EdgeFixtures.edge(paths: ["data/"], actions: ["read", "write"])
    end

    test "a write past max_request_size is refused on the DECODED size", %{
      ctx: ctx,
      component_ref: ref
    } do
      # 24 decoded bytes → 32 base64 chars. The ceiling reads the payload,
      # not the framing.
      content = Base.encode64(String.duplicate("x", 24))
      request = ~s({"action": "write", "path": "data/big.txt", "content": "#{content}"})

      decoded =
        Jason.decode!(StorageHandler.execute(request, rw_edge(), small_limits(), ctx, ref))

      assert decoded["error"]["type"] == "request_too_large"
    end

    test "a small write under the ceiling still lands", %{ctx: ctx, component_ref: ref} do
      content = Base.encode64("tiny")
      request = ~s({"action": "write", "path": "data/small.txt", "content": "#{content}"})

      decoded =
        Jason.decode!(StorageHandler.execute(request, rw_edge(), small_limits(), ctx, ref))

      assert decoded["written"] == true
    end

    test "a read past max_response_size is refused before base64 framing", %{
      ctx: ctx,
      component_ref: ref
    } do
      :ok = Arca.put(ctx, ["guest", "big.txt"], String.duplicate("y", 64))

      request = ~s({"action": "read", "path": "data/big.txt"})

      decoded =
        Jason.decode!(StorageHandler.execute(request, rw_edge(), small_limits(), ctx, ref))

      assert decoded["error"]["type"] == "response_too_large"
    end
  end

  describe "public quota counts what the guest actually stores" do
    defp quota_write(ctx, ref, path, bytes, quota) do
      content = Base.encode64(String.duplicate("z", bytes))
      request = ~s({"action": "write", "path": "#{path}", "content": "#{content}"})

      StorageHandler.execute(request, rw_edge(), nil, ctx, ref,
        public?: true,
        public_quota: quota
      )
      |> Jason.decode!()
    end

    test "usage is recursive — a nested write cannot evade the byte ceiling", %{
      ctx: ctx,
      component_ref: ref
    } do
      quota = %{max_bytes: 100, max_files: 50}

      # 60 bytes deep in a subdirectory — the old top-level listing counted
      # this as zero.
      assert %{"written" => true} = quota_write(ctx, ref, "data/nested/deep/a.txt", 60, quota)

      # 60 more would cross 100; the recursive usage must see the first file.
      decoded = quota_write(ctx, ref, "data/b.txt", 60, quota)
      assert decoded["error"]["type"] == "storage_quota_exceeded"
      assert decoded["error"]["message"] =~ "storage quota"
    end

    test "the file ceiling counts nested files too", %{ctx: ctx, component_ref: ref} do
      quota = %{max_bytes: 1_000_000, max_files: 2}

      assert %{"written" => true} = quota_write(ctx, ref, "data/one/a.txt", 4, quota)
      assert %{"written" => true} = quota_write(ctx, ref, "data/two/b.txt", 4, quota)

      decoded = quota_write(ctx, ref, "data/three/c.txt", 4, quota)
      assert decoded["error"]["type"] == "storage_quota_exceeded"
      assert decoded["error"]["message"] =~ "file quota"
    end

    test "the incoming size is the decoded payload, not the base64 framing", %{
      ctx: ctx,
      component_ref: ref
    } do
      # 90 decoded bytes → 120 base64 chars. Under a 100-byte quota the
      # write must pass: framing is transport, not stored bytes.
      quota = %{max_bytes: 100, max_files: 50}
      assert %{"written" => true} = quota_write(ctx, ref, "data/exact.txt", 90, quota)
    end

    defp components_quota_write(ctx, ref, path, bytes, quota) do
      content = Base.encode64(String.duplicate("z", bytes))
      request = ~s({"action": "write", "path": "#{path}", "content": "#{content}"})

      edge = EdgeFixtures.edge(paths: ["data/", "components/"], actions: ["read", "write"])

      StorageHandler.execute(request, edge, nil, ctx, ref,
        public?: true,
        public_quota: quota
      )
      |> Jason.decode!()
    end

    test "the components scope is counted too — the quota is not data-only", %{
      ctx: ctx,
      component_ref: ref
    } do
      quota = %{max_bytes: 100, max_files: 50}

      assert %{"written" => true} =
               components_quota_write(
                 ctx,
                 ref,
                 "components/catalysts/test/0.1.0/a.txt",
                 60,
                 quota
               )

      decoded =
        components_quota_write(ctx, ref, "components/catalysts/test/0.1.0/b.txt", 60, quota)

      assert decoded["error"]["type"] == "storage_quota_exceeded"
    end

    test "an athanor-less context gets a typed refusal, never a raise", %{component_ref: ref} do
      # No athanor: the quota walk cannot pin the components root, so it is
      # skipped as unreadable, and the write itself is refused downstream.
      anon = Sanctum.Context.build(user_id: "anon", athanor_id: nil, authenticated: false)

      quota = %{max_bytes: 100, max_files: 50}

      decoded =
        components_quota_write(anon, ref, "components/catalysts/test/0.1.0/a.txt", 10, quota)

      assert %{"error" => %{"type" => _}} = decoded
    end
  end
end
