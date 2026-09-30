# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.DirectoryController do
  @moduledoc """
  The identity directory's HTTP endpoints (`ARCHITECTURE.md` §9.1) over
  `Sanctum.Directory`, which decides every request; this adapter reads the
  request and writes the answer. No session is read: a log is public
  history, a genesis is its own identifier, and every signed write is
  verified against the identifier's chain.

  ## Routes

    * `POST /directory/v1/genesis` — the genesis entry; answers the
      identifier it hashes to, the same for a repeat.
    * `GET /directory/v1/:identifier?after=N` — one page of the log after
      position `N` (-1, the default, from the genesis).
    * `POST /directory/v1/:identifier/entries` — a signed rotate entry.
    * `POST /directory/v1/:identifier/recover` — a signed recover request,
      which must name the path's identifier.
    * `GET /directory/v1/:identifier/requests/:request_id` — a recovery
      request's recorded outcome.

  A POST's body is the JSON object itself, at most 16 KiB: a larger one is
  refused `413` before it is decoded (`CyfrWeb.Plugs.RawBodyReader`), in
  the endpoint's own error rendering.

  ## Answers

  `200` with `{"identifier", "seq", "entry_hash"}` for an accepted write,
  and `"entry"` too for a recovery; `{"identifier", "from", "entries",
  "next", "head", "length"}` for a page, whose entries are the stored
  canonical entries; `{"identifier", "request_id", "request_digest",
  "outcome"}` for an outcome, with `"seq"`, `"entry_hash"` and `"entry"`
  when it is `"accepted"` and `"recorded"` when it is `"stale_policy"`.

  ## Refusals

  The directory's own JSON, `{"error": code, …}`:

  | Status | `error` | With |
  |---|---|---|
  | 404 | `not_served` | this node serves no directory |
  | 404 | `not_found` | no such identifier or request |
  | 405 | `read_only` | a mirror; `allow: GET` |
  | 409 | `stale_head` | `head`, the current head |
  | 409 | `stale_policy` | `recorded`, the refusal recorded for the request |
  | 409 | `request_id_reused` | the id answered another request |
  | 409 | `conflict` | another genesis under the identifier |
  | 422 | `invalid` | `reason`, and `field` when one is named |
  | 422 | `unverified` | `reason`, why the chain refuses the entry |
  | 422 | `wrong_identifier` | the request names another identifier |
  | 429 | `rate_limited` | `retry_after` seconds, and the header |
  | 500 | `corrupt` | the stored log does not verify |
  | 503 | `capacity` | `exhausted`: `identities` or `log_bytes` with `retry-after: 60`, or `rotations` (the identifier's 100 a day) with the seconds left in its window |
  | 503 | `busy` | a recovery re-based three times; `retry-after: 1` |
  | 503 | `unavailable` | the store or settings did not answer; `retry-after: 1` |
  """

  use Emissary.Web, :controller

  @doc "`POST /directory/v1/genesis`."
  def register(conn, _params),
    do: answer(conn, Sanctum.Directory.register(%{genesis: body(conn), source: source(conn)}))

  @doc "`GET /directory/v1/:identifier`."
  def resolve(conn, _params) do
    case position(conn.query_params) do
      {:ok, after_seq} ->
        answer(
          conn,
          Sanctum.Directory.resolve(%{
            identifier: identifier(conn),
            after: after_seq,
            source: source(conn)
          })
        )

      :error ->
        refuse(conn, {:invalid, {:invalid_field, "after"}})
    end
  end

  @doc "`POST /directory/v1/:identifier/entries`."
  def append(conn, _params) do
    answer(
      conn,
      Sanctum.Directory.append(identifier(conn), %{entry: body(conn), source: source(conn)})
    )
  end

  @doc "`POST /directory/v1/:identifier/recover`."
  def recover(conn, _params) do
    answer(
      conn,
      Sanctum.Directory.recover(identifier(conn), %{request: body(conn), source: source(conn)})
    )
  end

  @doc "`GET /directory/v1/:identifier/requests/:request_id`."
  def outcome(conn, _params) do
    answer(
      conn,
      Sanctum.Directory.outcome(%{
        identifier: identifier(conn),
        request_id: conn.path_params["request_id"],
        source: source(conn)
      })
    )
  end

  # ---- the request ---------------------------------------------------------------

  # The path's identifier, never a body field of the same name: a recover
  # request carries its own `identifier`, which the decision compares.
  defp identifier(conn), do: conn.path_params["identifier"]

  # A body the parsers passed over (a type they do not read) is no body.
  defp body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body(%Plug.Conn{body_params: %{} = params}), do: params
  defp body(_conn), do: %{}

  defp source(conn), do: Sanctum.ClientIp.resolve(conn)

  # A position is -1 or a log position, which the store keeps as a 32-bit
  # integer: anything else is refused here, before any rate claim.
  defp position(%{"after" => text}) when is_binary(text) do
    with true <- Regex.match?(~r/\A-?[0-9]{1,10}\z/, text),
         {value, ""} when value >= -1 and value <= 2_147_483_647 <- Integer.parse(text) do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp position(%{"after" => _other}), do: :error
  defp position(_query), do: {:ok, -1}

  # ---- the answer ----------------------------------------------------------------

  defp answer(conn, {:ok, result}), do: conn |> put_status(200) |> json(wire(result))
  defp answer(conn, {:error, reason}), do: refuse(conn, reason)

  # Stored entries are canonical JSON already, and go out as they are.
  defp wire(%{entries: entries} = page) do
    %{
      "identifier" => page.identifier,
      "from" => page.from,
      "entries" => Enum.map(entries, &Jason.Fragment.new/1),
      "next" => page.next,
      "head" => page.head,
      "length" => page.length
    }
  end

  defp wire(%{outcome: :accepted} = outcome) do
    %{
      "identifier" => outcome.identifier,
      "request_id" => outcome.request_id,
      "request_digest" => outcome.request_digest,
      "outcome" => "accepted",
      "seq" => outcome.seq,
      "entry_hash" => outcome.entry_hash,
      "entry" => Jason.Fragment.new(outcome.entry)
    }
  end

  defp wire(%{outcome: :stale_policy} = outcome) do
    %{
      "identifier" => outcome.identifier,
      "request_id" => outcome.request_id,
      "request_digest" => outcome.request_digest,
      "outcome" => "stale_policy",
      "recorded" => outcome.recorded
    }
  end

  defp wire(%{identifier: identifier, seq: seq, entry_hash: hash} = accepted) do
    base = %{"identifier" => identifier, "seq" => seq, "entry_hash" => hash}

    case accepted do
      %{entry: entry} -> Map.put(base, "entry", Jason.Fragment.new(entry))
      _written -> base
    end
  end

  defp refuse(conn, reason) do
    {status, body, headers} = refusal(reason)

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
    |> put_status(status)
    |> json(body)
  end

  defp refusal(:not_served), do: {404, %{"error" => "not_served"}, []}
  defp refusal(:not_found), do: {404, %{"error" => "not_found"}, []}
  defp refusal(:read_only), do: {405, %{"error" => "read_only"}, [{"allow", "GET"}]}

  defp refusal({:stale_head, head}),
    do: {409, %{"error" => "stale_head", "head" => head}, []}

  defp refusal({:stale_policy, recorded}),
    do: {409, %{"error" => "stale_policy", "recorded" => recorded}, []}

  defp refusal(:request_id_reused), do: {409, %{"error" => "request_id_reused"}, []}
  defp refusal(:conflict), do: {409, %{"error" => "conflict"}, []}

  defp refusal({:invalid, {tag, field}}),
    do: {422, %{"error" => "invalid", "reason" => Atom.to_string(tag), "field" => field}, []}

  defp refusal({:invalid, reason}),
    do: {422, %{"error" => "invalid", "reason" => Atom.to_string(reason)}, []}

  defp refusal({:unverified, reason}),
    do: {422, %{"error" => "unverified", "reason" => Atom.to_string(reason)}, []}

  defp refusal(:wrong_identifier), do: {422, %{"error" => "wrong_identifier"}, []}

  defp refusal({:rate_limited, seconds}),
    do:
      {429, %{"error" => "rate_limited", "retry_after" => seconds},
       [{"retry-after", Integer.to_string(seconds)}]}

  defp refusal(:corrupt), do: {500, %{"error" => "corrupt"}, []}

  defp refusal({:capacity, which}),
    do:
      {503, %{"error" => "capacity", "exhausted" => Atom.to_string(which)},
       [{"retry-after", "60"}]}

  defp refusal({:capacity, :rotations, seconds}),
    do:
      {503, %{"error" => "capacity", "exhausted" => "rotations"},
       [{"retry-after", Integer.to_string(seconds)}]}

  defp refusal(:busy), do: {503, %{"error" => "busy"}, [{"retry-after", "1"}]}
  defp refusal(:unavailable), do: {503, %{"error" => "unavailable"}, [{"retry-after", "1"}]}
end
