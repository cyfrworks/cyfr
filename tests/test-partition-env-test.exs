# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
System.put_env("CYFR_TEST_PARTITION_ENV_LIBRARY", "1")
Code.require_file("../scripts/test-partition-env.exs", __DIR__)
Code.require_file("../config/database_choice.exs", __DIR__)
System.delete_env("CYFR_TEST_PARTITION_ENV_LIBRARY")
ExUnit.start()

defmodule Arca.Repo do
  def config, do: Process.get(:repo_config)
  def __adapter__, do: Cyfr.TestPartitionEnvTest.Adapter
end

defmodule Cyfr.TestPartitionEnvTest do
  use ExUnit.Case, async: false
  alias Cyfr.TestPartitionEnv, as: Env

  defmodule Adapter do
    def storage_up(_), do: Process.get(:create_result, :ok)

    def storage_down(_) do
      send(self(), :dropped)
      Process.get(:drop_result, :ok)
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "partition-env-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    keys =
      ~w(CYFR_DATABASE CYFR_DATABASE_URL CYFR_CLUSTER_DATABASE_URL CYFR_TEST_RUN_ROOT MIX_TEST_PARTITION)

    old = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      File.rm_rf!(root)

      Enum.each(old, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)

    %{root: root}
  end

  test "URI changes only the path, including escaped credentials and connection query" do
    base =
      "postgresql://us%40er:p%27ass%2Fword@[::1]:5433/a%20database?ssl=true&application_name=a%2Fb"

    uri = URI.parse(base)
    derived = Env.database_url!(base, "/checkout", "/run", 2) |> URI.parse()
    assert %{derived | path: uri.path} == uri
    refute derived.path == uri.path
    assert byte_size(String.trim_leading(derived.path, "/")) <= 63
    assert String.ends_with?(derived.path, "_p2")
  end

  test "identity separates runs, checkouts, partitions and remains safe for long names" do
    base = "postgres://u:p@localhost/" <> String.duplicate("%E6%BC%A2", 80)

    urls =
      for {checkout, run, partition} <- [
            {"a", "r", 1},
            {"b", "r", 1},
            {"a", "s", 1},
            {"a", "r", 2}
          ],
          do: Env.database_url!(base, checkout, run, partition)

    assert length(Enum.uniq(urls)) == 4

    for url <- urls do
      name = URI.parse(url).path |> String.trim_leading("/")
      assert byte_size(name) <= 63
      assert name =~ ~r/\A[a-zA-Z0-9_]+\z/
    end
  end

  test "malformed URLs refuse without disclosing their contents" do
    for url <- [
          "secret",
          "http://u:secret@host/db",
          "postgres:///db",
          "postgres://host",
          "postgres://host/",
          "postgres://host/a/b",
          "postgres://host/a%2Fb",
          "postgres://host/%QQ",
          "postgres://bad host/db",
          "postgres://host/db?database=base",
          "postgres://host/db#secret",
          "postgres://host/db\nsecret"
        ] do
      assert_raise ArgumentError, fn -> Env.database_url!(url, "c", "r", 1) end
    end
  end

  test "partition roots and cluster URL agree, with shell-safe secrets", %{root: root} do
    System.put_env("CYFR_DATABASE_URL", "postgres://u:unused@host/base")
    System.put_env("CYFR_CLUSTER_DATABASE_URL", "postgres://u:p'ass@host/cluster?ssl=true")
    Env.prepare!(root, "/checkout", 2, "postgres", true)
    first = File.read!(Path.join(root, "p1.env"))
    second = File.read!(Path.join(root, "p2.env"))
    refute first == second
    assert first =~ "p1/tmp"
    assert second =~ "p2/tmp"
    assert first =~ "p'\\''ass"

    {output, 0} =
      System.cmd("bash", [
        "-c",
        "source \"$1\"; test \"$CYFR_DATABASE_URL\" = \"$CYFR_CLUSTER_DATABASE_URL\"; test -d \"$TMPDIR\"",
        "test",
        Path.join(root, "p1.env")
      ])

    assert output == ""
  end

  test "cleanup requires a successful create receipt and matching actual database", %{root: root} do
    System.put_env("CYFR_DATABASE_URL", "postgres://u:p@host/base")
    Env.prepare!(root, "/checkout", 1, "postgres", false)
    resource = Path.join(root, "p1")
    name = File.read!(Path.join(resource, "database-name"))
    System.put_env("CYFR_TEST_RUN_ROOT", resource)
    System.put_env("CYFR_DATABASE_URL", "postgres://u:p@host/" <> name)
    Process.put(:repo_config, database: name)
    assert_raise File.Error, fn -> Env.storage!("drop") end
    refute_received :dropped
    Process.put(:create_result, {:error, :already_up})
    assert_raise RuntimeError, fn -> Env.storage!("create") end
    refute File.exists?(Path.join(resource, "database-created"))
    refute File.exists?(Path.join(resource, "database-create-pending"))
    Process.put(:create_result, {:error, :connection_lost})
    assert_raise RuntimeError, fn -> Env.storage!("create") end
    assert File.exists?(Path.join(resource, "database-create-pending"))
    refute File.exists?(Path.join(resource, "database-created"))
    assert_raise File.Error, fn -> Env.storage!("drop") end
    refute_received :dropped
    Process.put(:create_result, :ok)
    Env.storage!("create")
    Process.put(:repo_config, database: "base")
    assert_raise RuntimeError, fn -> Env.storage!("drop") end
    refute_received :dropped
    Process.put(:repo_config, database: name)
    Process.put(:drop_result, {:error, :unavailable})
    assert_raise RuntimeError, fn -> Env.storage!("drop") end
    assert File.exists?(Path.join(resource, "database-created"))
    Process.put(:drop_result, :ok)
    Env.storage!("drop")
    refute File.exists?(Path.join(resource, "database-created"))
  end

  test "test config consumes the partition root and keeps the explicit PostgreSQL URL", %{
    root: root
  } do
    System.put_env("CYFR_TEST_RUN_ROOT", root)
    System.put_env("MIX_TEST_PARTITION", "3")
    config_path = Path.expand("../config/test.exs", __DIR__)
    System.put_env("CYFR_DATABASE", "sqlite")
    arca = Config.Reader.read!(config_path, env: :test)[:arca]
    assert arca[Arca.Repo][:database] == Path.join(root, "test.db")
    assert arca[:base_path] == Path.join(root, "data")
    assert arca[:seed_path] == Path.join(root, "seed")
    System.put_env("CYFR_DATABASE", "postgres")
    url = Env.database_url!("postgres://u:p@host/base?ssl=true", "/checkout", root, 3)
    System.put_env("CYFR_DATABASE_URL", url)
    arca = Config.Reader.read!(config_path, env: :test)[:arca]
    assert arca[Arca.Repo][:url] == url
  end

  test "direct config evaluations isolate roots without a runner and include checkout and partition" do
    System.put_env("CYFR_DATABASE", "sqlite")
    System.put_env("MIX_TEST_PARTITION", "7")
    config_path = Path.expand("../config/test.exs", __DIR__)
    first = Config.Reader.read!(config_path, env: :test)[:arca]
    second = Config.Reader.read!(config_path, env: :test)[:arca]
    refute first[:base_path] == second[:base_path]
    refute first[Arca.Repo][:database] == second[Arca.Repo][:database]
    assert first[:base_path] =~ "cyfr_test_#{:erlang.phash2(Path.expand("."))}_"
    assert first[:base_path] =~ "_p7/data"
    assert Path.dirname(first[:base_path]) == Path.dirname(first[Arca.Repo][:database])
  end
end
