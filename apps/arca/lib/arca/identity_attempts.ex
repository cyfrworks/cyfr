# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.IdentityAttempts do
  @moduledoc """
  Enrollment, added-kit, restore and rotation attempts (`Arca.Schemas.IdentityAttempt`),
  keyed by request id, each persisted with its immutable submission before
  any remote call and advanced through named phases, each durable before
  the next begins, so a killed attempt resumes from the phase it reached.

  ## Phases

  The closed list is `staged | submitted | accepted | refused | superseded
  | keys_active | minted | completed`. Each kind walks its own path, and
  every move is a conditional write from the phase the caller names
  (`advance/5`): a move the kind's path does not have, or one from a phase
  the row no longer holds, writes nothing.

    * **enrollment** — `staged → submitted → accepted → completed`, or
      `submitted → refused`, or `staged | submitted → superseded` (the
      person abandoned it before the directory's acceptance). Acceptance
      writes the identifier onto the person's identity row in the same
      transaction, and a refusal or an abandonment returns the person to
      unenrolled; completion is the kit's acknowledgment
      (`acknowledge_kit/2`), which erases the sealed seed with it.
    * **holder** (another printed kit, added by a `recover` an existing
      kit signs, keeping the online keys) — `staged → submitted →
      accepted → completed`, or `submitted → refused`. Acceptance names
      the committed entry's hash and moves the person's head to it, only
      while the row still reads the head the attempt was staged at;
      completion is the kit's acknowledgment, as an enrollment's.
    * **rotation** — `staged → submitted → accepted → keys_active →
      completed`, or `submitted → refused | superseded` and `accepted →
      superseded`. `keys_active` replaces the person's live key and head
      only while their row still reads the head the rotation extended.
    * **restore** — `staged → submitted → accepted → keys_active → minted
      → completed`, or `submitted → refused | superseded` and `accepted |
      keys_active | minted → superseded`: a later recovery may replace the
      keys it introduced at any phase before its completion. Superseded at
      `minted`, it keeps naming the person it minted, whose row stays.
      Opening a restore claims the installation for it in the same
      transaction (`Arca.InstallationClaims`), so the claim and the attempt
      commit or roll back together, and the attempt's end, whatever its
      outcome, ends the claim.

  A terminal move (`refused`, `superseded`, `completed`) clears the staged
  sealed keys.

  ## One attempt in progress

  One enrollment and one rotation per person may be in progress at once,
  and one restore per installation token. A rotation and an added kit
  each move the person's head, and an added kit's `recover` names the
  online keys it keeps, so neither opens while the other is in flight
  (an added kit staged or submitted, a rotation not yet ended): both
  decide that under the person's row lock. Opening one again with the
  exact same submission answers the attempt that stands, so a lost
  response resumes rather than stages a second key set; a different
  submission is refused `:attempt_in_progress` (or `:token_claimed` for a
  restore).

  `open/3` takes an `also:` closure run inside its transaction after the
  attempt is written, the seam an enrollment or an added kit consumes its
  confirmation through, so the two commit or roll back together.

  ## Who writes

  Every function takes the actor first: a person reaches their own
  enrollment, added-kit and rotation attempts, the platform's own actor
  reaches any, and a restore is the platform's alone. Opening and advancing an attempt
  prove first that this member still owns its slot; a stale member writes
  nothing (`:not_owner`). Rows are plain maps (`Arca.Data`), sealed bytes
  included.
  """

  import Ecto.Query

  alias Arca.{InstallationClaims, PersonIdentities}
  alias Arca.Schemas.{IdentityAttempt, PersonIdentity}

  @paths %{
    "enrollment" => %{
      "staged" => ["submitted", "superseded"],
      "submitted" => ["accepted", "refused", "superseded"]
    },
    "holder" => %{
      "staged" => ["submitted"],
      "submitted" => ["accepted", "refused"]
    },
    "rotation" => %{
      "staged" => ["submitted"],
      "submitted" => ["accepted", "refused", "superseded"],
      "accepted" => ["keys_active", "superseded"],
      "keys_active" => ["completed"]
    },
    "restore" => %{
      "staged" => ["submitted"],
      "submitted" => ["accepted", "refused", "superseded"],
      "accepted" => ["keys_active", "superseded"],
      "keys_active" => ["minted", "superseded"],
      "minted" => ["completed", "superseded"]
    }
  }

  @terminal ~w(refused superseded completed)
  # The phases in which an added kit or a rotation still moves the
  # person's head: neither opens while the other holds one.
  @holder_moving ~w(staged submitted)
  @rotation_moving ~w(staged submitted accepted keys_active)
  @staged_columns [
    :staged_live_public_key,
    :staged_operational_public_key,
    :staged_live_key_sealed,
    :staged_operational_key_sealed
  ]

  @typedoc "An attempt row, as a plain map."
  @type row :: map()

  @doc "The phase moves each kind's path allows, `%{from => [to]}` per kind."
  @spec paths() :: %{String.t() => %{String.t() => [String.t()]}}
  def paths, do: @paths

  @doc """
  Persist a new attempt at `staged`. `attrs` carries the `:kind`, the
  caller's `:request_id` and the kind's submission:

    * **enrollment** — `:user_id`, `:identifier`, `:directory_url`, the
      immutable `:genesis` bytes, `:request_digest` (the genesis entry's
      hash) and the sealed `:kit_seed_sealed`. The person's identity row
      moves `none → pending` with it; a person with no local identity row,
      or one already enrolled, is refused `:not_enrollable`.
    * **holder** — `:user_id`, `:identifier`, `:directory_url`, the signed
      recover request's `:entry` bytes and `:request_digest`, the
      `:expected_revision` it names, the `:expected_head` the person's row
      reads as it is staged, and the added kit's sealed `:kit_seed_sealed`.
      The person must be enrolled under that identifier at that head
      (`:not_enrollable` or `:stale_head` otherwise), with no rotation in
      flight (`:attempt_in_progress`).
    * **rotation** — `:user_id`, the candidate `:entry` bytes and
      `:entry_hash` (also its `:request_digest`), the `:expected_head` it
      extends, and the staged `:staged_live_public_key` and
      `:staged_live_key_sealed`. The person must be enrolled at that head
      (`:stale_head` otherwise), with no added kit in flight
      (`:attempt_in_progress`).
    * **restore** — only the platform's actor: `:identifier`,
      `:directory_url`, the recover request's `:entry` bytes and
      `:request_digest`, the `:expected_revision`, the installation
      `:token_digest`, the staged live and operational keys, public and
      sealed, and the identifier's immutable `:genesis` bytes, which the
      restored person's identity rests on (`genesis/2`). The open claims
      the empty installation for this request and token in its own
      transaction: `:claimed` while another restore holds it,
      `:token_spent` for a token any claim was ever bound to, `:not_empty`
      on a node that holds a person.

  `opts[:also]` is run after the row is written, inside the transaction,
  with the attempt as a plain map; `{:error, reason}` rolls both back.

  Answers `{:ok, attempt}`, the attempt that stands for an exact retry
  (its `also:` is not run again), or a refusal: `:request_id_reused`,
  `:attempt_in_progress`, `:token_claimed`, `:not_enrollable`,
  `:stale_head`, `:claimed`, `:token_spent`, `:not_empty`, `:not_owner`,
  `:cross_tenant`,
  `{:invalid, errors}`, `:database_error`, or the closure's reason.
  """
  @spec open(Prima.Actor.t(), map(), keyword()) :: {:ok, row()} | {:error, term()}
  def open(%Prima.Actor{} = actor, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    attrs = Map.new(attrs)
    also = Keyword.get(opts, :also, fn _attempt -> :ok end)

    with :ok <- opens?(actor, attrs),
         {:ok, row} <- build(attrs) do
      Arca.Repo.Errors.with_db_rescue("Arca.IdentityAttempts.open", fn ->
        fenced(fn -> open_in(row, also) end)
      end)
      |> Arca.Data.project()
    end
  end

  @doc """
  Move the attempt `id` from `from` to `to`, a move its kind's path has,
  in one conditional write: nothing is written unless the row still holds
  `from`. `attrs` may record the directory's `:outcome` (text); a restore
  moving to `minted` names the `:user_id` it minted; an added kit or a
  restore moving to `accepted` names the committed `:entry_hash`, which an
  added kit requires.

  The move's own writes commit with it: an enrollment's acceptance writes
  the identifier onto the person's row, and its refusal or its abandonment
  (`superseded`, which takes the person's row lock before the attempt's)
  returns them to unenrolled; an added kit's acceptance moves the person's
  head to its entry while the row still reads the head it was staged at
  (`:stale_head` otherwise); a rotation's `keys_active` replaces the live
  key while the person's head is still the one it extended (`:stale_head`
  otherwise); a restore's end ends its installation claim; every terminal
  move clears the staged keys.

  Refusals: `:out_of_order` (a move the path lacks), `:stale` (the row no
  longer holds `from`), `:stale_head`, `:not_found`, `:not_owner`,
  `:cross_tenant`, `:database_error`.
  """
  @spec advance(Prima.Actor.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, row()} | {:error, term()}
  def advance(%Prima.Actor{} = actor, id, from, to, attrs \\ %{})
      when is_binary(id) and is_binary(from) and is_binary(to) and is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityAttempts.advance", fn ->
      fenced(fn ->
        with {:ok, attempt} <- held(actor, id),
             :ok <- allowed(attempt, from, to),
             :ok <- person_first(attempt, to) do
          move(attempt, from, to, Map.new(attrs))
        end
      end)
    end)
    |> Arca.Data.project()
  end

  @doc """
  The person acknowledged saving their kit: an accepted enrollment or
  added kit moves to `completed` and its sealed seed is erased in the
  same write. Asked again, it answers the completed attempt with no seed;
  the seed is never restored. One not yet accepted is refused
  `:not_accepted`. Narrows only, so a member that lost its slot may still
  acknowledge.
  """
  @spec acknowledge_kit(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_accepted | :not_found | :cross_tenant | :database_error}
  def acknowledge_kit(%Prima.Actor{} = actor, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityAttempts.acknowledge_kit", fn ->
      Arca.Repo.locking_transaction(fn ->
        with {:ok, attempt} <- held(actor, id) do
          acknowledged(attempt)
        end
        |> committed()
      end)
    end)
    |> Arca.Data.project()
  end

  @doc "The attempt `id`, if the actor may read it."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get(%Prima.Actor{} = actor, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityAttempts.get", fn ->
      case Arca.Repo.get(IdentityAttempt, id) do
        nil -> {:error, :not_found}
        attempt -> if reads?(actor, attempt), do: {:ok, attempt}, else: {:error, :cross_tenant}
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  The restore attempt bound to an installation token's digest, which
  names at most one: the platform's own actor only.
  """
  @spec get_by_token(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get_by_token(%Prima.Actor{scope: :platform, system: true}, token_digest)
      when is_binary(token_digest) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityAttempts.get_by_token", fn ->
      case Arca.Repo.get_by(IdentityAttempt, token_digest: token_digest, kind: "restore") do
        nil -> {:error, :not_found}
        attempt -> {:ok, attempt}
      end
    end)
    |> Arca.Data.project()
  end

  def get_by_token(%Prima.Actor{}, _token_digest), do: {:error, :cross_tenant}

  @doc "The attempt a request id names, if the actor may read it."
  @spec get_by_request(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get_by_request(%Prima.Actor{} = actor, request_id) when is_binary(request_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityAttempts.get_by_request", fn ->
      case Arca.Repo.get_by(IdentityAttempt, request_id: request_id) do
        nil -> {:error, :not_found}
        attempt -> if reads?(actor, attempt), do: {:ok, attempt}, else: {:error, :cross_tenant}
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  The person's attempt of `kind` still in progress (not refused,
  superseded or completed), or `{:error, :not_found}`.
  """
  @spec in_progress(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def in_progress(%Prima.Actor{} = actor, user_id, kind)
      when is_binary(user_id) and kind in ["enrollment", "holder", "rotation"] do
    if person?(actor, user_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.IdentityAttempts.in_progress", fn ->
        from(a in IdentityAttempt,
          where: a.user_id == ^user_id and a.kind == ^kind and a.phase not in ^@terminal,
          order_by: [desc: a.inserted_at],
          limit: 1
        )
        |> Arca.Repo.one()
        |> case do
          nil -> {:error, :not_found}
          attempt -> {:ok, attempt}
        end
      end)
      |> Arca.Data.project()
    else
      {:error, :cross_tenant}
    end
  end

  @doc """
  The genesis a person's identity rests on, and the directory it names:
  the immutable genesis bytes of their accepted or completed enrollment,
  or of the restore that minted them, with its identifier and directory
  URL. What the person's own home hands its directory client, and the one
  locator a rotation or a sign-in carry reads, never this home's
  enrollment setting. Read-only.

  `{:error, :not_found}` for a person with no such attempt: one never
  enrolled, or whose enrollment is still pending or was refused.
  """
  @spec genesis(Prima.Actor.t(), String.t()) ::
          {:ok, %{genesis: binary(), identifier: String.t(), directory_url: String.t()}}
          | {:error, :not_found | :cross_tenant | :database_error}
  def genesis(%Prima.Actor{} = actor, user_id) when is_binary(user_id) do
    if person?(actor, user_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.IdentityAttempts.genesis", fn ->
        from(a in IdentityAttempt,
          where:
            a.user_id == ^user_id and not is_nil(a.genesis) and
              ((a.kind == "enrollment" and a.phase in ["accepted", "completed"]) or
                 (a.kind == "restore" and a.phase in ["minted", "completed"])),
          order_by: [desc: a.inserted_at],
          limit: 1,
          select: %{genesis: a.genesis, identifier: a.identifier, directory_url: a.directory_url}
        )
        |> Arca.Repo.one()
        |> case do
          nil -> {:error, :not_found}
          binding -> {:ok, binding}
        end
      end)
    else
      {:error, :cross_tenant}
    end
  end

  @doc """
  Hold a single-use first-method reproof challenge on a completed restore:
  the digest of a fresh server challenge and its expiry, an instant on
  the database's clock (`Arca.ServerMetaStorage.now!/0`), which is the
  clock `reproof_held/3` and `consume_reproof/3` read it against,
  replacing any earlier one. Only while the restored person has never had
  a fresh confirmation method (`:first_method_used` otherwise). The
  platform's actor only.
  """
  @spec put_reproof(Prima.Actor.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, row()} | {:error, term()}
  def put_reproof(
        %Prima.Actor{scope: :platform, system: true},
        id,
        digest,
        %DateTime{} = expires_at
      )
      when is_binary(id) do
    if Prima.Identity.Encoding.digest?(digest) do
      Arca.Repo.Errors.with_db_rescue("Arca.IdentityAttempts.put_reproof", fn ->
        fenced(fn -> reproof(id, digest: digest, expires_at: expires_at) end)
      end)
      |> Arca.Data.project()
    else
      {:error, {:invalid, %{reproof_challenge_digest: ["is not a sha256 digest"]}}}
    end
  end

  def put_reproof(%Prima.Actor{}, _id, _digest, _expires_at), do: {:error, :cross_tenant}

  @doc """
  Whether the restore `id` holds the reproof challenge `digest`, before its
  expiry on the database's clock, without consuming it: a reproof asks
  before it reads the directory and consumes the challenge last
  (`consume_reproof/3`). Answers `:ok` or `{:error, :no_challenge}`. The
  platform's actor only.
  """
  @spec reproof_held(Prima.Actor.t(), String.t(), String.t()) ::
          :ok | {:error, :no_challenge | :cross_tenant | :database_error}
  def reproof_held(%Prima.Actor{scope: :platform, system: true}, id, digest)
      when is_binary(id) and is_binary(digest) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityAttempts.reproof_held", fn ->
      if Arca.Repo.exists?(live_reproof(id, digest, Arca.ServerMetaStorage.now!())),
        do: :ok,
        else: {:error, :no_challenge}
    end)
  end

  def reproof_held(%Prima.Actor{}, _id, _digest), do: {:error, :cross_tenant}

  @doc """
  Consume the restore's reproof challenge: only the digest it holds, before
  its expiry on the database's clock, and only while the restored person
  has never had a fresh confirmation method. Consumed once: a second
  answers `:no_challenge`. The platform's actor only.
  """
  @spec consume_reproof(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, term()}
  def consume_reproof(%Prima.Actor{scope: :platform, system: true}, id, digest)
      when is_binary(id) and is_binary(digest) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityAttempts.consume_reproof", fn ->
      fenced(fn -> reproof(id, consume: digest) end)
    end)
    |> Arca.Data.project()
  end

  def consume_reproof(%Prima.Actor{}, _id, _digest), do: {:error, :cross_tenant}

  # ---- opening ---------------------------------------------------------------

  defp opens?(%Prima.Actor{scope: :platform, system: true}, _attrs), do: :ok
  defp opens?(%Prima.Actor{}, %{kind: "restore"}), do: {:error, :cross_tenant}

  defp opens?(%Prima.Actor{user_id: user_id}, %{user_id: user_id}) when is_binary(user_id),
    do: :ok

  defp opens?(%Prima.Actor{}, _attrs), do: {:error, :cross_tenant}

  defp open_in(row, also) do
    case Arca.Repo.get_by(IdentityAttempt, request_id: row.request_id) do
      nil -> open_new(row, also)
      existing -> same_submission(existing, row)
    end
  end

  defp open_new(%{kind: kind} = row, also) do
    with :ok <- precondition(row),
         :ok <- inserted(row, kind),
         :ok <- side_effect(row) do
      attempt = Arca.Repo.get!(IdentityAttempt, row.id)

      case also.(Arca.Data.project(attempt)) do
        :ok -> {:ok, attempt}
        {:error, _reason} = refusal -> refusal
      end
    end
  end

  defp precondition(%{
         kind: "restore",
         token_digest: token,
         request_id: request,
         identifier: identifier
       })
       when is_binary(token) and is_binary(request) and is_binary(identifier) do
    claim = %{token_digest: token, request_id: request, identifier: identifier}
    with {:ok, _claim} <- InstallationClaims.claim!(claim), do: :ok
  end

  # A rotation and an added kit each move the person's head. Each decides
  # under the person's row lock, the first of the standing order, so of
  # two racing opens the second sees the first.
  defp precondition(%{kind: "rotation", user_id: user_id, expected_head: head}) do
    _locked = Arca.DirectoryHeads.lock_person!(user_id)

    enrolled =
      from(p in PersonIdentity,
        where:
          p.user_id == ^user_id and p.provenance == "local" and p.enrollment == "enrolled" and
            p.head_hash == ^head
      )

    cond do
      not Arca.Repo.exists?(enrolled) -> {:error, :stale_head}
      moving?(user_id, "holder", @holder_moving) -> {:error, :attempt_in_progress}
      true -> :ok
    end
  end

  defp precondition(%{
         kind: "holder",
         user_id: user_id,
         identifier: identifier,
         expected_head: head
       }) do
    _locked = Arca.DirectoryHeads.lock_person!(user_id)

    identity =
      Arca.Repo.one(
        from(p in PersonIdentity,
          where:
            p.user_id == ^user_id and p.provenance == "local" and p.enrollment == "enrolled" and
              p.identifier == ^identifier
        )
      )

    cond do
      is_nil(identity) -> {:error, :not_enrollable}
      identity.head_hash != head -> {:error, :stale_head}
      moving?(user_id, "rotation", @rotation_moving) -> {:error, :attempt_in_progress}
      moving?(user_id, "holder", @holder_moving) -> {:error, :attempt_in_progress}
      true -> :ok
    end
  end

  defp precondition(%{kind: "enrollment"}), do: :ok

  defp moving?(user_id, kind, phases) do
    Arca.Repo.exists?(
      from(a in IdentityAttempt,
        where: a.user_id == ^user_id and a.kind == ^kind and a.phase in ^phases
      )
    )
  end

  # The partial unique indexes decide a race between two opens; the loser
  # reads what won and answers it or refuses.
  defp inserted(row, kind) do
    case Arca.Repo.insert_all(IdentityAttempt, [row], on_conflict: :nothing) do
      {1, _} -> :ok
      {0, _} -> lost(row, kind)
    end
  end

  defp lost(row, "restore") do
    existing =
      Arca.Repo.get_by(IdentityAttempt, token_digest: row.token_digest) ||
        Arca.Repo.get_by(IdentityAttempt, request_id: row.request_id)

    case existing do
      nil -> {:error, :token_claimed}
      existing -> same_submission(existing, row)
    end
  end

  defp lost(row, kind) do
    case Arca.Repo.get_by(IdentityAttempt, request_id: row.request_id) do
      nil ->
        from(a in IdentityAttempt,
          where: a.user_id == ^row.user_id and a.kind == ^kind and a.phase not in ^@terminal,
          limit: 1
        )
        |> Arca.Repo.one()
        |> case do
          nil -> {:error, :attempt_in_progress}
          existing -> same_submission(existing, row)
        end

      existing ->
        same_submission(existing, row)
    end
  end

  # An exact retry answers the attempt that stands; any other submission
  # under that request id or in its place is refused.
  defp same_submission(existing, row) do
    same? =
      existing.kind == row.kind and existing.user_id == row.user_id and
        existing.request_digest == row.request_digest and existing.genesis == row.genesis and
        existing.entry == row.entry and existing.token_digest == row.token_digest

    cond do
      same? -> {:ok, existing}
      existing.request_id == row.request_id -> {:error, :request_id_reused}
      existing.kind == "restore" -> {:error, :token_claimed}
      true -> {:error, :attempt_in_progress}
    end
  end

  defp side_effect(%{kind: "enrollment", user_id: user_id}) do
    if PersonIdentities.enrolling!(user_id) == 1, do: :ok, else: {:error, :not_enrollable}
  end

  defp side_effect(_row), do: :ok

  # ---- advancing -------------------------------------------------------------

  defp held(actor, id) do
    case Arca.Repo.get(IdentityAttempt, id) do
      nil -> {:error, :not_found}
      attempt -> if reads?(actor, attempt), do: {:ok, attempt}, else: {:error, :cross_tenant}
    end
  end

  # An abandoned enrollment returns the person to unenrolled, so it takes
  # the person's row lock before it writes the attempt, the first of the
  # standing order, as the opens that move a person's identity do.
  defp person_first(%IdentityAttempt{kind: "enrollment", user_id: user_id}, "superseded") do
    _locked = Arca.DirectoryHeads.lock_person!(user_id)
    :ok
  end

  defp person_first(_attempt, _to), do: :ok

  defp allowed(%IdentityAttempt{kind: kind}, from, to) do
    if to in (@paths |> Map.fetch!(kind) |> Map.get(from, [])),
      do: :ok,
      else: {:error, :out_of_order}
  end

  defp move(attempt, from, to, attrs) do
    with {:ok, set} <- move_set(attempt, to, attrs) do
      {count, _} =
        from(a in IdentityAttempt, where: a.id == ^attempt.id and a.phase == ^from)
        |> Arca.Repo.update_all(set: set, inc: [revision: 1])

      case count do
        1 ->
          moved = Arca.Repo.get!(IdentityAttempt, attempt.id)
          with :ok <- consequence(moved, to), do: {:ok, moved}

        0 ->
          {:error, :stale}
      end
    end
  end

  # The columns a move writes: its phase, the directory's outcome when one
  # is recorded, the person a restore minted, and on a terminal move the
  # sealed material it no longer needs.
  defp move_set(attempt, to, attrs) do
    now = Arca.ServerMetaStorage.now!()
    set = [phase: to, updated_at: now]

    set =
      case attrs do
        %{outcome: outcome} when is_binary(outcome) -> Keyword.put(set, :outcome, outcome)
        _ -> set
      end

    set =
      if to in @terminal,
        do: set ++ [staged_live_key_sealed: nil, staged_operational_key_sealed: nil],
        else: set

    set =
      if to in ["refused", "superseded"], do: Keyword.put(set, :kit_seed_sealed, nil), else: set

    case {attempt.kind, to, attrs} do
      {"restore", "minted", %{user_id: user_id}} when is_binary(user_id) and user_id != "" ->
        {:ok, Keyword.put(set, :user_id, user_id)}

      {"restore", "minted", _attrs} ->
        {:error, {:invalid, %{user_id: ["names the person the restore minted"]}}}

      {kind, "accepted", %{entry_hash: hash}} when kind in ["holder", "restore"] ->
        if Prima.Identity.Encoding.digest?(hash),
          do: {:ok, Keyword.put(set, :entry_hash, hash)},
          else: {:error, {:invalid, %{entry_hash: ["is not a sha256 digest"]}}}

      {"holder", "accepted", _attrs} ->
        {:error, {:invalid, %{entry_hash: ["names the entry the directory committed"]}}}

      _ ->
        {:ok, set}
    end
  end

  # What a move commits beside the attempt's own row.
  defp consequence(%IdentityAttempt{kind: "enrollment"} = attempt, "accepted") do
    facts = %{
      identifier: attempt.identifier,
      genesis_hash: attempt.request_digest,
      head_hash: attempt.request_digest,
      directory_url: attempt.directory_url
    }

    if PersonIdentities.enrolled!(attempt.user_id, facts) == 1,
      do: :ok,
      else: {:error, :stale}
  end

  defp consequence(%IdentityAttempt{kind: "enrollment"} = attempt, to)
       when to in ["refused", "superseded"] do
    PersonIdentities.unenrolled!(attempt.user_id)
    :ok
  end

  # An added kit's committed `recover` is the person's new head: the keys
  # it names are the ones the row holds, so only the head moves.
  defp consequence(%IdentityAttempt{kind: "holder"} = attempt, "accepted") do
    if PersonIdentities.recovered_head!(
         attempt.user_id,
         attempt.expected_head,
         attempt.entry_hash
       ) == 1,
       do: :ok,
       else: {:error, :stale_head}
  end

  defp consequence(%IdentityAttempt{kind: "rotation"} = attempt, "keys_active") do
    set = [
      live_public_key: attempt.staged_live_public_key,
      live_key_sealed: attempt.staged_live_key_sealed,
      head_hash: attempt.entry_hash
    ]

    if PersonIdentities.activate_keys!(attempt.user_id, attempt.expected_head, set) == 1,
      do: :ok,
      else: {:error, :stale_head}
  end

  defp consequence(%IdentityAttempt{kind: "restore"} = attempt, to) when to in @terminal do
    InstallationClaims.end!(attempt.request_id, to)
    :ok
  end

  defp consequence(_attempt, _to), do: :ok

  defp acknowledged(%IdentityAttempt{kind: kind, phase: "completed"} = attempt)
       when kind in ["enrollment", "holder"],
       do: {:ok, attempt}

  defp acknowledged(%IdentityAttempt{kind: kind, phase: "accepted"} = attempt)
       when kind in ["enrollment", "holder"] do
    now = Arca.ServerMetaStorage.now!()

    {count, _} =
      from(a in IdentityAttempt, where: a.id == ^attempt.id and a.phase == "accepted")
      |> Arca.Repo.update_all(
        set: [phase: "completed", kit_seed_sealed: nil, kit_acknowledged_at: now, updated_at: now],
        inc: [revision: 1]
      )

    if count == 1,
      do: {:ok, Arca.Repo.get!(IdentityAttempt, attempt.id)},
      else: acknowledged(Arca.Repo.get!(IdentityAttempt, attempt.id))
  end

  defp acknowledged(%IdentityAttempt{}), do: {:error, :not_accepted}

  defp reproof(id, change) do
    with %IdentityAttempt{kind: "restore", phase: "completed", user_id: user_id} = attempt
         when is_binary(user_id) <- Arca.Repo.get(IdentityAttempt, id) || {:error, :not_found},
         :ok <- no_method_yet(user_id) do
      write_reproof(attempt, change)
    else
      %IdentityAttempt{} -> {:error, :not_restored}
      {:error, _reason} = refusal -> refusal
    end
  end

  defp write_reproof(attempt, digest: digest, expires_at: expires_at) do
    now = Arca.ServerMetaStorage.now!()

    {1, _} =
      from(a in IdentityAttempt, where: a.id == ^attempt.id)
      |> Arca.Repo.update_all(
        set: [
          reproof_challenge_digest: digest,
          reproof_expires_at: usec(expires_at),
          updated_at: now
        ],
        inc: [revision: 1]
      )

    {:ok, Arca.Repo.get!(IdentityAttempt, attempt.id)}
  end

  defp write_reproof(attempt, consume: digest) do
    now = Arca.ServerMetaStorage.now!()

    {count, _} =
      live_reproof(attempt.id, digest, now)
      |> Arca.Repo.update_all(
        set: [reproof_challenge_digest: nil, reproof_expires_at: nil, updated_at: now],
        inc: [revision: 1]
      )

    if count == 1,
      do: {:ok, Arca.Repo.get!(IdentityAttempt, attempt.id)},
      else: {:error, :no_challenge}
  end

  # The restore's challenge `digest`, held and alive at `now`, the
  # database's clock its expiry was set from (`Sanctum.Recovery`).
  defp live_reproof(id, digest, now) do
    from(a in IdentityAttempt,
      where: a.id == ^id and a.reproof_challenge_digest == ^digest and a.reproof_expires_at > ^now
    )
  end

  defp no_method_yet(user_id) do
    used =
      from(p in PersonIdentity, where: p.user_id == ^user_id and not is_nil(p.first_method_at))

    if Arca.Repo.exists?(used), do: {:error, :first_method_used}, else: :ok
  end

  # ---- reading and building --------------------------------------------------

  defp reads?(%Prima.Actor{scope: :platform}, _attempt), do: true
  defp reads?(%Prima.Actor{}, %IdentityAttempt{kind: "restore"}), do: false

  defp reads?(%Prima.Actor{user_id: user_id}, %IdentityAttempt{user_id: user_id})
       when is_binary(user_id), do: true

  defp reads?(%Prima.Actor{}, _attempt), do: false

  defp person?(%Prima.Actor{scope: :platform}, _user_id), do: true
  defp person?(%Prima.Actor{user_id: user_id}, user_id), do: true
  defp person?(%Prima.Actor{}, _user_id), do: false

  defp build(%{kind: "enrollment"} = attrs) do
    []
    |> required(attrs, :request_id, &Prima.Identity.Encoding.id?/1)
    |> required(attrs, :user_id, &nonempty?/1)
    |> required(attrs, :identifier, &Prima.Identity.Encoding.identifier?/1)
    |> required(attrs, :directory_url, &Prima.Identity.Encoding.directory_url?/1)
    |> required(attrs, :genesis, &bytes?/1)
    |> required(attrs, :request_digest, &Prima.Identity.Encoding.digest?/1)
    |> required(attrs, :kit_seed_sealed, &nonempty_binary?/1)
    |> row(attrs, ~w(user_id identifier directory_url genesis request_digest kit_seed_sealed)a)
  end

  defp build(%{kind: "holder"} = attrs) do
    []
    |> required(attrs, :request_id, &Prima.Identity.Encoding.id?/1)
    |> required(attrs, :user_id, &nonempty?/1)
    |> required(attrs, :identifier, &Prima.Identity.Encoding.identifier?/1)
    |> required(attrs, :directory_url, &Prima.Identity.Encoding.directory_url?/1)
    |> required(attrs, :entry, &bytes?/1)
    |> required(attrs, :request_digest, &Prima.Identity.Encoding.digest?/1)
    |> required(attrs, :expected_revision, &(is_integer(&1) and &1 >= 0))
    |> required(attrs, :expected_head, &Prima.Identity.Encoding.digest?/1)
    |> required(attrs, :kit_seed_sealed, &nonempty_binary?/1)
    |> row(
      attrs,
      ~w(user_id identifier directory_url entry request_digest expected_revision expected_head kit_seed_sealed)a
    )
  end

  defp build(%{kind: "rotation"} = attrs) do
    []
    |> required(attrs, :request_id, &Prima.Identity.Encoding.id?/1)
    |> required(attrs, :user_id, &nonempty?/1)
    |> required(attrs, :entry, &bytes?/1)
    |> required(attrs, :entry_hash, &Prima.Identity.Encoding.digest?/1)
    |> required(attrs, :expected_head, &Prima.Identity.Encoding.digest?/1)
    |> required(attrs, :staged_live_public_key, &key?/1)
    |> required(attrs, :staged_live_key_sealed, &nonempty_binary?/1)
    |> row(
      Map.put(attrs, :request_digest, attrs[:entry_hash]),
      ~w(user_id entry entry_hash expected_head request_digest staged_live_public_key staged_live_key_sealed)a
    )
  end

  defp build(%{kind: "restore"} = attrs) do
    []
    |> required(attrs, :request_id, &Prima.Identity.Encoding.id?/1)
    |> required(attrs, :identifier, &Prima.Identity.Encoding.identifier?/1)
    |> required(attrs, :directory_url, &Prima.Identity.Encoding.directory_url?/1)
    |> required(attrs, :entry, &bytes?/1)
    |> required(attrs, :request_digest, &Prima.Identity.Encoding.digest?/1)
    |> required(attrs, :expected_revision, &(is_integer(&1) and &1 >= 0))
    |> required(attrs, :token_digest, &Prima.Identity.Encoding.digest?/1)
    |> required(attrs, :staged_live_public_key, &key?/1)
    |> required(attrs, :staged_operational_public_key, &key?/1)
    |> required(attrs, :staged_live_key_sealed, &nonempty_binary?/1)
    |> required(attrs, :staged_operational_key_sealed, &nonempty_binary?/1)
    |> optional(attrs, :genesis, &bytes?/1)
    |> row(
      attrs,
      ~w(identifier directory_url entry request_digest expected_revision token_digest genesis)a ++
        @staged_columns
    )
  end

  defp build(_attrs),
    do: {:error, {:invalid, %{kind: ["is enrollment, holder, restore or rotation"]}}}

  defp row([], attrs, fields) do
    now = DateTime.utc_now()

    {:ok,
     Map.merge(
       %{
         id: Prima.UUID7.generate_id("iat"),
         kind: attrs.kind,
         request_id: attrs.request_id,
         phase: "staged",
         user_id: nil,
         identifier: nil,
         directory_url: nil,
         genesis: nil,
         entry: nil,
         entry_hash: nil,
         expected_head: nil,
         expected_revision: nil,
         token_digest: nil,
         staged_live_public_key: nil,
         staged_operational_public_key: nil,
         staged_live_key_sealed: nil,
         staged_operational_key_sealed: nil,
         kit_seed_sealed: nil,
         revision: 1,
         inserted_at: now,
         updated_at: now
       },
       Map.take(attrs, fields)
     )}
  end

  defp row(errors, _attrs, _fields), do: {:error, {:invalid, Map.new(errors)}}

  defp required(errors, attrs, field, valid?) do
    if valid?.(Map.get(attrs, field)), do: errors, else: [{field, ["is required"]} | errors]
  end

  defp optional(errors, attrs, field, valid?) do
    case Map.get(attrs, field) do
      nil -> errors
      value -> if valid?.(value), do: errors, else: [{field, ["is malformed"]} | errors]
    end
  end

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp nonempty_binary?(value), do: is_binary(value) and value != ""

  defp bytes?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= Prima.Identity.max_entry_bytes()

  defp key?(value), do: is_binary(value) and byte_size(value) == 32

  # A caller's instant stored at the column's microsecond precision,
  # whatever precision it arrived with.
  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}

  # Opening and advancing an attempt widen what a person's identity may do,
  # so each transaction first proves this member still owns its slot
  # (`Arca.ControlPlane.verify_held/1`): a stale owner writes nothing.
  defp fenced(write) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot() do
      Arca.Repo.locking_transaction(fn ->
        case Arca.ControlPlane.verify_held(slot) do
          :ok -> committed(write.())
          :lost -> Arca.Repo.rollback(:not_owner)
        end
      end)
    end
  end

  defp committed({:ok, value}), do: value
  defp committed({:error, reason}), do: Arca.Repo.rollback(reason)
end
