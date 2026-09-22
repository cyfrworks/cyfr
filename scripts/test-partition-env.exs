# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TestPartitionEnv do
  @moduledoc false

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

        _ ->
          raise ArgumentError, "invalid partition helper arguments"
      end
    rescue
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
