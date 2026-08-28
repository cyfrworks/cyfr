# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderService do
  @moduledoc """
  The builder container's HTTP face: one authenticated endpoint that runs
  `Locus.Builder.compile/3` and returns the artifact.

  Served only when `:cyfr, :builder_listen` is true — the `builder`
  release sets `CYFR_BUILDER_LISTEN=true`; the app image never listens.
  The client half is `Locus.BuilderClient`, selected by
  `CYFR_BUILDER_URL` on the server node.

  The contract is deliberately small: `POST /build` carries the source
  map (base64 values), the language and the target type; the response
  carries the compiled bytes (or a tincture's output files), the digest,
  and the build log lines. Progress cannot stream over one POST — the
  client replays the returned log lines to its own progress sink at
  completion. Auth is one static bearer (`CYFR_BUILDER_TOKEN`), compared
  constant-time; the compose network is internal-only on top.
  """

  use Plug.Router

  # Sources are validated (and bounded) again by Locus.Builder; this parser
  # cap only has to admit a legal source map with base64 overhead.
  @max_body_bytes 100_000_000

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: @max_body_bytes)
  plug(:dispatch)

  get "/health" do
    send_json(conn, 200, %{ok: true, toolchains: Locus.Builder.available_toolchains()})
  end

  post "/build" do
    with :ok <- check_token(conn),
         {:ok, source_files, language, target_type} <- decode_request(conn.body_params) do
      run_build(conn, source_files, language, target_type)
    else
      {:error, :unauthorized} ->
        send_json(conn, 401, %{ok: false, error: "unauthorized"})

      {:error, message} when is_binary(message) ->
        send_json(conn, 400, %{ok: false, error: message})
    end
  end

  match _ do
    send_json(conn, 404, %{ok: false, error: "not found"})
  end

  defp check_token(conn) do
    expected = Application.get_env(:cyfr, :builder_token)

    with [<<"Bearer ", presented::binary>>] <- get_req_header(conn, "authorization"),
         true <- is_binary(expected) and expected != "",
         true <- Plug.Crypto.secure_compare(presented, expected) do
      :ok
    else
      # No token configured is a refusal too: an unauthenticated builder
      # is a remote code executor.
      _ -> {:error, :unauthorized}
    end
  end

  defp decode_request(%{
         "source_files" => sources,
         "language" => language,
         "target_type" => target_type
       })
       when is_map(sources) and is_binary(language) and is_binary(target_type) do
    with {:ok, language} <- known(language, ~w(rust javascript), "language"),
         {:ok, target_type} <-
           known(target_type, ~w(reagent catalyst formula tincture), "target_type"),
         {:ok, decoded} <- decode_sources(sources) do
      {:ok, decoded, String.to_existing_atom(language), String.to_existing_atom(target_type)}
    end
  end

  defp decode_request(_), do: {:error, "source_files, language and target_type are required"}

  defp known(value, roster, field) do
    if value in roster, do: {:ok, value}, else: {:error, "unknown #{field}: #{value}"}
  end

  defp decode_sources(sources) do
    Enum.reduce_while(sources, {:ok, %{}}, fn
      {path, b64}, {:ok, acc} when is_binary(path) and is_binary(b64) ->
        case Base.decode64(b64) do
          {:ok, content} -> {:cont, {:ok, Map.put(acc, path, content)}}
          :error -> {:halt, {:error, "source #{path} is not valid base64"}}
        end

      {path, _}, _acc ->
        {:halt, {:error, "source #{inspect(path)} is malformed"}}
    end)
  end

  defp run_build(conn, source_files, language, target_type) do
    log = :ets.new(:build_log, [:public])
    counter = :counters.new(1, [])

    on_progress = fn stage, message ->
      :counters.add(counter, 1, 1)
      :ets.insert(log, {:counters.get(counter, 1), "#{stage}: #{message}"})
      :ok
    end

    result =
      Locus.Builder.compile(source_files, language,
        target_type: target_type,
        on_progress: on_progress
      )

    logs =
      log
      |> :ets.tab2list()
      |> Enum.sort()
      |> Enum.map(fn {_i, line} -> line end)

    :ets.delete(log)

    case result do
      {:ok, %{wasm_bytes: wasm_bytes} = built} ->
        send_json(conn, 200, %{
          ok: true,
          wasm_base64: Base.encode64(wasm_bytes),
          digest: built.digest,
          size: built.size,
          exports: built.exports,
          language: built.language,
          target_type: built.target_type,
          logs: logs
        })

      {:ok, %{output_files: files} = built} ->
        send_json(conn, 200, %{
          ok: true,
          output_files: Map.new(files, fn {path, content} -> {path, Base.encode64(content)} end),
          digest: built.digest,
          size: built.size,
          exports: built.exports,
          language: built.language,
          target_type: built.target_type,
          logs: logs
        })

      {:error, reason} ->
        send_json(conn, 422, %{ok: false, error: render_reason(reason), logs: logs})
    end
  end

  defp render_reason({:compilation_failed, exit_code, output}),
    do: "Compilation failed (exit #{exit_code}): #{output}"

  defp render_reason(:compilation_timeout), do: "Compilation timed out"

  defp render_reason({:toolchain_not_found, lang}),
    do: "Toolchain not found in the builder image: #{lang}"

  defp render_reason(reason), do: "Compilation error: #{inspect(reason)}"

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
