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
      ~w(CYFR_DATABASE CYFR_DATABASE_URL CYFR_CLUSTER_DATABASE_URL CYFR_TEST_RUN_ROOT MIX_TEST_PARTITION MIX_BUILD_PATH)

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

  defp record(failures), do: :erlang.term_to_binary({1, failures})
  defp read_record(path), do: path |> File.read!() |> :erlang.binary_to_term()

  # A run directory seeded from the canonical record of checkout `root`,
  # and the record each of its partitions ends with: a map, `:all`, `:seed`
  # (it never reached its suite's end) or `:missing`.
  defp partition_run(root, name, count, ends) do
    run = Path.join(root, name)
    File.mkdir_p!(run)
    Env.failures_seed!(run, count, root)

    for {partition, final} <- ends do
      file = Path.join([run, "p#{partition}", "failures"])

      case final do
        :seed -> :ok
        :missing -> File.rm!(file)
        :all -> File.write!(file, :erlang.term_to_binary({1, :all}))
        %{} = failures -> File.write!(file, record(failures))
      end
    end

    run
  end

  @a {ATest, :"test a"}
  @b {BTest, :"test b"}
  @c {CTest, :"test c"}

  test "the seed copies the canonical record to the base and every partition", %{root: root} do
    canonical = Path.join(root, "_build/test/test_failures")
    run = Path.join(root, "run")
    File.mkdir_p!(run)
    Env.failures_seed!(run, 2, root)
    # No canonical record yet: every copy is the empty record.
    for file <- ["base", "p1/failures", "p2/failures"] do
      assert read_record(Path.join(run, file)) == {1, %{}}
    end

    File.write!(canonical, record(%{@a => "/a_test.exs"}))
    Env.failures_seed!(run, 2, root)

    for file <- ["base", "p1/failures", "p2/failures"] do
      assert File.read!(Path.join(run, file)) == File.read!(canonical)
    end

    System.put_env("MIX_BUILD_PATH", "_build/test_pg")
    assert Env.canonical_failures(root) == Path.join(root, "_build/test_pg/test_failures")
  end

  test "the merge unites the partitions' new failures and removes what passed", %{root: root} do
    canonical = Path.join(root, "_build/test/test_failures")
    run = partition_run(root, "union", 2, [{1, %{@a => "/a"}}, {2, %{@b => "/b"}}])
    Env.failures_merge!(run, [1, 2], root)
    assert read_record(canonical) == {1, %{@a => "/a", @b => "/b"}}

    # A passed in partition 1; B failed again in partition 2, which held it.
    run = partition_run(root, "removal", 2, [{1, %{@b => "/b"}}, {2, %{@a => "/a", @b => "/b"}}])
    Env.failures_merge!(run, [1, 2], root)
    assert read_record(canonical) == {1, %{@b => "/b"}}
  end

  test "a partition that never finished, or left no record, contributes nothing", %{root: root} do
    canonical = Path.join(root, "_build/test")
    File.mkdir_p!(canonical)
    canonical = Path.join(canonical, "test_failures")
    File.write!(canonical, record(%{@a => "/a", @b => "/b"}))
    run = partition_run(root, "partial", 3, [{1, :seed}, {2, :missing}, {3, %{@a => "/a"}}])
    Env.failures_merge!(run, [1, 2, 3], root)
    # Partition 3 passed B; 1 and 2 say nothing of A or B.
    assert read_record(canonical) == {1, %{@a => "/a"}}
    # A partition the runner did not start is not read at all.
    run = partition_run(root, "unstarted", 2, [{1, %{@a => "/a", @c => "/c"}}, {2, %{}}])
    Env.failures_merge!(run, [1], root)
    assert read_record(canonical) == {1, %{@a => "/a", @c => "/c"}}
  end

  test "an :all on either side", %{root: root} do
    canonical = Path.join(root, "_build/test/test_failures")
    run = partition_run(root, "partition-all", 2, [{1, :all}, {2, %{@a => "/a"}}])
    Env.failures_merge!(run, [1, 2], root)
    assert read_record(canonical) == {1, :all}

    # A base of :all: the union of what the partitions recorded.
    run = partition_run(root, "base-all", 2, [{1, %{@b => "/b"}}, {2, %{@c => "/c"}}])
    Env.failures_merge!(run, [1, 2], root)
    assert read_record(canonical) == {1, %{@b => "/b", @c => "/c"}}

    # ...unless a partition never finished and still holds the seed's :all.
    File.write!(canonical, :erlang.term_to_binary({1, :all}))
    run = partition_run(root, "base-all-partial", 2, [{1, %{@b => "/b"}}, {2, :seed}])
    Env.failures_merge!(run, [1, 2], root)
    assert read_record(canonical) == {1, :all}
  end

  test "two merges in a row each keep the other's result", %{root: root} do
    canonical = Path.join(root, "_build/test/test_failures")
    File.mkdir_p!(Path.dirname(canonical))
    File.write!(canonical, record(%{@a => "/a", @b => "/b"}))
    # Two runs seeded from the same record, ending in either order.
    first = partition_run(root, "first", 1, [{1, %{@b => "/b", @c => "/c"}}])
    second = partition_run(root, "second", 1, [{1, %{@a => "/a"}}])
    Env.failures_merge!(first, [1], root)
    assert read_record(canonical) == {1, %{@b => "/b", @c => "/c"}}
    Env.failures_merge!(second, [1], root)
    assert read_record(canonical) == {1, %{@c => "/c"}}
  end

  test "a merge waits for the lock another holder has", %{root: root} do
    canonical = Path.join(root, "_build/test/test_failures")
    run = partition_run(root, "locked", 1, [{1, %{@a => "/a"}}])
    flock = System.find_executable("flock")

    holder =
      Port.open({:spawn_executable, flock}, [
        :binary,
        :exit_status,
        args: [canonical <> ".lock", "sh", "-c", "echo held; exec sleep 2"]
      ])

    assert_receive {^holder, {:data, "held\n"}}, 5_000
    {usec, :ok} = :timer.tc(fn -> Env.failures_merge!(run, [1], root) end)
    assert usec > 1_000_000
    assert_receive {^holder, {:exit_status, 0}}, 5_000
    assert read_record(canonical) == {1, %{@a => "/a"}}
  end

  test "the weights table's grammar", %{root: root} do
    table = Path.join(root, "weights.tsv")
    File.write!(table, "# comment\n12.5\tapps/a/test/a_test.exs\n3\tapps/b/test/b_test.exs\n")

    assert Env.weights!(table, true) == %{
             "apps/a/test/a_test.exs" => 12.5,
             "apps/b/test/b_test.exs" => 3.0
           }

    # Only the default table's absence means equal weights.
    assert Env.weights!(Path.join(root, "absent.tsv"), false) == %{}
    assert_raise Env.Refusal, fn -> Env.weights!(Path.join(root, "absent.tsv"), true) end
    assert_raise Env.Refusal, fn -> Env.weights!(root, false) end

    for bad <- ["12.5 apps/a_test.exs", "x\tapps/a_test.exs", "1\t", "", "1\ta\tb", "-1\ta"] do
      File.write!(table, "1\tok_test.exs\n#{bad}\n")
      assert_raise Env.Refusal, ~r/line 2/, fn -> Env.weights!(table, false) end
    end
  end

  test "the split: largest first, to the lightest partition, ties to the lower number" do
    assert Env.median(%{}) == 1.0
    assert Env.median(%{"a" => 1.0, "b" => 5.0, "c" => 3.0}) == 3.0
    assert Env.median(%{"a" => 1.0, "b" => 5.0}) == 3.0

    units = [{"a", 1.0}, {"b", 9.0}, {"c", 4.0}, {"d", 4.0}, {"e", 2.0}]
    assert Env.split(units, 2) == [["b", "a"], ["c", "d", "e"]]
    assert Env.split(Enum.reverse(units), 2) == Env.split(units, 2)
    # Equal weights fill the partitions in turn.
    assert Env.split([{"x", 1.0}, {"y", 1.0}, {"z", 1.0}], 2) == [["x", "z"], ["y"]]
    assert Env.split([{"x", 1.0}], 3) == [["x"], [], []]
  end
end
