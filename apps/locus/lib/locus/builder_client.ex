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
      max_retries: 0
    ]

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true} = built}} ->
        replay_logs(built, on_progress)
        {:ok, decode_result(built)}

      {:ok, %Req.Response{status: 422, body: %{"error" => error} = built}} ->
        replay_logs(built, on_progress)
        {:error, {:builder_failed, error}}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :builder_unauthorized}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:builder_unexpected_status, status}}

      {:error, reason} ->
        Logger.error("[Locus.BuilderClient] builder unreachable: #{inspect(reason)}")
        {:error, :builder_unreachable}
    end
  end

  defp decode_result(%{"wasm_base64" => b64} = built) when is_binary(b64) do
    %{
      wasm_bytes: Base.decode64!(b64),
      digest: built["digest"],
      size: built["size"],
      exports: built["exports"] || [],
      language: built["language"],
      target_type: built["target_type"]
    }
  end

  defp decode_result(%{"output_files" => files} = built) when is_map(files) do
    %{
      output_files: Map.new(files, fn {path, b64} -> {path, Base.decode64!(b64)} end),
      digest: built["digest"],
      size: built["size"],
      exports: built["exports"] || [],
      language: built["language"],
      target_type: built["target_type"]
    }
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
