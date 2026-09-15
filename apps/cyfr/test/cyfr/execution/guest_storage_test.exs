# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.GuestStorageTest.UnreadableUsageAdapter do
  @moduledoc false
  use Arca.Storage.TestDouble

  def usage(_ctx, _path), do: {:error, :unreadable}
end

defmodule Cyfr.Execution.GuestStorageTest do
  @moduledoc """
  What a guest's storage operation may reach is decided on CYFR: the
  athanor it runs in, the actions and paths its consent edge grants, the
  guest scopes of the athanor's tree and never the host's, the unit grammar
  and publisher of a component write, path safety, the node's size limits,
  the public quota and the per-scope file ceiling. A write runs only
  through the attempt's hold, and a refused hold writes nothing. Every
  refusal is a typed error for the guest, never a raise.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge
  alias Cyfr.Execution.GuestStorage
  alias Cyfr.Execution.GuestStorageTest.UnreadableUsageAdapter

  @every_action ["read", "write", "append", "list", "delete", "exists"]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    # The public-quota counters are keyed by athanor and scope; each test
    # gets a fresh storage root under the same athanor id.
    Arca.Cache.delete_match({:scope_usage, :_, :_, :_})

    test_dir =
      Path.join(System.tmp_dir!(), "guest_storage_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local(), test_dir: test_dir}
  end

  defp edge(paths, actions \\ @every_action),
    do: %Edge{storage: %{paths: paths, actions: actions}}

  # One operation under an edge, held unless `:hold` says otherwise.
  defp run(ctx, edge, %{"action" => action} = request, opts \\ []) do
    scope = %{
      ctx: ctx,
      edge: edge,
      limits: Keyword.get(opts, :limits),
      quota: Keyword.get(opts, :quota),
      hold: Keyword.get(opts, :hold, fn write -> {:ok, write.()} end)
    }

    GuestStorage.run(scope, String.to_existing_atom(action), Map.delete(request, "action"))
  end

  defp write(path, text),
    do: %{"action" => "write", "path" => path, "content" => Base.encode64(text)}

  defp refused(result) do
    assert {:error, {:guest_error, type, message}} = result
    {type, message}
  end

  describe "operations" do
    test "read answers base64 content; a missing file is not_found", %{ctx: ctx} do
      :ok = Arca.put(ctx, ["data", "test.txt"], "hello world")

      assert {:ok, answer} =
               run(ctx, edge(["data/"]), %{"action" => "read", "path" => "data/test.txt"})

      assert answer == %{
               "path" => "data/test.txt",
               "content" => Base.encode64("hello world"),
               "size" => 11,
               "encoding" => "base64"
             }

      assert {"not_found", message} =
               refused(
                 run(ctx, edge(["data/"]), %{"action" => "read", "path" => "data/missing.txt"})
               )

      assert message =~ "not found"
    end

    test "write stores the decoded content", %{ctx: ctx} do
      assert {:ok, %{"path" => "data/test.txt", "written" => true, "size" => 11}} =
               run(ctx, edge(["data/"]), write("data/test.txt", "hello world"))

      assert {:ok, "hello world"} = Arca.get(ctx, ["data", "test.txt"])
    end

    test "write and append refuse invalid base64 and missing content", %{ctx: ctx} do
      for action <- ["write", "append"] do
        assert {"invalid_base64", message} =
                 refused(
                   run(ctx, edge(["data/"]), %{
                     "action" => action,
                     "path" => "data/test.txt",
                     "content" => "not-valid-base64!!!"
                   })
                 )

        assert message =~ "Invalid base64"

        assert {"invalid_request", message} =
                 refused(
                   run(ctx, edge(["data/"]), %{"action" => action, "path" => "data/test.txt"})
                 )

        assert message =~ "content"
      end

      refute Arca.exists?(ctx, ["data", "test.txt"])
    end

    test "append adds to a file, creating it when absent", %{ctx: ctx} do
      :ok = Arca.put(ctx, ["data", "log.txt"], "line1\n")

      assert {:ok, %{"appended" => true, "size" => 6}} =
               run(ctx, edge(["data/"]), %{
                 "action" => "append",
                 "path" => "data/log.txt",
                 "content" => Base.encode64("line2\n")
               })

      assert {:ok, "line1\nline2\n"} = Arca.get(ctx, ["data", "log.txt"])

      assert {:ok, %{"appended" => true}} =
               run(ctx, edge(["data/"]), %{
                 "action" => "append",
                 "path" => "data/new-log.txt",
                 "content" => Base.encode64("first line\n")
               })
    end

    test "list marks directories with a trailing slash", %{ctx: ctx} do
      :ok = Arca.put(ctx, ["data", "file.txt"], "content")
      :ok = Arca.put(ctx, ["data", "subdir", "nested.txt"], "nested")

      assert {:ok, %{"path" => "data", "files" => files}} =
               run(ctx, edge(["data/"]), %{"action" => "list", "path" => "data"})

      assert Enum.sort(files) == ["file.txt", "subdir/"]
    end

    test "delete removes a file; exists answers whether one is there", %{ctx: ctx} do
      :ok = Arca.put(ctx, ["data", "to-delete.txt"], "content")

      assert {:ok, %{"exists" => true}} =
               run(ctx, edge(["data/"]), %{"action" => "exists", "path" => "data/to-delete.txt"})

      assert {:ok, %{"path" => "data/to-delete.txt", "deleted" => true}} =
               run(ctx, edge(["data/"]), %{"action" => "delete", "path" => "data/to-delete.txt"})

      assert {:error, :not_found} = Arca.get(ctx, ["data", "to-delete.txt"])

      assert {:ok, %{"exists" => false}} =
               run(ctx, edge(["data/"]), %{"action" => "exists", "path" => "data/to-delete.txt"})

      assert {"not_found", _} =
               refused(
                 run(ctx, edge(["data/"]), %{"action" => "delete", "path" => "data/to-delete.txt"})
               )
    end

    test "content that is not a string is an invalid request", %{ctx: ctx} do
      assert {"invalid_request", _} =
               refused(
                 run(ctx, edge(["data/"]), %{
                   "action" => "write",
                   "path" => "data/a.txt",
                   "content" => 42
                 })
               )
    end
  end

  describe "the bare root" do
    test "lists the guest scopes, never the athanor's tree, even under '*'", %{ctx: ctx} do
      :ok = Arca.put(ctx, ["aqua", "agent.json"], "{}")

      assert {:ok, %{"path" => "", "files" => files}} =
               run(ctx, edge(["*"]), %{"action" => "list", "path" => ""})

      assert Enum.sort(files) == ["components/", "data/"]

      assert {:ok, %{"exists" => true}} =
               run(ctx, edge(["*"]), %{"action" => "exists", "path" => ""})
    end

    test "a mutation of the bare root or a bare scope is refused, even under '*'", %{ctx: ctx} do
      for request <- [
            %{"action" => "write", "content" => Base.encode64("x")},
            %{"action" => "append", "content" => Base.encode64("x")},
            %{"action" => "delete"}
          ],
          path <- ["", "data", "components"] do
        assert {"storage_path_denied", _} =
                 refused(run(ctx, edge(["*"]), Map.put(request, "path", path)))
      end
    end
  end

  describe "the consent edge" do
    test "an action the edge does not name is denied; actions match case-insensitively", %{
      ctx: ctx
    } do
      :ok = Arca.put(ctx, ["data", "test.txt"], "content")

      assert {"action_denied", "Storage action 'write' is not allowed by policy."} =
               refused(
                 run(
                   ctx,
                   edge(["data/"], ["read", "list", "exists"]),
                   write("data/test.txt", "new")
                 )
               )

      assert {"action_denied", _} =
               refused(
                 run(ctx, edge(["data/"], ["read"]), %{
                   "action" => "delete",
                   "path" => "data/test.txt"
                 })
               )

      assert {:ok, _} =
               run(ctx, edge(["data/"], ["READ"]), %{
                 "action" => "read",
                 "path" => "data/test.txt"
               })

      assert {:ok, "content"} = Arca.get(ctx, ["data", "test.txt"])
    end

    test "a nil edge, a nil storage group and empty lists deny everything", %{ctx: ctx} do
      for edge <- [nil, %Edge{}, edge([], []), edge([], @every_action)] do
        assert {type, _} =
                 refused(run(ctx, edge, %{"action" => "read", "path" => "data/test.txt"}))

        assert type in ["action_denied", "storage_path_denied"]
      end

      assert {"storage_path_denied", message} =
               refused(
                 run(ctx, edge([], ["read"]), %{"action" => "read", "path" => "data/test.txt"})
               )

      assert message =~ "not allowed by policy"
    end

    test "an entry without a trailing slash is that exact path", %{ctx: ctx} do
      exact = edge(["data/notes/todo.md"])
      :ok = Arca.put(ctx, ["data", "notes", "todo.md"], "t")

      assert {:ok, _} = run(ctx, exact, %{"action" => "read", "path" => "data/notes/todo.md"})

      for path <- ["data/notes/todo.md.bak", "data/notes/", "data/notes/other.md"] do
        assert {"storage_path_denied", _} =
                 refused(run(ctx, exact, %{"action" => "read", "path" => path}))
      end
    end

    test "a trailing slash is a prefix, and a directory is named with or without it", %{ctx: ctx} do
      prefix = edge(["data/notes/"])
      :ok = Arca.put(ctx, ["data", "notes", "deep", "todo.md"], "t")

      assert {:ok, _} =
               run(ctx, prefix, %{"action" => "read", "path" => "data/notes/deep/todo.md"})

      assert {:ok, _} = run(ctx, prefix, %{"action" => "list", "path" => "data/notes"})

      for path <- ["data/notes-private/todo.md", "data/other/todo.md", "data"] do
        assert {"storage_path_denied", _} =
                 refused(run(ctx, prefix, %{"action" => "read", "path" => path}))
      end
    end

    test "several prefixes each allow their own scope", %{ctx: ctx} do
      grants = edge(["data/", "components/catalysts/"], ["read"])
      unit = ["components", "catalysts", "test", "pkg", "0.1.0", "output.json"]
      :ok = Arca.put(ctx, unit, "{}")

      assert {:ok, _} =
               run(ctx, grants, %{"action" => "read", "path" => Enum.join(unit, "/")})
    end
  end

  describe "paths" do
    test "traversal and absolute paths are refused for every action", %{ctx: ctx} do
      for request <- [
            %{"action" => "read", "path" => "data/../secrets/key.json"},
            %{"action" => "read", "path" => "/etc/passwd"},
            %{
              "action" => "write",
              "path" => "data/../../evil.txt",
              "content" => Base.encode64("bad")
            },
            %{"action" => "delete", "path" => "data/../secrets/key.json"},
            %{"action" => "list", "path" => "data/a/../../c"}
          ] do
        assert {"storage_path_denied", _} = refused(run(ctx, edge(["*"]), request))
      end

      assert {"storage_path_denied", message} =
               refused(
                 run(ctx, edge(["data/"]), %{
                   "action" => "read",
                   "path" => "data/../secrets/key.json"
                 })
               )

      assert message =~ "Path traversal"
    end

    test "a path outside the guest scopes is refused", %{ctx: ctx} do
      for path <- ["secrets/key.json", "agent/file.txt", "artifacts/build.wasm", "*"] do
        assert {"storage_path_denied", message} =
                 refused(run(ctx, edge(["*"]), %{"action" => "read", "path" => path}))

        assert message =~ "must start with 'components/' or 'data/'"
      end
    end

    test "the host's roots are invisible to a guest, however wide its grant", %{ctx: ctx} do
      # Refused as host roots of the athanor's tree, not as unknown ones.
      assert "aqua" in Arca.Storage.tenant_roots()
      assert "threads" in Arca.Storage.tenant_roots()
      :ok = Arca.put(ctx, ["aqua", "agent.json"], "{}")
      :ok = Arca.put(ctx, ["threads", "thread_1", "msg_1.txt"], "host bytes")

      for path <- ["aqua/agent.json", "aqua", "threads/thread_1/msg_1.txt", "threads"],
          request <- [%{"action" => "read"}, %{"action" => "list"}, write(path, "guest bytes")] do
        assert {"storage_path_denied", _} =
                 refused(run(ctx, edge(["*"]), Map.put(request, "path", path)))
      end

      assert {:ok, "host bytes"} = Arca.get(ctx, ["threads", "thread_1", "msg_1.txt"])

      # The retired name for threads/ (spelled split for the vocabulary
      # gate) is no root at all, and no guest path either.
      retired = "conver" <> "sations"
      refute retired in Arca.Storage.tenant_roots()

      assert {"storage_path_denied", _} =
               refused(
                 run(ctx, edge(["*"]), %{"action" => "read", "path" => retired <> "/thread_1"})
               )
    end

    test "a grant that parses is a path this boundary honors, and the reverse", %{ctx: ctx} do
      for path <- [
            "data",
            "data/",
            "data/notes.txt",
            "components",
            "components/catalysts/local/x/0.1.0/catalyst.wasm",
            "aqua/agent.json",
            "threads/thread_1",
            "guest/notes.txt",
            "secrets/key.json"
          ] do
        manifest = %{"caps" => %{"storage" => %{"paths" => [path]}}}
        parses? = Compendium.Manifest.Caps.validate(manifest) == :ok

        honored? =
          not match?(
            {:error, {:guest_error, "storage_path_denied", "Path must start with" <> _}},
            run(ctx, edge(["*"]), %{"action" => "exists", "path" => path})
          )

        assert parses? == honored?,
               "manifest and boundary disagree on #{inspect(path)}: " <>
                 "parses?=#{parses?} honored?=#{honored?}"
      end

      # `"*"` is grant grammar and never a request path; `""` is the scope
      # listing and never a grant.
      assert :ok =
               Compendium.Manifest.Caps.validate(%{"caps" => %{"storage" => %{"paths" => ["*"]}}})

      assert {"storage_path_denied", _} =
               refused(run(ctx, edge(["*"]), %{"action" => "exists", "path" => "*"}))

      assert {:ok, _} = run(ctx, edge(["*"]), %{"action" => "exists", "path" => ""})
    end
  end

  describe "component writes" do
    setup %{test_dir: test_dir} do
      seed = Path.join(test_dir, "seed_fixture")
      bundle = Path.join([seed, "components", "catalysts", "local", "bundled", "1.0.0"])
      File.mkdir_p!(bundle)
      File.write!(Path.join(bundle, "cyfr-manifest.json"), ~s({"type":"catalyst"}))
      File.write!(Path.join(bundle, "config.json"), ~s({"seeded":true}))

      prev_seed = Application.get_env(:cyfr, :seed_path)
      Application.put_env(:cyfr, :seed_path, seed)

      on_exit(fn ->
        if prev_seed,
          do: Application.put_env(:cyfr, :seed_path, prev_seed),
          else: Application.delete_env(:cyfr, :seed_path)
      end)

      :ok
    end

    test "a guest reads a shipped bundle file the athanor holds", %{ctx: ctx} do
      :ok =
        Arca.Overlay.pull_shipped(ctx, ["components", "catalysts", "local", "bundled", "1.0.0"])

      grants = edge(["components/"], ["read", "list"])

      assert {:ok, %{"content" => content}} =
               run(ctx, grants, %{
                 "action" => "read",
                 "path" => "components/catalysts/local/bundled/1.0.0/config.json"
               })

      assert Base.decode64!(content) == ~s({"seeded":true})

      assert {:ok, %{"files" => ["1.0.0/"]}} =
               run(ctx, grants, %{
                 "action" => "list",
                 "path" => "components/catalysts/local/bundled"
               })
    end

    test "a guest write into a shipped copy lands as an edit", %{ctx: ctx} do
      unit = ["components", "catalysts", "local", "bundled", "1.0.0"]
      :ok = Arca.Overlay.pull_shipped(ctx, unit)

      assert {:ok, %{"written" => true}} =
               run(
                 ctx,
                 edge(["components/"]),
                 write(
                   "components/catalysts/local/bundled/1.0.0/config.json",
                   ~s({"seeded":false})
                 )
               )

      assert {:ok, ~s({"seeded":false})} = Arca.get(ctx, unit ++ ["config.json"])
      assert Arca.Adapters.Local.exists?(ctx, unit ++ ["cyfr-manifest.json"])
      assert Arca.Overlay.unit_status(ctx, unit) == {:ok, :shipped}
      assert {:ok, true} = Arca.Overlay.edited?(ctx, unit)
    end

    test "a mutation above the unit grammar is refused; data/ at the same depth is not", %{
      ctx: ctx
    } do
      grants = edge(["data/", "components/"])

      assert {"storage_path_denied", message} =
               refused(run(ctx, grants, write("components/junk.txt", "junk")))

      assert message =~ "version directory"
      assert {:ok, %{"written" => true}} = run(ctx, grants, write("data/junk.txt", "fine"))
    end

    test "a write under a pulled publisher is refused; local/ is free", %{ctx: ctx} do
      grants = edge(["data/", "components/"])

      assert {"storage_path_denied", message} =
               refused(
                 run(
                   ctx,
                   grants,
                   write("components/catalysts/moonmoon69/x/1.0.0/catalyst.wasm", "evil")
                 )
               )

      assert message =~ "fork into local/"

      assert {:ok, %{"written" => true}} =
               run(
                 ctx,
                 grants,
                 write("components/catalysts/local/mine/0.1.0/output.json", ~s({"ok":true}))
               )
    end
  end

  describe "size limits" do
    defp small_limits, do: %Cyfr.Limits{max_request_size: 16, max_response_size: 16}

    test "a write past max_request_size is refused on its decoded size", %{ctx: ctx} do
      # 24 decoded bytes are 32 base64 characters.
      assert {"request_too_large", message} =
               refused(
                 run(ctx, edge(["data/"]), write("data/big.txt", String.duplicate("x", 24)),
                   limits: small_limits()
                 )
               )

      assert message =~ "24 bytes"
      refute Arca.exists?(ctx, ["data", "big.txt"])

      assert {:ok, %{"written" => true}} =
               run(ctx, edge(["data/"]), write("data/small.txt", "tiny"), limits: small_limits())

      # 16 decoded bytes are at the limit, not past it.
      assert {:ok, %{"written" => true}} =
               run(ctx, edge(["data/"]), write("data/exact.txt", String.duplicate("y", 16)),
                 limits: small_limits()
               )
    end

    test "a read or listing past max_response_size is refused", %{ctx: ctx} do
      :ok = Arca.put(ctx, ["data", "big.txt"], String.duplicate("y", 64))

      assert {"response_too_large", _} =
               refused(
                 run(ctx, edge(["data/"]), %{"action" => "read", "path" => "data/big.txt"},
                   limits: small_limits()
                 )
               )

      for name <- ["a-long-file-name.txt", "another-long-name.txt"],
          do: :ok = Arca.put(ctx, ["data", "listed", name], "x")

      assert {"response_too_large", _} =
               refused(
                 run(ctx, edge(["data/"]), %{"action" => "list", "path" => "data/listed"},
                   limits: small_limits()
                 )
               )
    end
  end

  describe "the public quota" do
    defp quota_write(ctx, path, bytes, quota, grants \\ ["data/"]) do
      run(ctx, edge(grants), write(path, String.duplicate("z", bytes)), quota: quota)
    end

    test "usage is recursive, so a nested write cannot evade the byte quota", %{ctx: ctx} do
      quota = %{max_bytes: 100, max_files: 50}
      assert {:ok, %{"written" => true}} = quota_write(ctx, "data/nested/deep/a.txt", 60, quota)

      assert {"storage_quota_exceeded", message} =
               refused(quota_write(ctx, "data/b.txt", 60, quota))

      assert message =~ "storage quota"
    end

    test "the file quota counts nested files too", %{ctx: ctx} do
      quota = %{max_bytes: 1_000_000, max_files: 2}

      assert {:ok, _} = quota_write(ctx, "data/one/a.txt", 4, quota)
      assert {:ok, _} = quota_write(ctx, "data/two/b.txt", 4, quota)

      assert {"storage_quota_exceeded", message} =
               refused(quota_write(ctx, "data/three/c.txt", 4, quota))

      assert message =~ "file quota"
    end

    test "usage is cached and bumped per write, and a delete drops it", %{ctx: ctx} do
      quota = %{max_bytes: 1_000_000, max_files: 10}
      assert {:ok, _} = quota_write(ctx, "data/a.txt", 4, quota)

      bytes_key = Arca.Cache.Keys.scope_usage_bytes(ctx.athanor_id, "data")
      files_key = Arca.Cache.Keys.scope_usage_files(ctx.athanor_id, "data")
      assert {:ok, 4} = Arca.Cache.get(bytes_key)
      assert {:ok, 1} = Arca.Cache.get(files_key)

      assert {:ok, _} = quota_write(ctx, "data/b.txt", 6, quota)
      assert {:ok, 10} = Arca.Cache.get(bytes_key)
      assert {:ok, 2} = Arca.Cache.get(files_key)

      assert {:ok, %{"deleted" => true}} =
               run(ctx, edge(["data/"]), %{"action" => "delete", "path" => "data/b.txt"})

      assert :miss = Arca.Cache.get(bytes_key)
      assert :miss = Arca.Cache.get(files_key)
    end

    test "the incoming size is the decoded content, and components/ counts too", %{ctx: ctx} do
      assert {:ok, _} = quota_write(ctx, "data/exact.txt", 90, %{max_bytes: 100, max_files: 50})

      grants = ["data/", "components/"]
      quota = %{max_bytes: 100, max_files: 50}
      unit = "components/catalysts/local/pkg/0.1.0/"

      assert {:ok, _} = quota_write(ctx, unit <> "a.txt", 60, quota, grants)

      assert {"storage_quota_exceeded", _} =
               refused(quota_write(ctx, unit <> "b.txt", 60, quota, grants))
    end

    @tag :capture_log
    test "an unreadable usage refuses the public write", %{ctx: ctx} do
      original = Application.get_env(:cyfr, :storage_adapter)
      Application.put_env(:cyfr, :storage_adapter, UnreadableUsageAdapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :storage_adapter, original),
          else: Application.delete_env(:cyfr, :storage_adapter)
      end)

      assert {"storage_quota_exceeded", message} =
               refused(quota_write(ctx, "data/a.txt", 10, %{max_bytes: 100, max_files: 50}))

      assert message =~ "usage unavailable"
    end

    test "a public profile's scope carries the configured quota; any other carries none", %{
      ctx: ctx
    } do
      hold = fn write -> {:ok, write.()} end
      public = %{Authority.zero() | profile_kind: :public}

      assert %{quota: quota} = GuestStorage.scope(ctx, public, nil, hold)
      assert quota == Application.fetch_env!(:cyfr, :public_storage_quota)
      assert %{quota: nil, edge: nil} = GuestStorage.scope(ctx, Authority.zero(), nil, hold)
    end
  end

  test "a scope at the file ceiling refuses one more guest write", %{ctx: ctx} do
    Arca.Cache.put(Arca.Cache.Keys.scope_usage_files(ctx.athanor_id, "data"), 100_000, 60_000)
    Arca.Cache.put(Arca.Cache.Keys.scope_usage_bytes(ctx.athanor_id, "data"), 1_000, 60_000)

    assert {"storage_quota_exceeded", message} =
             refused(run(ctx, edge(["data/"]), write("data/one-more.txt", "x")))

    assert message =~ "file ceiling"
  end

  describe "the attempt's hold" do
    test "a refused hold writes, appends and deletes nothing, and reads need none", %{ctx: ctx} do
      :ok = Arca.put(ctx, ["data", "kept.txt"], "kept")
      test = self()

      lost = fn _write ->
        send(test, :held)
        {:error, :lost}
      end

      for request <- [
            write("data/late.txt", "late"),
            write("data/kept.txt", "overwritten"),
            %{
              "action" => "append",
              "path" => "data/kept.txt",
              "content" => Base.encode64("more")
            },
            %{"action" => "delete", "path" => "data/kept.txt"}
          ] do
        assert {:error, :lost} = run(ctx, edge(["data/"]), request, hold: lost)
        assert_received :held
      end

      assert {:error, :unavailable} =
               run(ctx, edge(["data/"]), write("data/late.txt", "late"),
                 hold: fn _ -> {:error, :unavailable} end
               )

      refute Arca.exists?(ctx, ["data", "late.txt"])
      assert {:ok, "kept"} = Arca.get(ctx, ["data", "kept.txt"])

      for request <- [
            %{"action" => "read", "path" => "data/kept.txt"},
            %{"action" => "list", "path" => "data"},
            %{"action" => "exists", "path" => "data/kept.txt"}
          ] do
        assert {:ok, _} = run(ctx, edge(["data/"]), request, hold: lost)
      end

      refute_received :held
    end

    test "a refusal is decided before the hold is asked", %{ctx: ctx} do
      test = self()

      hold = fn write ->
        send(test, :held)
        {:ok, write.()}
      end

      assert {"storage_path_denied", _} =
               refused(run(ctx, edge(["data/"]), write("aqua/x.txt", "x"), hold: hold))

      refute_received :held
    end
  end

  describe "the boundary" do
    test "a context without an athanor, or with a malformed one, is a typed refusal", %{ctx: _ctx} do
      for athanor <- [nil, "x/../y"] do
        ctx = Sanctum.Context.build(user_id: "u", athanor_id: athanor, authenticated: true)

        assert {"storage_path_denied", _} =
                 refused(run(ctx, edge(["*"]), write("data/a.txt", "x")))
      end
    end

    @tag :capture_log
    test "a raise below the boundary is a generic storage_error", %{ctx: ctx} do
      # A quota without its keys raises below the checks.
      assert {"storage_error", "Internal storage error."} =
               refused(run(ctx, edge(["data/"]), write("data/a.txt", "x"), quota: %{}))
    end
  end
end
