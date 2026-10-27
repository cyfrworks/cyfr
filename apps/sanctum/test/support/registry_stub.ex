# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.RegistryStub do
  @moduledoc """
  A scripted registry for the suites: plain HTTP on loopback, one request
  per connection, answering `handler.(request)` with `{status, body}`,
  `:hang` (answer nothing) or `:close` (close without answering). Every
  request is told to the test that started it as
  `{:registry_request, %{method:, path:, body:, headers:}}`, the headers
  as their raw lines. Each stub adds its loopback address to the
  operator's private egress targets while it serves.

  `start!/1` points both applications' copies of the registry
  (`:sanctum, :registry_url` and `:cyfr, :registry_url`) at it, so the
  canonical host a request is signed for is `127.0.0.1`, and restores
  them and stops the listener on exit.

  `person!/0` and `enroll!/1` make an enrolled local person whose head
  `state/1` reads back; `verify/2` checks a request as the registry does
  (`Prima.RegistryRequest.verify/4`); `refusal/2` and `answer/1` are the
  registry's envelope and an answer's bytes, by the protocol's own table.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Prima.Identity
  alias Prima.Identity.Entry

  @host "127.0.0.1"
  @directory "https://cyfr.run"

  @doc "The canonical host a request to the stub is signed for."
  def host, do: @host

  @doc "The directory every identity `enroll!/1` makes names."
  def directory, do: @directory

  @doc "Serve `handler` and point the registry at it (the module doc)."
  def start!(handler) when is_function(handler, 1) do
    %{port: port} = serve!(handler)

    previous =
      for {app, key} <- [{:sanctum, :registry_url}, {:cyfr, :registry_url}],
          do: {app, key, Application.fetch_env(app, key)}

    on_exit(fn ->
      for {app, key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    for {app, key, _} <- previous, do: Application.put_env(app, key, "#{@host}:#{port}")
    %{port: port}
  end

  @doc """
  Serve `handler` on a loopback port, stopped on exit, pointing nothing at
  it: for a test that names the host itself, as the OCI gateway's.
  """
  def serve!(handler) when is_function(handler, 1) do
    observer = self()
    loopback!()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    pid = spawn(fn -> accept(listen, handler, observer) end)
    :ok = :gen_tcp.controlling_process(listen, pid)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    %{port: port}
  end

  # The stub's own permission to be reached: its loopback address added to
  # the operator's private egress targets, restored on exit, registered
  # before the change so a test killed at its timeout restores it too. An
  # application's suite that loads no umbrella configuration (the Sanctum
  # island) has no other.
  defp loopback! do
    previous = Application.fetch_env(:sanctum, :private_egress_targets)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sanctum, :private_egress_targets, value)
        :error -> Application.delete_env(:sanctum, :private_egress_targets)
      end
    end)

    targets =
      case previous do
        {:ok, list} when is_list(list) -> list
        _none -> []
      end

    Application.put_env(:sanctum, :private_egress_targets, Enum.uniq(targets ++ [@host]))
  end

  defp accept(listen, handler, observer) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve(socket, handler, observer)
        accept(listen, handler, observer)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, handler, observer) do
    with {:ok, request} <- read(socket, "") do
      send(observer, {:registry_request, request})

      case handler.(request) do
        {status, body} when is_integer(status) and is_binary(body) ->
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} Answer\r\ncontent-type: application/json\r\n" <>
              "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
          )

        :hang ->
          Process.sleep(:infinity)

        :close ->
          :ok
      end
    end

    :gen_tcp.close(socket)
  end

  defp read(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        [line | headers] = String.split(head, "\r\n")
        [method, path | _] = String.split(line, " ")

        length =
          Enum.find_value(headers, 0, fn header ->
            case String.split(header, ":", parts: 2) do
              [name, value] ->
                if String.downcase(name) == "content-length",
                  do: String.to_integer(String.trim(value))

              _ ->
                nil
            end
          end)

        with {:ok, body} <- body(socket, rest, length),
             do: {:ok, %{method: method, path: path, body: body, headers: headers}}

      [_partial] ->
        with {:ok, data} <- :gen_tcp.recv(socket, 0, 5_000), do: read(socket, acc <> data)
    end
  end

  defp body(_socket, acc, length) when byte_size(acc) >= length, do: {:ok, acc}

  defp body(socket, acc, length) do
    with {:ok, data} <- :gen_tcp.recv(socket, 0, 5_000), do: body(socket, acc <> data, length)
  end

  # ---- the person ----------------------------------------------------------------

  @doc "A first admitted sign-in's person, with the key set it mints."
  def person! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: "github|https://github.com|registry#{n}",
        provider: "github",
        email: "registry#{n}@example.com",
        verified: true
      })

    user
  end

  @doc """
  Enroll `user_id` at `directory/0`: their genesis over their own keys,
  opened and accepted, so their identity row holds the identifier and the
  head. Answers the head as the registry would verify it.
  """
  def enroll!(user_id) do
    actor = %Prima.Actor{user_id: user_id}
    row = identity_row(user_id)
    {:ok, {recovery, _}} = Identity.derive_recovery_key(:crypto.strong_rand_bytes(32))

    {:ok, genesis} =
      Entry.genesis(
        live_key: row.live_public_key,
        operational_key: row.operational_public_key,
        recovery_keys: [recovery],
        directory: @directory
      )

    {:ok, attempt} =
      Arca.IdentityAttempts.open(actor, %{
        kind: "enrollment",
        request_id: "req_#{System.unique_integer([:positive])}",
        user_id: user_id,
        identifier: Identity.identifier(genesis),
        directory_url: @directory,
        genesis: Identity.canonical(genesis),
        request_digest: Identity.hash(genesis),
        kit_seed_sealed: "sealed-kit-seed"
      })

    {:ok, _} = Arca.IdentityAttempts.advance(actor, attempt.id, "staged", "submitted")
    {:ok, _} = Arca.IdentityAttempts.advance(actor, attempt.id, "submitted", "accepted")
    state(user_id, genesis.recovery_keys)
  end

  @doc "The verified head of `user_id`'s one-entry log, from their identity row."
  def state(user_id, recovery_keys \\ []) do
    row = identity_row(user_id)

    %Identity.State{
      identifier: row.identifier,
      directory: @directory,
      head: row.head_hash,
      key_epoch: row.head_hash,
      recovery_epoch: row.head_hash,
      live_key: row.live_public_key,
      operational_key: row.operational_public_key,
      recovery_keys: recovery_keys,
      revision: 0,
      length: 1
    }
  end

  defp identity_row(user_id),
    do: Arca.Repo.get_by!(Arca.Schemas.PersonIdentity, user_id: user_id)

  # ---- the wire ------------------------------------------------------------------

  @doc "Check a request's bytes as the registry at `host/0` does, under `state`."
  def verify(bytes, %Identity.State{} = state) do
    Prima.RegistryRequest.verify(
      bytes,
      state,
      %{host: @host, directory: @directory},
      System.os_time(:millisecond)
    )
  end

  @doc """
  The registry's refusal `name` as it answers it: its status and the
  envelope with its code (`Prima.RegistryRequest.refusals/0`), beside any
  `extra` top-level field.
  """
  def refusal(name, extra \\ %{}) do
    {code, status} = Keyword.fetch!(Prima.RegistryRequest.refusals(), name)
    {status, answer(Map.put(extra, "errors", [%{"code" => code, "message" => "refused"}]))}
  end

  @doc "An answer's bytes: JCS, so it carries no null."
  def answer(map), do: Prima.Identity.Encoding.jcs!(map)
end
