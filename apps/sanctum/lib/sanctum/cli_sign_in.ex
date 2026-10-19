# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CliSignIn do
  @moduledoc """
  Signing a command line in by approving it in Prism (`cyfr login`), and
  the person's command-line sessions.

  ## The ceremony

    * `begin/2`: the command line, holding no credential, names the
      machine it runs on (`machine/1`) and is answered three things: a
      session token, 32 random bytes it keeps and nothing else is shown;
      a code of eight characters, `XXXX-XXXX`, it shows; and the link it
      prints, this home's `/cli` page with a 128-bit approval secret in
      the fragment's `code`, which a browser never sends to a server. The
      home stores only the two secrets' hashes, beside the code, the
      machine and an expiry five minutes out (`Arca.CliSignIns`).
    * `describe/1`: Prism's `/cli` page reads, by the link's secret, what
      it shows the person, the machine and the code, so they check the
      code against the one their command line shows before they approve.
    * `approve/2`: the person, signed in, approves. The session it mints
      outlives the approving one, so approving is a sensitive change of
      the `credential_issuance` action (`Sanctum.Pairing`): a fresh
      confirmation of this one sign-in, whose preview names the machine
      and the code. Once it is proven, one transaction mints the person's
      session, in the athanor in focus, under the token the command line
      holds; approves the pending sign-in, once and before its expiry on
      the database's clock; and consumes the confirmation
      (`Sanctum.Session.create_for_command_line/3`). Only a session
      approves: a paired device's context, an API key's and anyone
      anonymous are refused.
    * `poll/2`: the command line asks, by its token, what became of it:
      `pending`; `approved` while a session holds its token; `revoked`
      once that session ended; `cancelled`; or `expired`, which is also
      what a token no row knows reads as. The answer carries no secret,
      since the command line already holds its token.
    * `cancel/2`: the command line stops waiting (an interrupt or its
      deadline). A pending sign-in is cancelled, so no approval lands
      after it, and an approval that committed first has its session
      ended in the same transaction.
    * `list/1` and `revoke/2`: the person's command-line sessions, the
      ones the provider device flow signs in among them
      (`Sanctum.Auth.DeviceFlow`), and ending one. Revoking only
      narrows, so the person's session is all it needs.

  A command line killed while it waits leaves its pending sign-in to
  expire. Approved before then, the session it minted is held by no one:
  it is listed under the person's devices to revoke, and it ends at the
  session lifetime (`session_ttl_hours`).

  ## Bounds

  The command line's three calls are anonymous. Each begin writes a row,
  so it is counted against its source address (20 a minute) and the
  installation (200 a minute), this node's count and then the cell's
  (`Arca.RequestRateWindows`), and refused `{:rate_limited, seconds}`
  once either is spent. A poll and a cancel name a 256-bit token no one
  can guess, and are counted on this node alone, as the provider device
  flow's polls are: 180 a minute per address and 3,600 for the node, and
  then 60 per token, twice what a command line polling every two seconds
  asks; while one is spent a poll is answered `slow_down` and a cancel
  `{:rate_limited, seconds}`. The address is counted before the token,
  so no caller chooses how many tokens this node counts. Approving needs a
  signed-in session and a 128-bit secret, and adds no bound of its own.
  """

  alias Prima.Identity.Encoding
  alias Sanctum.Consent.Authz
  alias Sanctum.Context

  @lifetime_ms 300_000
  @lifetime_minutes div(@lifetime_ms, 60_000)
  @interval_s 2
  @secret_bytes 16
  @token_bytes 32
  @machine_bytes 64

  # Crockford's base32: no I, L, O or U, so a code reads back as it was
  # written. Eight characters are 40 random bits.
  @code_alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @window_ms 60_000
  @begin_source_cap 20
  @begin_installation_cap 200
  @poll_token_cap 60
  @poll_source_cap 180
  @poll_node_cap 3_600

  @typedoc "What `begin/2` answers the command line."
  @type begun :: %{
          session_token: String.t(),
          user_code: String.t(),
          approve_url: String.t(),
          expires_in: pos_integer(),
          interval: pos_integer()
        }

  @typedoc "What a pending sign-in became, as `poll/2` and `describe/1` read it."
  @type status :: String.t()

  # ============================================================================
  # The command line
  # ============================================================================

  @doc """
  Open a pending sign-in for the command line on `machine`, from the
  address `source` (nil where the ingress knew none): answers `t:begun/0`,
  or `{:error, {:invalid_argument, sentence}}` for a machine name
  `machine/1` refuses, `{:error, {:rate_limited, seconds}}` once a bound
  is spent, or `{:error, :unavailable}`.
  """
  @spec begin(term(), String.t() | nil) :: {:ok, begun()} | {:error, term()}
  def begin(machine, source) do
    with {:ok, machine} <- machine(machine),
         :ok <- begin_room(source) do
      secret = :crypto.strong_rand_bytes(@secret_bytes)
      token = Encoding.b64(:crypto.strong_rand_bytes(@token_bytes))

      attrs = %{
        approval_hash: approval_hash(secret),
        token_hash: Sanctum.Session.token_hash(token),
        token_prefix: String.slice(token, 0, 8),
        user_code: user_code(),
        machine: machine,
        lifetime_ms: @lifetime_ms
      }

      case Arca.CliSignIns.open(attrs) do
        {:ok, opened} ->
          {:ok,
           %{
             session_token: token,
             user_code: opened.user_code,
             approve_url: approve_url(secret),
             expires_in: div(@lifetime_ms, 1_000),
             interval: @interval_s
           }}

        {:error, _unrecorded} ->
          {:error, :unavailable}
      end
    end
  end

  @doc """
  What became of the pending sign-in the command line holding `token`
  opened (the module doc), from the address `source`: `{:ok, %{status,
  interval}}`, with `slow_down: true` once a bound is spent, or `{:error,
  :unavailable}`.
  """
  @spec poll(term(), String.t() | nil) ::
          {:ok, %{required(:status) => status(), optional(atom()) => term()}}
          | {:error, :unavailable}
  def poll(token, source) do
    with {:ok, token_hash} <- token_hash(token),
         :ok <- poll_room(token_hash, source) do
      case Arca.CliSignIns.by_token(token_hash) do
        {:ok, row} -> polled(row, token_hash)
        {:error, :not_found} -> {:ok, polled("expired")}
        {:error, _unanswered} -> {:error, :unavailable}
      end
    else
      :malformed -> {:ok, polled("expired")}
      :slow_down -> {:ok, Map.put(polled("pending"), :slow_down, true)}
    end
  end

  defp polled(%{state: "pending", expires_at: expires_at}, _token_hash) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: {:ok, polled("pending")},
      else: {:ok, polled("expired")}
  end

  defp polled(%{state: "approved"}, token_hash) do
    case Arca.SessionStorage.get_session(token_hash) do
      {:ok, _session} -> {:ok, polled("approved")}
      {:error, :not_found} -> {:ok, polled("revoked")}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp polled(%{state: "cancelled"}, _token_hash), do: {:ok, polled("cancelled")}

  defp polled(status), do: %{status: status, interval: @interval_s}

  @doc """
  Stop waiting: the pending sign-in the command line holding `token`
  opened is cancelled, and a session its approval already minted is
  ended and announced. Answers `{:ok, %{status: "cancelled"}}` (also for
  a token no row knows, since nothing is left to stop), `{:error,
  {:rate_limited, seconds}}` once a bound is spent, or `{:error,
  :unavailable}`.
  """
  @spec cancel(term(), String.t() | nil) ::
          {:ok, %{status: String.t()}} | {:error, {:rate_limited, pos_integer()} | :unavailable}
  def cancel(token, source) do
    with {:ok, token_hash} <- token_hash(token),
         :ok <- poll_room(token_hash, source) do
      case Arca.CliSignIns.cancel(token_hash) do
        {:ok, %{ended: user_id}} ->
          if is_binary(user_id), do: Sanctum.Session.announce_revoked(user_id, [token_hash])
          {:ok, %{status: "cancelled"}}

        {:error, :not_found} ->
          {:ok, %{status: "cancelled"}}

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    else
      :malformed -> {:ok, %{status: "cancelled"}}
      :slow_down -> {:error, {:rate_limited, div(@window_ms, 1_000)}}
    end
  end

  # ============================================================================
  # Prism
  # ============================================================================

  @doc """
  What the `/cli` page shows for the link's `secret`: `%{machine,
  user_code, expires_at, status}`, `status` as `poll/2` reads it but for
  a session it does not look up (`approved` once approved), or `{:error,
  :not_found}` for a secret no pending sign-in names. A trusted read: it
  grants nothing, and approving is `approve/2`'s decision.
  """
  @spec describe(term()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def describe(secret) do
    with {:ok, bytes} <- approval_secret(secret),
         {:ok, row} <- by_approval(bytes) do
      {:ok,
       %{
         machine: row.machine,
         user_code: row.user_code,
         expires_at: row.expires_at,
         status: shown_status(row)
       }}
    end
  end

  defp shown_status(%{state: "pending", expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt, do: "pending", else: "expired"
  end

  defp shown_status(%{state: state}), do: state

  @doc """
  Approve the command line the link's `secret` names, as the person
  `ctx` is (the module doc). Answers `%{machine, user_code}` once the
  session is minted; the consent signal `{:error, {:confirmation_required,
  _}}` until the confirmation is proven; or a refusal: `:not_found` for a
  secret no pending sign-in names, `:expired`, `:approved` (already
  used), `:cancelled` (the command line stopped waiting),
  `:session_required` for a context that holds no session, the standing
  refusals of the issuance (`Sanctum.Issuance.standing_refusals/0`) and
  the confirmation's own.
  """
  @spec approve(Context.t(), term()) :: {:ok, map()} | {:error, term()}
  def approve(%Context{auth_method: :oidc, session_token_hash: hash} = ctx, secret)
      when is_binary(hash) and is_binary(secret) do
    with {:ok, bytes} <- approval_secret(secret),
         {:ok, row} <- by_approval(bytes),
         :ok <- still_pending(row),
         change = approval_change(secret, row),
         :ok <- Authz.check(ctx, :credential_issuance, change) do
      approval_hash = approval_hash(bytes)

      # Approved, and its confirmation consumed, in the transaction that
      # inserts the session: a cancel, an expiry or a second approval that
      # wins the row's lock first rolls the session back with them.
      also = fn _session ->
        with :ok <- Arca.CliSignIns.approve!(approval_hash, row.token_hash),
             do: Authz.consume(ctx, {:credential_issuance, change})
      end

      minting = %{
        token_hash: row.token_hash,
        token_prefix: row.token_prefix,
        machine: row.machine
      }

      case Sanctum.Session.create_for_command_line(ctx, minting, also) do
        {:ok, _session} ->
          # Announced once its consumption committed with the session.
          Authz.consumed(ctx)
          {:ok, %{machine: row.machine, user_code: row.user_code}}

        {:error, :database_error} ->
          {:error, :unavailable}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def approve(%Context{auth_method: :oidc, session_token_hash: hash}, _secret)
      when is_binary(hash),
      do: {:error, :not_found}

  def approve(%Context{}, _secret), do: {:error, :session_required}

  defp still_pending(%{state: "pending", expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt, do: :ok, else: {:error, :expired}
  end

  defp still_pending(%{state: "approved"}), do: {:error, :approved}
  defp still_pending(%{state: "cancelled"}), do: {:error, :cancelled}

  @doc """
  What confirming a command line's sign-in approves
  (`t:Sanctum.Consent.Authz.change/0`): the session `approve/2` mints for
  the command line the link's `secret` names, which the preview names by
  its machine and the code it shows.
  """
  @spec approval_change(String.t(), map()) :: Authz.change()
  def approval_change(secret, %{machine: machine, user_code: code}) when is_binary(secret) do
    %{
      operation: "session.cli_approve",
      arguments: %{"approval_secret" => secret},
      resource: "the command line on " <> machine,
      details: %{
        "command_line" => "on #{machine}, showing #{code}",
        "sign_in" =>
          "The command line showing this code signs in as you, within " <>
            "#{@lifetime_minutes} minutes, and acts as you until you revoke it under Devices."
      }
    }
  end

  @doc """
  The person's live command-line sessions, oldest first: `%{session_id,
  machine, signed_in_at, expires_at, current}`, `current` for the session
  `ctx` holds itself.
  """
  @spec list(Context.t()) :: {:ok, [map()]} | {:error, :unauthenticated | :unavailable}
  def list(%Context{user_id: user_id} = ctx) when is_binary(user_id) and user_id != "" do
    case Arca.SessionStorage.list_command_lines(user_id) do
      {:ok, rows} ->
        own = own_session_id(ctx)

        {:ok,
         Enum.map(rows, fn row ->
           %{
             session_id: row.id,
             machine: row.cli_machine,
             signed_in_at: row.inserted_at,
             expires_at: row.expires_at,
             current: row.id == own
           }
         end)}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  def list(%Context{}), do: {:error, :unauthenticated}

  defp own_session_id(%Context{session_token_hash: hash}) when is_binary(hash) do
    case Arca.SessionStorage.get_session(hash) do
      {:ok, %{id: id}} -> id
      _none -> nil
    end
  end

  defp own_session_id(%Context{}), do: nil

  @doc """
  End the person's command-line session `session_id`, and announce it so
  every holder lets go (`Sanctum.Session.announce_revoked/2`). Answers
  `%{session_id, revoked: true}`, or `{:error, :not_found}` for an id that
  names no command-line session of theirs.
  """
  @spec revoke(Context.t(), term()) :: {:ok, map()} | {:error, term()}
  def revoke(%Context{user_id: user_id}, session_id)
      when is_binary(user_id) and user_id != "" and is_binary(session_id) do
    case Arca.SessionStorage.delete_command_line(user_id, session_id) do
      {:ok, token_hash} ->
        Sanctum.Session.announce_revoked(user_id, [token_hash])
        {:ok, %{session_id: session_id, revoked: true}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  def revoke(%Context{user_id: user_id}, _session_id) when is_binary(user_id) and user_id != "",
    do: {:error, {:invalid_argument, "Missing required argument: session_id"}}

  def revoke(%Context{}, _session_id), do: {:error, :unauthenticated}

  # ============================================================================
  # Shared
  # ============================================================================

  @doc """
  The machine name a command line gives, trimmed: 1 to #{@machine_bytes}
  characters of printable ASCII, spaces inside it included. Anything else
  is `{:error, {:invalid_argument, sentence}}`, so no control character,
  bidirectional mark or look-alike letter reaches the prompt that names
  the machine.
  """
  @spec machine(term()) :: {:ok, String.t()} | {:error, {:invalid_argument, String.t()}}
  def machine(name) when is_binary(name) do
    trimmed = String.trim(name)

    if byte_size(trimmed) in 1..@machine_bytes and trimmed =~ ~r/\A[\x20-\x7E]+\z/,
      do: {:ok, trimmed},
      else: machine(nil)
  end

  def machine(_name),
    do:
      {:error,
       {:invalid_argument,
        "The machine is the command line's host name: 1 to #{@machine_bytes} printable ASCII characters"}}

  @doc """
  Delete the pending sign-ins past their expiry (`Arca.CliSignIns.sweep/0`):
  housekeeping, which the session sweep runs (`Sanctum.Session.cleanup/0`).
  """
  @spec sweep() :: {:ok, non_neg_integer()} | {:error, :database_error}
  def sweep, do: Arca.CliSignIns.sweep()

  @doc "How long a pending sign-in waits for its approval, in milliseconds."
  @spec lifetime_ms() :: pos_integer()
  def lifetime_ms, do: @lifetime_ms

  # The one spelling of the link a command line prints: this home's
  # `/cli` page, the approval secret in the fragment, which a browser
  # never sends.
  defp approve_url(secret), do: Sanctum.Person.home() <> "/cli#code=" <> Encoding.b64(secret)

  defp approval_hash(secret_bytes), do: :crypto.hash(:sha256, secret_bytes)

  defp approval_secret(secret) do
    case Encoding.unb64(secret, @secret_bytes) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :not_found}
    end
  end

  defp by_approval(bytes) do
    case Arca.CliSignIns.by_approval(approval_hash(bytes)) do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # A token is the unpadded base64url of 32 bytes; anything else names no
  # pending sign-in and is answered as one that expired.
  defp token_hash(token) do
    case Encoding.unb64(token, @token_bytes) do
      {:ok, _bytes} -> {:ok, Sanctum.Session.token_hash(token)}
      :error -> :malformed
    end
  end

  defp user_code do
    <<bits::40>> = :crypto.strong_rand_bytes(5)

    code =
      for shift <- 35..0//-5, into: "" do
        <<Enum.at(@code_alphabet, Bitwise.band(Bitwise.bsr(bits, shift), 31))>>
      end

    String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
  end

  # ---- bounds ------------------------------------------------------------------

  defp begin_room(source) do
    key = source_key(source)

    with :ok <- on_node({:cli_sign_in, :source, key}, @begin_source_cap),
         :ok <- on_node({:cli_sign_in, :installation}, @begin_installation_cap),
         :ok <- in_cell(:cli_sign_in_source, key, @begin_source_cap) do
      in_cell(:cli_sign_in_installation, "installation", @begin_installation_cap)
    end
  end

  defp on_node(key, cap) do
    case Prima.RateLimiter.check(key, cap, @window_ms) do
      :ok -> :ok
      {:deny, retry_after_s} -> {:error, {:rate_limited, retry_after_s}}
    end
  end

  defp in_cell(bucket, key, cap) do
    case Arca.RequestRateWindows.claim(Prima.Actor.system(), bucket, key, cap, @window_ms) do
      :ok ->
        :ok

      {:error, {:rate_limited, retry_after_ms}} ->
        {:error, {:rate_limited, seconds(retry_after_ms)}}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp seconds(ms), do: max(div(ms + 999, 1_000), 1)

  defp poll_room(token_hash, source) do
    with :ok <-
           Prima.RateLimiter.check(
             {:cli_poll, :source, source_key(source)},
             @poll_source_cap,
             @window_ms
           ),
         :ok <- Prima.RateLimiter.check({:cli_poll, :all}, @poll_node_cap, @window_ms),
         :ok <- Prima.RateLimiter.check({:cli_poll, token_hash}, @poll_token_cap, @window_ms) do
      :ok
    else
      {:deny, _retry_after_s} -> :slow_down
    end
  end

  # An ingress that knew no address charges one shared bucket, never none.
  defp source_key(source) when is_binary(source) and source != "", do: source
  defp source_key(_source), do: "unknown"
end
