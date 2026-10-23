# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TestPartitionEnv do
  @moduledoc false

  defmodule Refusal do
    @moduledoc false
    defexception [:message]
  end

  def database_url!(url, checkout, run, partition) do
    uri = URI.parse(url)

    unless uri.scheme in ["postgres", "postgresql"] and is_binary(uri.host) and
             uri.host != "" and is_binary(uri.path) and uri.path not in ["", "/"] and
             is_nil(uri.fragment) and not Regex.match?(~r/[\s\x00-\x1f\x7f]/u, url) and
             not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, url) do
      raise ArgumentError, "invalid test database URL"
    end

    if uri.query &&
         Enum.any?(URI.query_decoder(uri.query), fn {key, _} -> key in ["database", "url"] end) do
      raise ArgumentError, "database overrides are not permitted in a test connection URL"
    end

    name = URI.decode(String.trim_leading(uri.path, "/"))

    if String.contains?(name, ["/", "\0"]) or name == "" do
      raise ArgumentError, "invalid test database name"
    end

    # Only the database path changes. ASCII identifiers avoid PostgreSQL's
    # byte truncation and quoting ambiguities, even for escaped source names.
    prefix = name |> String.replace(~r/[^a-zA-Z0-9_]/, "_") |> String.slice(0, 16)
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({checkout, run, partition}))
    suffix = digest |> Base.encode16(case: :lower) |> binary_part(0, 32)
    database = "#{prefix}_#{suffix}_p#{partition}"

    if byte_size(database) > 63 or database == name do
      raise ArgumentError, "invalid partition database identity"
    end

    URI.to_string(%{uri | path: "/" <> database})
  end

  def prepare!(directory, checkout, count, adapter, cluster?) do
    base =
      if cluster?,
        do: nonempty_env("CYFR_CLUSTER_DATABASE_URL") || nonempty_env("CYFR_DATABASE_URL"),
        else: nonempty_env("CYFR_DATABASE_URL")

    base = base || "postgres://cyfr:cyfr@localhost:5432/cyfr_test"

    for partition <- 1..count do
      root = Path.join(directory, "p#{partition}")
      tmp = Path.join(root, "tmp")
      File.mkdir_p!(tmp)

      vars = [
        {"MIX_TEST_PARTITION", to_string(partition)},
        {"CYFR_TEST_RUN_ROOT", root},
        {"TMPDIR", tmp},
        {"TMP", tmp},
        {"TEMP", tmp}
      ]

      vars =
        if adapter == "postgres" do
          url = database_url!(base, Path.expand(checkout), directory, partition)

          File.write!(
            Path.join(root, "database-name"),
            URI.parse(url).path |> String.trim_leading("/")
          )

          vars ++ [{"CYFR_DATABASE_URL", url}, {"CYFR_CLUSTER_DATABASE_URL", url}]
        else
          vars
        end

      shell =
        Enum.map_join(vars, "\n", fn {key, value} -> "export #{key}=#{quote_shell(value)}" end)

      File.write!(Path.join(directory, "p#{partition}.env"), shell <> "\n")
    end
  end

  def storage!(action) when action in ["create", "drop"] do
    root = System.fetch_env!("CYFR_TEST_RUN_ROOT")
    expected = root |> Path.join("database-name") |> File.read!()
    url = System.fetch_env!("CYFR_DATABASE_URL")
    repo = Module.concat(["Arca", "Repo"])
    config = repo.config()
    receipt = Path.join(root, "database-created")
    pending = Path.join(root, "database-create-pending")

    unless URI.parse(url).path == "/" <> expected and config[:database] == expected and
             Regex.match?(~r/\A[a-zA-Z0-9_]+_[a-f0-9]{32}_p[0-9]+\z/, expected) do
      raise "partition database ownership mismatch"
    end

    adapter = repo.__adapter__()

    case action do
      "create" ->
        # :already_up is a refusal: never adopt or drop someone else's DB.
        # CREATE DATABASE cannot commit atomically with a filesystem receipt.
        # A killed creator leaves an explicit uncertain result for inspection;
        # cleanup never guesses that an unreceipted database belongs to us.
        File.write!(pending, expected)

        case adapter.storage_up(config) do
          :ok ->
            File.rename!(pending, receipt)

          {:error, :already_up} ->
            File.rm!(pending)
            raise "partition database already exists; it was not adopted"

          _ ->
            raise "partition database creation has an uncertain outcome"
        end

      "drop" ->
        unless File.read!(receipt) == expected, do: raise("partition database receipt mismatch")

        case adapter.storage_down(Keyword.put(config, :force_drop, true)) do
          :ok -> File.rm!(receipt)
          {:error, :already_down} -> File.rm!(receipt)
          _ -> raise "partition database cleanup failed"
        end
    end
  end

  # The failures record (what `mix test --failed` reruns) is Mix's term,
  # `{1, %{{module, name} => file}}` or `{1, :all}`. Each partition records
  # into its own copy of the canonical one, and the run folds each copy's
  # change back into the canonical record as it stands then, so two runs
  # that end in either order each keep the other's result. The runner holds
  # the record's lock, `flock <canonical>.lock`, around this VM, so a
  # stopped seed or merge takes its lock holder with it.
  @record_version 1

  def canonical_failures(checkout) do
    Path.join(
      Path.expand(System.get_env("MIX_BUILD_PATH") || "_build/test", checkout),
      "test_failures"
    )
  end

  def failures_seed!(directory, count, checkout) do
    canonical = canonical_failures(checkout)

    binary =
      case File.read(canonical) do
        {:ok, binary} -> binary
        {:error, :enoent} -> :erlang.term_to_binary({@record_version, %{}})
      end

    File.write!(Path.join(directory, "base"), binary)
    # A record of :all reruns the whole suite: the runner then drops
    # --failed, which Mix, reading the record per application in one VM,
    # would apply to the first application's files alone.
    if decode_record(binary) == :all, do: File.write!(Path.join(directory, "base-all"), "")

    for partition <- 1..count//1 do
      root = Path.join(directory, "p#{partition}")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "failures"), binary)
    end

    :ok
  end

  # `reason` is why the run was not every file of the suite to its end, or
  # nil when it was: the runner's one definition (scripts/test-partitioned.sh).
  def failures_merge!(directory, started, reason, checkout) do
    canonical = canonical_failures(checkout)

    seed = File.read(Path.join(directory, "base"))

    parts =
      for partition <- started do
        case File.read(Path.join([directory, "p#{partition}", "failures"])) do
          # Never reached its suite's end, or recorded nothing new.
          ^seed -> :unchanged
          {:ok, binary} -> decode_record(binary) || :none
          {:error, _} -> :none
        end
      end

    base =
      case seed do
        {:ok, binary} -> decode_record(binary) || %{}
        {:error, _} -> %{}
      end

    current =
      case File.read(canonical) do
        {:ok, binary} -> decode_record(binary) || %{}
        {:error, :enoent} -> %{}
      end

    result = merge_records(current, base, parts, reason == nil)

    if base == :all and reason != nil do
      IO.puts(
        "==> the failures record stays :all, the whole suite's rerun still owed: this run had #{reason}"
      )
    end

    File.mkdir_p!(Path.dirname(canonical))
    partial = canonical <> ".partial"
    File.write!(partial, :erlang.term_to_binary({@record_version, result}))
    File.rename!(partial, canonical)

    :ok
  end

  # `canonical := (current − (base − p)) ∪ (p − base)` for each partition's
  # record p. A partition still holding the seed, or holding nothing,
  # leaves its part of the record as it was, so under a seed of `:all` the
  # record stays `:all` until every started partition has written its own.
  # A seed of `:all` owes a rerun of the whole suite, so only a run of every
  # file of it to its end (`whole?`) replaces it: what any other run, such
  # as one shard's, did not run is still owed, and the record stays `:all`.
  def merge_records(current, base, parts, whole?) do
    cond do
      :all in parts -> :all
      base == :all and (:unchanged in parts or not whole?) -> :all
      base == :all -> Enum.reduce(parts, %{}, &union_part/2)
      current == :all -> :all
      true -> Enum.reduce(parts, current, &apply_part(&1, &2, base))
    end
  end

  defp union_part(%{} = part, acc), do: Map.merge(acc, part)
  defp union_part(_, acc), do: acc

  defp apply_part(%{} = part, current, base) do
    passed = Enum.reject(Map.keys(base), &Map.has_key?(part, &1))
    failed = Map.filter(part, fn {id, file} -> Map.get(base, id) != file end)
    current |> Map.drop(passed) |> Map.merge(failed)
  end

  defp apply_part(_, current, _base), do: current

  def decode_record(binary) do
    case :erlang.binary_to_term(binary) do
      {@record_version, :all} -> :all
      {@record_version, %{} = failures} -> failures
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # The weights table: `<seconds>\t<path>` lines and `#` comments, the path
  # as `scripts/test-timings.exs weights` prints it. Only an absent default
  # table means equal weights; anything else that is not the grammar is
  # refused.
  def weights!(path, required?) do
    case File.read(path) do
      {:ok, text} ->
        text
        |> String.split("\n")
        |> then(fn lines -> if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines end)
        |> Enum.with_index(1)
        |> Enum.reduce(%{}, fn {line, number}, acc ->
          cond do
            String.starts_with?(line, "#") ->
              acc

            match = Regex.run(~r/\A([0-9]+(?:\.[0-9]+)?)\t([^\t]+)\z/, line) ->
              [_, seconds, file] = match
              {weight, ""} = Float.parse(seconds)
              Map.put(acc, file, weight)

            true ->
              raise Refusal, "the weights table #{path} line #{number} is not <seconds>\\t<path>"
          end
        end)

      {:error, :enoent} when not required? ->
        %{}

      {:error, reason} ->
        raise Refusal, "the weights table #{path} cannot be read: #{:file.format_error(reason)}"
    end
  end

  def median(weights) do
    case weights |> Map.values() |> Enum.sort() do
      [] ->
        1.0

      sorted ->
        n = length(sorted)
        middle = div(n, 2)

        if rem(n, 2) == 1,
          do: Enum.at(sorted, middle),
          else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end

  # Largest first, ties by path, each to the partition with the smallest
  # running total, ties to the lower number.
  def split(units, count) do
    units
    |> Enum.sort_by(fn {unit, weight} -> {-weight, unit} end)
    |> Enum.reduce(List.duplicate({0.0, []}, count), fn {unit, weight}, partitions ->
      {_, index} =
        partitions
        |> Enum.with_index()
        |> Enum.min_by(fn {{total, _}, index} -> {total, index} end)

      List.update_at(partitions, index, fn {total, assigned} ->
        {total + weight, [unit | assigned]}
      end)
    end)
    |> Enum.map(fn {_, assigned} -> Enum.reverse(assigned) end)
  end

  # Runs under `mix run --no-start --no-compile`: every application's test
  # files as `mix test` would load them, from its own configuration. A
  # named file, with or without a line, is one unit; a named directory is
  # its test files; no name is the whole suite. Under --failed the record
  # narrows the units before the split, or, for a sharded run
  # (`whole_split?`), each partition of the whole selection's split, so a
  # shard reruns only failures among the files it runs.
  def assign!(directory, count, checkout, table, required?, failed?, whole_split?, names) do
    weights = weights!(table, required?)
    apps = test_apps()

    {units, misnamed, outside} =
      if names == [], do: suite(apps), else: named(apps, names, checkout)

    out = Path.join(directory, "assign")
    File.mkdir_p!(out)

    if misnamed != [] do
      File.write!(Path.join(out, "misnamed"), Enum.join(misnamed, "\n") <> "\n")
      warn_misnamed(misnamed)
    end

    # Mix silently runs nothing for a path under no application.
    if outside != [] do
      File.write!(Path.join(out, "outside"), Enum.join(outside, "\n") <> "\n")
      System.halt(4)
    end

    if units == [], do: System.halt(2)

    # The files the failures record names, or nil when every unit runs.
    recorded =
      if failed? do
        case Path.join(directory, "base") |> File.read() |> elem(1) |> decode_record() do
          :all ->
            nil

          failures ->
            MapSet.new(Map.values(failures || %{}), &Path.relative_to(&1, checkout))
        end
      end

    default = median(weights)
    file_of = Map.new(units)
    recorded? = fn unit -> MapSet.member?(recorded, Map.fetch!(file_of, unit)) end

    weighed = fn units ->
      Enum.map(units, fn {unit, file} -> {unit, Map.get(weights, file, default)} end)
    end

    partitions =
      cond do
        recorded == nil ->
          units |> weighed.() |> split(count)

        whole_split? ->
          units |> weighed.() |> split(count) |> Enum.map(&Enum.filter(&1, recorded?))

        true ->
          units |> Enum.filter(fn {unit, _} -> recorded?.(unit) end) |> weighed.() |> split(count)
      end

    if Enum.all?(partitions, &(&1 == [])), do: System.halt(3)

    partitions
    |> Enum.with_index(1)
    |> Enum.each(fn {assigned, partition} ->
      File.write!(Path.join(out, "p#{partition}"), Enum.map(assigned, &[&1, 0]))
    end)
  end

  defp test_apps do
    case Mix.Project.apps_paths() do
      nil ->
        [{".", Mix.Project.config()}]

      paths ->
        for {app, path} <- Enum.sort_by(paths, &elem(&1, 1)) do
          {path, Mix.Project.in_project(app, path, fn _ -> Mix.Project.config() end)}
        end
    end
  end

  defp suite(apps) do
    apps
    |> Enum.map(fn {path, config} ->
      test_paths = config[:test_paths] || default_test_paths(path)
      classify(path, config, Enum.flat_map(test_paths, &wildcard(path, &1, config)))
    end)
    |> Enum.reduce({[], [], []}, fn {load, warn}, {units, misnamed, outside} ->
      {units ++ Enum.map(load, &{&1, &1}), misnamed ++ warn, outside}
    end)
  end

  defp named(apps, names, checkout) do
    {units, misnamed, outside} =
      Enum.reduce(names, {[], [], []}, fn name, {units, misnamed, outside} ->
        # The `:line` suffixes come off the name as given: `./`, absolute
        # and `..` spellings name the same file as its relative one.
        [file, suffix] = Regex.run(~r/\A(.*?)((?::[0-9]+)*)\z/s, name, capture: :all_but_first)
        relative = file |> Path.expand(checkout) |> Path.relative_to(checkout)

        case Enum.find(apps, fn {path, _} -> owns?(path, relative) end) do
          nil ->
            {units, misnamed, outside ++ [name]}

          {path, config} ->
            app_relative = if path == ".", do: relative, else: Path.relative_to(relative, path)

            case File.stat(relative) do
              {:ok, %{type: :directory}} ->
                {load, warn} = classify(path, config, wildcard(path, app_relative, config))
                {units ++ Enum.map(load, &{&1, &1}), misnamed ++ warn, outside}

              # A named file runs whatever its name, as Mix runs it.
              {:ok, _} ->
                {units ++ [{relative <> suffix, relative}], misnamed, outside}

              _ ->
                {units, misnamed, outside ++ [name]}
            end
        end
      end)

    {Enum.uniq(units), Enum.uniq(misnamed), outside}
  end

  defp owns?(".", relative), do: not String.starts_with?(relative, "../")
  defp owns?(path, relative), do: String.starts_with?(relative, path <> "/")

  defp default_test_paths(path) do
    if File.dir?(Path.join(path, "test")), do: ["test"], else: []
  end

  # App-relative spellings, as Mix sees them from the application's root;
  # Path.wildcard skips dot-entries as Mix's does.
  defp wildcard(path, test_path, config) do
    pattern = config[:test_pattern] || "*.{ex,exs}"

    File.cd!(path, fn -> Path.wildcard("#{test_path}/**/#{pattern}") end)
  end

  # Mix's own classification: the load filters first, then the ignore
  # filters with Mix's implicit `_helper.exs` and `elixirc_paths` ones.
  defp classify(path, config, files) do
    load_filters = config[:test_load_filters] || [&String.ends_with?(&1, "_test.exs")]
    elixirc_paths = config[:elixirc_paths] || []

    ignore_filters =
      [
        &String.ends_with?(&1, "_helper.exs"),
        fn file -> Enum.any?(elixirc_paths, &String.starts_with?(file, &1)) end
      ] ++ Keyword.get(config, :test_ignore_filters, [])

    files = Enum.uniq(files)
    prefix = fn file -> if path == ".", do: file, else: Path.join(path, file) end

    {Enum.filter(files, &matches?(&1, load_filters)) |> Enum.map(prefix),
     Enum.reject(files, &(matches?(&1, load_filters) or matches?(&1, ignore_filters)))
     |> Enum.map(prefix)}
  end

  defp matches?(file, filters) do
    Enum.any?(filters, fn
      %Regex{} = regex -> Regex.match?(regex, file)
      binary when is_binary(binary) -> file == binary
      fun when is_function(fun, 1) -> fun.(file)
    end)
  end

  # Mix's own text (`mix test`), which the runner's warning evidence reads.
  defp warn_misnamed(files) do
    IO.puts("""
    warning: the following files do not match any of the configured \
    `:test_load_filters` / `:test_ignore_filters`:

    #{Enum.join(files, "\n")}

    This might indicate a typo in a test file name (for example, \
    using "foo_tests.exs" instead of "foo_test.exs").

    See the configuration for `:test_pattern` under `mix help test` \
    for more information.
    """)
  end

  defp nonempty_env(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  def main(args) do
    try do
      case args do
        ["prepare", directory, checkout, count, adapter, cluster] ->
          prepare!(directory, checkout, String.to_integer(count), adapter, cluster == "true")

        [action] when action in ["create", "drop"] ->
          storage!(action)

        ["failures-seed", directory, count] ->
          failures_seed!(directory, String.to_integer(count), File.cwd!())

        ["failures-merge", directory, count, reason | started] ->
          count = String.to_integer(count)
          started = Enum.map(started, &String.to_integer/1)
          true = Enum.all?(started, &(&1 in 1..count//1))

          failures_merge!(
            directory,
            started,
            if(reason == "", do: nil, else: reason),
            File.cwd!()
          )

        ["weights", table, required] ->
          weights!(table, required == "true")

        ["assign", directory, count, table, required, failed, whole_split, "--" | names] ->
          assign!(
            directory,
            String.to_integer(count),
            File.cwd!(),
            table,
            required == "true",
            failed == "true",
            whole_split == "true",
            names
          )

        _ ->
          raise ArgumentError, "invalid partition helper arguments"
      end
    rescue
      refusal in Refusal ->
        IO.puts(:stderr, refusal.message)
        System.halt(64)

      _ ->
        # URLs and adapter exception messages can contain credentials.
        IO.puts(:stderr, "test partition environment/storage operation failed")
        System.halt(1)
    end
  end
end

unless System.get_env("CYFR_TEST_PARTITION_ENV_LIBRARY") == "1" do
  Cyfr.TestPartitionEnv.main(System.argv())
end
