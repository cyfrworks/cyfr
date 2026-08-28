# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderClient do
  @moduledoc """
  The server half of the build-isolation seam: when the operator sets
  `CYFR_BUILDER_URL`, `build.compile` POSTs the source map to the builder
  container (`Locus.BuilderService`) instead of running toolchains in
  this image. Unset, builds run in-process — `Locus.Builder` states that
  posture's threat model honestly.

  The result mirrors `Locus.Builder.compile/3`'s shape exactly, so the
  caller cannot tell which path built the artifact. Progress cannot
  stream over one POST; the builder's log lines are replayed into
  `on_progress` at completion.
  """

  require Logger

  # A build is minutes; the builder's own compile deadline governs — this
  # is the client-side slack above it.
  @receive_timeout_ms :timer.minutes(12)
  @max_response_bytes 100_000_000

  @doc "Whether the operator pointed builds at a builder container."
  @spec enabled?() :: boolean()
  def enabled? do
    is_binary(url()) and url() != ""
  end

  @doc "Compile via the builder service. Same result shape as `Locus.Builder.compile/3`."
  @spec compile(map(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def compile(source_files, language, opts) do
    target_type = Keyword.fetch!(opts, :target_type)
    on_progress = Keyword.get(opts, :on_progress, fn _stage, _msg -> :ok end)

    body = %{
      "source_files" =>
        Map.new(source_files, fn {path, content} -> {path, Base.encode64(content)} end),
      "language" => Atom.to_string(language),
      "target_type" => Atom.to_string(target_type)
    }

    on_progress.(:compiling, "Building in the builder container…")

    request = [
      method: :post,
      url: url() <> "/build",
      json: body,
      headers: [{"authorization", "Bearer " <> (token() || "")}],
      receive_timeout: @receive_timeout_ms,
      max_retries: 0,
      compressed: false,
      decode_body: false,
      # The ceiling streams: a misbehaving builder cannot flood this node's
      # heap before a post-hoc size check would run. `Cyfr.Network`'s
      # collector is pure and compiled into the builder release too.
      into: Cyfr.Network.bounded_collector(@max_response_bytes)
    ]

    case Req.request(request) do
      {:ok, %Req.Response{status: status} = resp} ->
        case Cyfr.Network.collected_body(resp, @max_response_bytes) do
          {:ok, raw} ->
            handle_response(status, decode_json_body(raw), on_progress)

          {:error, {:response_too_large, size, max}} ->
            Logger.error(
              "[Locus.BuilderClient] builder response exceeded #{max} bytes (#{size} seen) — aborted"
            )

            {:error, :builder_response_too_large}
        end

      {:error, reason} ->
        Logger.error("[Locus.BuilderClient] builder unreachable: #{inspect(reason)}")
        {:error, :builder_unreachable}
    end
  end

  defp handle_response(200, %{"ok" => true} = built, on_progress) do
    replay_logs(built, on_progress)
    decode_result(built)
  end

  defp handle_response(422, %{"error" => error} = built, on_progress) do
    replay_logs(built, on_progress)
    {:error, {:builder_failed, error}}
  end

  defp handle_response(401, _body, _on_progress), do: {:error, :builder_unauthorized}

  defp handle_response(status, _body, _on_progress),
    do: {:error, {:builder_unexpected_status, status}}

  defp decode_json_body(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc """
  The builder's answer, checked rather than believed.

  The container is a separate trust domain: everything below is input. The
  in-process path validates the bytes it produced and derives the digest,
  size and exports from that validation (`Locus.Builder.do_compile/5`), so
  this path does the same instead of copying the claim — otherwise a
  compromised or simply buggy builder names the digest a component is
  registered under. Output paths are held to `Cyfr.PathSafety` on the way
  OUT for the same reason they are on the way in: they become
  `Path.split/1` segments of a version directory, and Arca does not itself
  refuse a `..`.
  """
  @spec decode_result(map()) :: {:ok, map()} | {:error, term()}
  def decode_result(%{"wasm_base64" => b64} = built) when is_binary(b64) do
    with {:ok, bytes} <- decode64(b64, "wasm_base64"),
         {:ok, validation} <- validate_wasm(bytes) do
      {:ok,
       %{
         wasm_bytes: bytes,
         digest: validation.digest,
         size: validation.size,
         exports: validation.exports,
         language: built["language"],
         target_type: built["target_type"]
       }}
    end
  end

  def decode_result(%{"output_files" => files} = built) when is_map(files) do
    with {:ok, decoded} <- decode_output_files(files) do
      {:ok,
       %{
         output_files: decoded,
         digest: built["digest"],
         size: built["size"],
         exports: built["exports"] || [],
         language: built["language"],
         target_type: built["target_type"]
       }}
    end
  end

  def decode_result(built),
    do: {:error, {:builder_malformed_result, Map.keys(built)}}

  defp decode_output_files(files) do
    Enum.reduce_while(files, {:ok, %{}}, fn {path, b64}, {:ok, acc} ->
      with :ok <- safe_path(path),
           {:ok, content} <- decode64(b64, path) do
        {:cont, {:ok, Map.put(acc, path, content)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp safe_path(path) when is_binary(path) do
    case Cyfr.PathSafety.validate_relative_path(path) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:builder_unsafe_path, path, reason}}
    end
  end

  defp safe_path(path), do: {:error, {:builder_unsafe_path, path, :not_a_string}}

  defp decode64(b64, where) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:builder_invalid_base64, where}}
    end
  end

  defp decode64(_b64, where), do: {:error, {:builder_invalid_base64, where}}

  defp validate_wasm(bytes) do
    case Compendium.WasmValidator.validate(bytes) do
      {:ok, validation} -> {:ok, validation}
      {:error, reason} -> {:error, {:builder_invalid_wasm, reason}}
    end
  end

  defp replay_logs(%{"logs" => logs}, on_progress) when is_list(logs) do
    Enum.each(logs, fn line -> on_progress.(:output, to_string(line)) end)
  end

  defp replay_logs(_built, _on_progress), do: :ok

  @doc false
  def max_response_bytes, do: @max_response_bytes

  defp url, do: Application.get_env(:cyfr, :builder_url)
  defp token, do: Application.get_env(:cyfr, :builder_token)
end
