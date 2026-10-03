# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.FileOffers do
  @moduledoc """
  Sending a copy: a person's offer of files to another, and the
  recipient's acceptance of it into their own tree.

  ## The offer

  `offer/3` takes the sender's actor, the recipient's person id and files
  under `data/`. The two must sit together in an active athanor
  (`Arca.Members.shared_athanor?/3`, asked under the platform's actor).
  Each file's bytes are copied at once into the sender's reserved
  `payloads/offers/<offer id>/`, a snapshot counted against the sender's
  storage cap, and one `file_offers` row per file, in the sender's
  athanor, records its name, digest, size and expiry
  (`file_offer_days`, at most `Arca.Retention.FileOffers.max_days/0`).
  The snapshot is released by the offer's end —
  acceptance, decline, withdrawal or expiry — or by the `file_offers`
  retention kind, never by the staging sweep. `inbox/1` and `outbox/1`
  list a person's incoming and outgoing offers.

  ## Acceptance moves custody first

  `accept/3` takes the recipient's actor, the offer id and a folder under
  `data/`, in four steps, so a purged sender cannot strand the transfer:

    1. the recipient's cap is asked once for twice the offer's size (the
       custody copy and the published file coexist until the copy is
       released), and the bytes are copied from the sender's snapshot into
       the recipient's reserved
       `payloads/receipts/<offer id>/<attempt>/`, under a token of this
       acceptance's own, inside the internal-write scope, as a charged
       tenant write;
    2. one transaction, refused `:not_owner` when this member no longer
       owns its slot (`Arca.ControlPlane`), inserts a `file_receipts` row
       per file in the recipient's athanor (`received`, recording its
       custody copy's path in `custody_path`) and turns the offer
       `offered` → `accepted` by a conditional write; the sender's
       snapshot is released after it commits, and from here the receipt
       alone drives what follows;
    3. publication (`complete/2`) writes `<folder>/<offer id>[-<n>]/<filename>`
       from the custody copy by conditional create
       (`Arca.put_if_none_match/4`), an ordinary cap-checked tenant write
       that never overwrites; success marks the receipt `published`;
    4. the receipt is marked `completed` under the completer's claim, then
       its custody copy is released inside the internal-write scope (a
       release that fails is left to the receipts sweep).

  ## Ownership of a publication

  `complete/2` claims the receipt first (`completing_by`, the member's
  generation and a random token, until `completing_until`, a short lease
  on database time) by a conditional write, or answers `{:error, :busy}`.
  Every row write after it is conditional on that claim and on the status
  it read; a refused one ends the call with nothing released. Before its
  first write a completer records the path it will write (`attempt_path`,
  `attempt_state: chosen`): the files of one offer share one folder, so a
  receipt takes the folder another receipt of its offer already recorded
  (the lowest index, when one file has moved on a conflict of its own),
  and only when none has, the first index whose folder does not exist.
  It marks the path `issued` immediately before sending the create,
  appending it to `issued_paths` and setting `ever_issued` in the same
  row write.
  A completer that finds a write was ever sent reconciles before writing:
  it reads the current path when it is `issued`, or every path in
  `issued_paths` when the current one is `chosen`, under the recipient's
  actor; bytes whose digest is the transfer's mean the transfer is
  published there; other bytes at the current `issued` path mean the path
  is someone else's (or the transfer's own file already edited), and the
  next index is recorded `chosen`; `:not_found` keeps the same path and
  sends the same conditional create again, safe in either order. A create
  answering `:exists` or `{:error, :unknown}` returns to that
  reconciliation. Only an actual write asks the cap for space, at most one
  hundred indices are tried, and a cap refusal or a read that cannot
  answer leaves the row as it was for the next sweep. The claim is cleared
  last. A custody copy is released only once its receipt is recorded
  `completed` under the completer's claim, after `published`, so a wrong
  guess costs a second folder, never the transfer, and a completer whose
  claim was taken releases nothing.

  Two acceptances of one offer — a repeated submit — copy into two
  attempt paths, and at most one commits. One that fails releases only
  the copies it wrote, never the path a committed receipt records;
  publication, release and the receipts sweep each reach a custody copy
  by its receipt's `custody_path`, and a copy no receipt names is
  released by the sweep after a day.

  `decline/2` (recipient) and `withdraw/2` (sender) are conditional status
  writes from `offered`, so an acceptance racing either is decided by
  whichever lands first; each releases the snapshot. `expire/1` ends the
  actor's athanor's offers past their expiry.

  Every durable offer transition emits `[:cyfr, :arca, :file_offer, kind]`
  once after it commits, per file, with the offer id, the kind, the
  sender's and recipient's ids and the filename, never content.
  """

  import Ecto.Query

  require Logger

  alias Arca.Schemas.FileOffer
  alias Arca.Schemas.FileReceipt

  @lease_ms 30_000
  @max_index 100
  @orphan_age_s 86_400

  @typedoc "One file of an offer, as callers see it."
  @type offer_row :: %{
          id: String.t(),
          offer_id: String.t(),
          sender_user_id: String.t(),
          recipient_user_id: String.t(),
          filename: String.t(),
          digest: String.t(),
          size: non_neg_integer(),
          status: String.t(),
          expires_at: DateTime.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @typedoc "One accepted file, as callers see it."
  @type receipt :: %{
          id: String.t(),
          offer_id: String.t(),
          sender_user_id: String.t(),
          recipient_user_id: String.t(),
          filename: String.t(),
          digest: String.t(),
          size: non_neg_integer(),
          folder: String.t(),
          status: String.t(),
          attempt_path: String.t() | nil,
          attempt_state: String.t() | nil,
          issued_paths: [String.t()],
          ever_issued: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defguardp resolved(athanor_id) when is_binary(athanor_id) and athanor_id != ""

  # ---------------------------------------------------------------------------
  # Offer
  # ---------------------------------------------------------------------------

  @doc """
  Offer `files` (paths under `data/`, as segment lists or `/`-joined
  strings) to the person `recipient_user_id`.

  Refusals, each before anything is written: `{:error, :no_files}`;
  `{:error, {:outside_data, path}}` for a path not under `data/`;
  `{:error, :duplicate_filename}` for two files of one name;
  `{:error, {:too_large, filename}}` for a file over
  `Arca.Files.max_write/0`; `{:error, :not_shared}` when the two share no
  active athanor; the sender's storage cap's refusal; and a read's own
  error. A snapshot write that fails releases what it wrote; an insert
  the database did not answer (`{:error, :database_error}`) leaves the
  snapshot to the offers sweep, since its rows may have landed. Answers
  the offer id, its files and its expiry.
  """
  @spec offer(Prima.Actor.t(), String.t(), [Arca.Storage.path() | String.t()]) ::
          {:ok, %{offer_id: String.t(), expires_at: DateTime.t(), files: [offer_row()]}}
          | {:error, term()}
  def offer(%Prima.Actor{athanor_id: athanor_id, user_id: sender} = actor, recipient, files)
      when resolved(athanor_id) and is_binary(sender) and sender != "" and
             is_binary(recipient) and recipient != "" and is_list(files) do
    with {:ok, sources} <- sources(files),
         :ok <- shared(sender, recipient),
         {:ok, contents} <- read_sources(actor, sources),
         :ok <- Prima.Caps.check_storage(actor, total(contents)),
         {:ok, expires_at} <- expiry(actor) do
      offer_id = Prima.UUID7.generate_id("ofr")

      case write_snapshot(actor, offer_id, contents) do
        :ok ->
          case insert_offer(actor, offer_id, recipient, contents, expires_at) do
            {:ok, rows} ->
              Enum.each(rows, &announce(:offered, &1))

              {:ok,
               %{offer_id: offer_id, expires_at: expires_at, files: Enum.map(rows, &offer_view/1)}}

            # The insert is not known to have rolled back (`:database_error`:
            # a connection lost at COMMIT among others), and rows it landed
            # name the snapshot, so the snapshot is left to the offers sweep,
            # which releases one no offer row names only after a day and one
            # an offer names only once it has ended.
            {:error, _} = error ->
              error
          end

        # No row was written, so nothing names the snapshot's bytes.
        {:error, _} = error ->
          release_snapshot(actor, offer_id)
          error
      end
    end
  end

  def offer(%Prima.Actor{}, recipient, files) when is_binary(recipient) and is_list(files),
    do: {:error, :no_athanor}

  @doc "The offers addressed to the actor's person, newest first, from any sender."
  @spec inbox(Prima.Actor.t()) :: {:ok, [offer_row()]} | {:error, term()}
  # arca:unscoped-ok a person's incoming offers cross senders' athanors and are addressed by person
  def inbox(%Prima.Actor{user_id: user_id}) when is_binary(user_id) and user_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.inbox", fn ->
      rows =
        from(o in FileOffer,
          where: o.recipient_user_id == ^user_id,
          order_by: [desc: o.inserted_at, asc: o.filename]
        )
        |> Arca.Repo.all()

      {:ok, Enum.map(rows, &offer_view/1)}
    end)
  end

  def inbox(%Prima.Actor{}), do: {:error, :no_person}

  @doc "The offers the actor's person sent from the actor's athanor, newest first."
  @spec outbox(Prima.Actor.t()) :: {:ok, [offer_row()]} | {:error, term()}
  def outbox(%Prima.Actor{athanor_id: athanor_id, user_id: user_id})
      when resolved(athanor_id) and is_binary(user_id) and user_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.outbox", fn ->
      rows =
        from(o in FileOffer,
          where: o.sender_user_id == ^user_id,
          order_by: [desc: o.inserted_at, asc: o.filename]
        )
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()

      {:ok, Enum.map(rows, &offer_view/1)}
    end)
  end

  def outbox(%Prima.Actor{}), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # Accept, decline, withdraw, expire
  # ---------------------------------------------------------------------------

  @doc """
  Accept the offer `offer_id` into `folder` (under `data/`) of the actor's
  athanor, by the module doc's four steps, then complete each receipt.

  Refusals, with nothing copied or placed: `{:error, :not_owner}` when
  this member no longer owns its slot; `{:error, {:outside_data, folder}}`;
  `{:error, :not_found}` for an offer not addressed to the actor's person;
  `{:error, {:not_offered, status}}` for one no longer `offered`
  (`expired` past its expiry); the recipient's cap's refusal of twice the
  offer's size. An offer that ended between the copy and the commit is
  `{:error, {:not_offered, status}}` and its custody copy is released; an
  acceptance whose commit the database did not answer
  (`{:error, :database_error}`) leaves its copy to the orphan sweep, since
  the commit may have landed.
  Answers the receipts as they stand after their completion was tried.
  """
  @spec accept(Prima.Actor.t(), String.t(), Arca.Storage.path() | String.t()) ::
          {:ok, %{offer_id: String.t(), folder: String.t(), receipts: [receipt()]}}
          | {:error, term()}
  def accept(%Prima.Actor{athanor_id: athanor_id, user_id: user_id} = actor, offer_id, folder)
      when resolved(athanor_id) and is_binary(user_id) and user_id != "" and is_binary(offer_id) do
    attempt = attempt_token()

    with {:ok, slot} <- Arca.ControlPlane.member_slot(),
         {:ok, folder} <- data_folder(folder),
         {:ok, rows} <- custody(actor, offer_id, attempt) do
      case commit_acceptance(actor, slot, rows, folder, attempt) do
        {:ok, receipts} ->
          release_snapshot(sender_actor(rows), offer_id)
          Enum.each(rows, &announce(:accepted, %{&1 | status: "accepted"}))

          for receipt <- receipts, do: complete(actor, receipt.id)

          {:ok,
           %{
             offer_id: offer_id,
             folder: Enum.join(folder, "/"),
             receipts: Enum.map(receipts, &reread(actor, &1))
           }}

        # A refusal the transaction rolled back is definite: no receipt
        # names this attempt's copy, so it goes now. An outcome the
        # database did not answer (`:database_error`: a connection lost at
        # COMMIT among others) may have committed receipts that name the
        # copy, so it is left to the orphan sweep, which releases only a
        # copy no receipt names, after a day.
        {:error, :database_error} = error ->
          error

        {:error, _} = error ->
          release_attempt(actor, rows, attempt)
          error
      end
    end
  end

  def accept(%Prima.Actor{}, offer_id, _folder) when is_binary(offer_id),
    do: {:error, :no_athanor}

  @doc """
  Decline the offer `offer_id` addressed to the actor's person: a
  conditional write from `offered`, releasing the sender's snapshot.
  `{:error, :not_found}` or `{:error, {:not_offered, status}}` otherwise.
  """
  @spec decline(Prima.Actor.t(), String.t()) :: :ok | {:error, term()}
  # arca:unscoped-ok a person's incoming offers cross senders' athanors and are addressed by person
  def decline(%Prima.Actor{user_id: user_id}, offer_id)
      when is_binary(user_id) and user_id != "" and is_binary(offer_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.decline", fn ->
      now = now()

      declined =
        from(o in FileOffer,
          where:
            o.offer_id == ^offer_id and o.recipient_user_id == ^user_id and o.status == "offered",
          select: o
        )
        |> Arca.Repo.update_all(set: [status: "declined", updated_at: now])

      case declined do
        {0, _} ->
          from(o in FileOffer,
            where: o.offer_id == ^offer_id and o.recipient_user_id == ^user_id,
            select: o.status,
            limit: 1
          )
          |> Arca.Repo.one()
          |> not_ended()

        {_count, rows} ->
          after_end(rows || [])
          :ok
      end
    end)
  end

  def decline(%Prima.Actor{}, offer_id) when is_binary(offer_id), do: {:error, :no_person}

  @doc """
  Withdraw the offer `offer_id` the actor's person sent from the actor's
  athanor: a conditional write from `offered`, releasing the snapshot. An
  accepted offer is not withdrawn (`{:error, {:not_offered, "accepted"}}`)
  and its copy stands.
  """
  @spec withdraw(Prima.Actor.t(), String.t()) :: :ok | {:error, term()}
  def withdraw(%Prima.Actor{athanor_id: athanor_id, user_id: user_id}, offer_id)
      when resolved(athanor_id) and is_binary(user_id) and user_id != "" and is_binary(offer_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.withdraw", fn ->
      query =
        from(o in FileOffer,
          where:
            o.athanor_id == ^athanor_id and o.offer_id == ^offer_id and
              o.sender_user_id == ^user_id and o.status == "offered"
        )

      case Arca.Repo.update_all(from(o in query, select: o),
             set: [status: "withdrawn", updated_at: now()]
           ) do
        {0, _} ->
          from(o in FileOffer,
            where:
              o.athanor_id == ^athanor_id and o.offer_id == ^offer_id and
                o.sender_user_id == ^user_id,
            select: o.status,
            limit: 1
          )
          |> Arca.Repo.one()
          |> not_ended()

        {_count, rows} ->
          after_end(rows || [])
          :ok
      end
    end)
  end

  def withdraw(%Prima.Actor{}, offer_id) when is_binary(offer_id), do: {:error, :no_athanor}

  @doc """
  End the actor's athanor's offers past their expiry (database time):
  `offered` → `expired`, each snapshot released once. Answers how many
  files' offers ended; `dry_run: true` counts without writing.
  """
  @spec expire(Prima.Actor.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def expire(actor, opts \\ [])

  def expire(%Prima.Actor{athanor_id: athanor_id}, opts)
      when resolved(athanor_id) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.expire", fn ->
      now = Arca.ServerMetaStorage.now!()

      query =
        from(o in FileOffer,
          where: o.athanor_id == ^athanor_id and o.status == "offered" and o.expires_at <= ^now
        )

      if Keyword.get(opts, :dry_run, false) do
        {:ok, Arca.Repo.aggregate(query, :count)}
      else
        {_count, rows} =
          Arca.Repo.update_all(from(o in query, select: o),
            set: [status: "expired", updated_at: now]
          )

        rows = rows || []
        after_end(rows)
        {:ok, length(rows)}
      end
    end)
  end

  def expire(%Prima.Actor{}, opts) when is_list(opts), do: {:error, :no_athanor}

  @doc false
  # Inside a deny's transaction (`Arca.SecurityTransitions`): every offer
  # the person sent is withdrawn and every offer addressed to them
  # declined, by conditional writes from `offered`. Answers the rows ended,
  # for `after_end/1` once the transaction commits.
  @spec end_for_person!(String.t()) :: [FileOffer.t()]
  # arca:db-raise-ok a step inside the caller's transaction; a raise rolls it back.
  # arca:unscoped-ok a denied person's offers are ended in every athanor:
  # the person's sent and incoming offers cross athanors and are keyed by
  # the person.
  def end_for_person!(user_id) when is_binary(user_id) and user_id != "" do
    now = now()

    {_sent, withdrawn} =
      from(o in FileOffer,
        where: o.sender_user_id == ^user_id and o.status == "offered",
        select: o
      )
      |> Arca.Repo.update_all(set: [status: "withdrawn", updated_at: now])

    {_incoming, declined} =
      from(o in FileOffer,
        where: o.recipient_user_id == ^user_id and o.status == "offered",
        select: o
      )
      |> Arca.Repo.update_all(set: [status: "declined", updated_at: now])

    (withdrawn || []) ++ (declined || [])
  end

  @doc false
  # After a transition that ended offers commits: each snapshot released
  # and each file's transition announced.
  @spec after_end([FileOffer.t()]) :: :ok
  def after_end(rows) when is_list(rows) do
    rows
    |> Enum.uniq_by(&{&1.athanor_id, &1.offer_id})
    |> Enum.each(&release_snapshot(Prima.Actor.in_athanor(&1.athanor_id), &1.offer_id))

    Enum.each(rows, &announce(String.to_existing_atom(&1.status), &1))
  end

  # ---------------------------------------------------------------------------
  # Complete
  # ---------------------------------------------------------------------------

  @doc """
  Drive the receipt `receipt_id` of the actor's athanor towards
  `completed`, by the module doc's claim and reconciliation.

  Answers the receipt once it is `completed` (or already `failed`).
  `{:error, :busy}` when another completer holds it; `{:error,
  :claim_lost}` when another took it over mid-way (this call then
  released nothing); `{:error, :not_found}`; and, with the row left as it
  was for the next sweep, the cap's refusal of a write,
  `{:error, {:unavailable, reason}}` for a read that could not answer,
  `{:error, :no_free_index}` past the hundredth folder.
  """
  @spec complete(Prima.Actor.t(), String.t()) :: {:ok, receipt()} | {:error, term()}
  def complete(%Prima.Actor{athanor_id: athanor_id} = actor, receipt_id)
      when resolved(athanor_id) and is_binary(receipt_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.complete", fn ->
      case claim(athanor_id, receipt_id) do
        {:claimed, row, token} ->
          result = drive(actor, row, token, 2 * @max_index)

          case result do
            {:error, :claim_lost} = lost ->
              lost

            _held ->
              unclaim(athanor_id, receipt_id, token)

              case result do
                {:done, row} -> {:ok, receipt_view(row)}
                {:stop, reason} -> {:error, reason}
              end
          end

        {:done, row} ->
          {:ok, receipt_view(row)}

        {:error, _} = error ->
          error
      end
    end)
  end

  def complete(%Prima.Actor{}, receipt_id) when is_binary(receipt_id), do: {:error, :no_athanor}

  @doc "The receipts of the actor's athanor, newest first; `status:` narrows to one state."
  @spec receipts(Prima.Actor.t(), keyword()) :: {:ok, [receipt()]} | {:error, term()}
  def receipts(%Prima.Actor{athanor_id: athanor_id}, opts \\ [])
      when resolved(athanor_id) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.receipts", fn ->
      query =
        from(r in FileReceipt, order_by: [desc: r.inserted_at, asc: r.filename])
        |> Arca.QueryHelpers.where_athanor(athanor_id)

      query =
        case Keyword.get(opts, :status) do
          nil -> query
          status when is_binary(status) -> where(query, [r], r.status == ^status)
        end

      {:ok, Enum.map(Arca.Repo.all(query), &receipt_view/1)}
    end)
  end

  @doc false
  # The receipts retention kind's failure of a transfer for which no write
  # was ever sent, received before `cutoff` and held by no live claim: the
  # receipt is `failed` and its custody copy released. One with a write
  # ever sent is never failed, whatever its age.
  @spec fail_stale(Prima.Actor.t(), DateTime.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def fail_stale(%Prima.Actor{athanor_id: athanor_id} = actor, %DateTime{} = cutoff, dry_run)
      when resolved(athanor_id) and is_boolean(dry_run) do
    Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.fail_stale", fn ->
      now = Arca.ServerMetaStorage.now!()

      query =
        from(r in FileReceipt,
          where:
            r.athanor_id == ^athanor_id and r.status == "received" and
              r.ever_issued == false and r.inserted_at < ^cutoff and
              (is_nil(r.completing_by) or r.completing_until <= ^now)
        )

      if dry_run do
        {:ok, Arca.Repo.aggregate(query, :count)}
      else
        {_count, rows} =
          Arca.Repo.update_all(from(r in query, select: r),
            set: [status: "failed", completing_by: nil, completing_until: nil, updated_at: now]
          )

        rows = rows || []

        for row <- rows do
          release_custody(actor, row)

          Logger.warning(
            "[Arca.FileOffers] receipt #{row.id} of offer #{row.offer_id} failed: " <>
              "never published within the retention window, custody released"
          )
        end

        {:ok, length(rows)}
      end
    end)
  end

  @doc false
  # The receipts' custody copies a retention sweep may release: those of
  # `completed` or `failed` receipts, by the path each receipt records, and
  # those no receipt row names that are older than a day. Answers how many
  # went (or would).
  @spec sweep_custody(Prima.Actor.t(), boolean()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_custody(%Prima.Actor{athanor_id: athanor_id} = actor, dry_run)
      when resolved(athanor_id) and is_boolean(dry_run) do
    with {:ok, keys} <- Arca.Storage.list_prefix(actor, Arca.Storage.receipts_prefix()) do
      Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.sweep_custody", fn ->
        states = receipt_states(athanor_id, keys)

        released =
          Enum.count(keys, fn key ->
            releasable?(actor, key, states) and (dry_run or delete_reserved(actor, key) == :ok)
          end)

        {:ok, released}
      end)
    end
  end

  @doc false
  # The offers' snapshots a retention sweep may release: those of offers
  # that ended, and those no offer row names that are older than a day.
  @spec sweep_snapshots(Prima.Actor.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sweep_snapshots(%Prima.Actor{athanor_id: athanor_id} = actor, dry_run)
      when resolved(athanor_id) and is_boolean(dry_run) do
    with {:ok, keys} <- Arca.Storage.list_prefix(actor, Arca.Storage.offers_prefix()) do
      Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.sweep_snapshots", fn ->
        offers = keys |> Enum.map(&Enum.at(&1, 2)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
        states = offer_states(athanor_id, offers)

        released =
          Enum.count(keys, fn key ->
            snapshot_releasable?(actor, key, states) and
              (dry_run or delete_reserved(actor, key) == :ok)
          end)

        {:ok, released}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Offer internals
  # ---------------------------------------------------------------------------

  defp sources([]), do: {:error, :no_files}

  defp sources(files) do
    files
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case data_path(file) do
        {:ok, segments} -> {:cont, {:ok, [{segments, List.last(segments)} | acc]}}
        :error -> {:halt, {:error, {:outside_data, file}}}
      end
    end)
    |> case do
      {:ok, sources} ->
        sources = Enum.reverse(sources)
        names = Enum.map(sources, &elem(&1, 1))

        if length(Enum.uniq(names)) == length(names),
          do: {:ok, sources},
          else: {:error, :duplicate_filename}

      error ->
        error
    end
  end

  # A file under `data/`, at least one segment below it, every segment
  # safe.
  defp data_path(path) do
    with {:ok, ["data", _ | _] = segments} <- segments(path),
         :ok <- Prima.PathSafety.validate_segments(segments) do
      {:ok, segments}
    else
      _ -> :error
    end
  end

  # A folder under `data/`, `data` itself included.
  defp data_folder(folder) do
    with {:ok, ["data" | _] = segments} <- segments(folder),
         :ok <- Prima.PathSafety.validate_segments(segments) do
      {:ok, segments}
    else
      _ -> {:error, {:outside_data, folder}}
    end
  end

  defp segments(path) when is_binary(path),
    do: {:ok, path |> String.split("/") |> Enum.reject(&(&1 == ""))}

  defp segments(path) when is_list(path) do
    if Enum.all?(path, &is_binary/1),
      do:
        {:ok, Enum.flat_map(path, &(&1 |> String.split("/") |> Enum.reject(fn s -> s == "" end)))},
      else: :error
  end

  defp segments(_path), do: :error

  defp shared(sender, recipient) do
    case Arca.Members.shared_athanor?(Prima.Actor.system(), sender, recipient) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :not_shared}
      {:error, _} = error -> error
    end
  end

  defp read_sources(actor, sources) do
    max = Arca.Files.max_write()

    Enum.reduce_while(sources, {:ok, []}, fn {segments, filename}, {:ok, acc} ->
      case Arca.get(actor, segments) do
        {:ok, bytes} when byte_size(bytes) > max ->
          {:halt, {:error, {:too_large, filename}}}

        {:ok, bytes} ->
          {:cont, {:ok, [{filename, bytes} | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, contents} -> {:ok, Enum.reverse(contents)}
      error -> error
    end
  end

  defp total(contents),
    do: Enum.reduce(contents, 0, fn {_name, bytes}, acc -> acc + byte_size(bytes) end)

  defp expiry(actor) do
    with {:ok, settings} <- Arca.Retention.get_settings(actor) do
      days =
        min(
          Map.fetch!(settings, Arca.Retention.FileOffers.key()),
          Arca.Retention.FileOffers.max_days()
        )

      Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.expiry", fn ->
        {:ok, DateTime.add(Arca.ServerMetaStorage.now!(), days * 86_400, :second)}
      end)
    end
  end

  defp write_snapshot(actor, offer_id, contents) do
    Arca.Overlay.with_internal_writes(fn ->
      Enum.reduce_while(contents, :ok, fn {filename, bytes}, :ok ->
        case Arca.put(actor, snapshot_path(offer_id, filename), bytes) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end)
  end

  defp insert_offer(
         %Prima.Actor{athanor_id: athanor_id, user_id: sender},
         offer_id,
         recipient,
         contents,
         expires_at
       ) do
    Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.offer", fn ->
      now = now()

      rows =
        for {filename, bytes} <- contents do
          %{
            id: Prima.UUID7.generate_id("fof"),
            athanor_id: athanor_id,
            offer_id: offer_id,
            sender_user_id: sender,
            recipient_user_id: recipient,
            filename: filename,
            digest: Prima.Digest.sha256(bytes),
            size: byte_size(bytes),
            status: "offered",
            expires_at: DateTime.truncate(expires_at, :microsecond),
            inserted_at: now,
            updated_at: now
          }
        end

      {count, _} = Arca.Repo.insert_all(FileOffer, rows)

      if count == length(rows),
        do: {:ok, Enum.map(rows, &struct(FileOffer, &1))},
        else: {:error, :partial_insert}
    end)
  end

  # ---------------------------------------------------------------------------
  # Accept internals
  # ---------------------------------------------------------------------------

  # The offer's rows addressed to the actor's person, still `offered`
  # and unexpired, then steps 1's cap check and copy: the bytes read from
  # the sender's snapshot, held to each row's digest, and written into the
  # recipient's custody under this acceptance's `attempt`. Nothing is
  # copied unless every file can be.
  # arca:unscoped-ok an accepted offer's bytes cross from the sender's snapshot into the recipient's custody, under the offer row
  defp custody(%Prima.Actor{user_id: user_id} = actor, offer_id, attempt) do
    result =
      Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.accept", fn ->
        now = Arca.ServerMetaStorage.now!()

        rows =
          from(o in FileOffer,
            where: o.offer_id == ^offer_id and o.recipient_user_id == ^user_id,
            order_by: o.filename
          )
          |> Arca.Repo.all()

        {:ok, rows, now}
      end)

    with {:ok, rows, now} <- result,
         :ok <- acceptable(rows, now),
         :ok <- Prima.Caps.check_storage(actor, 2 * Enum.reduce(rows, 0, &(&1.size + &2))),
         {:ok, contents} <- read_snapshot(rows) do
      copied =
        Arca.Overlay.with_internal_writes(fn ->
          Enum.reduce_while(contents, :ok, fn {row, bytes}, :ok ->
            case Arca.put(actor, custody_path(row.offer_id, attempt, row.filename), bytes) do
              :ok -> {:cont, :ok}
              {:error, _} = error -> {:halt, error}
            end
          end)
        end)

      case copied do
        :ok ->
          {:ok, rows}

        {:error, _} = error ->
          release_attempt(actor, rows, attempt)
          error
      end
    end
  end

  defp acceptable([], _now), do: {:error, :not_found}

  defp acceptable(rows, now) do
    cond do
      Enum.any?(rows, &(&1.status != "offered")) ->
        {:error, {:not_offered, Enum.find(rows, &(&1.status != "offered")).status}}

      Enum.any?(rows, &(DateTime.compare(&1.expires_at, now) != :gt)) ->
        {:error, {:not_offered, "expired"}}

      true ->
        :ok
    end
  end

  # The one cross-tenant storage read: the sender's snapshot, by the offer
  # row that names it, held to the row's digest.
  defp read_snapshot(rows) do
    sender = sender_actor(rows)

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case Arca.get(sender, snapshot_path(row.offer_id, row.filename)) do
        {:ok, bytes} ->
          if Prima.Digest.sha256(bytes) == row.digest,
            do: {:cont, {:ok, [{row, bytes} | acc]}},
            else: {:halt, {:error, :snapshot_corrupt}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, contents} -> {:ok, Enum.reverse(contents)}
      error -> error
    end
  end

  # Step 2: the receipts and the offer's turn to `accepted`, in one
  # transaction that first proves this member still owns its slot.
  defp commit_acceptance(%Prima.Actor{athanor_id: athanor_id}, slot, rows, folder, attempt) do
    [first | _] = rows
    sender_athanor = first.athanor_id

    Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.accept", fn ->
      Arca.Repo.locking_transaction(fn ->
        with :ok <- owned(slot),
             now = Arca.ServerMetaStorage.now!(),
             {:ok, receipts} <- insert_receipts(athanor_id, rows, folder, attempt, now),
             :ok <- turn_accepted(sender_athanor, first.offer_id, length(rows), now) do
          receipts
        else
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
    end)
  end

  defp owned(slot) do
    case Arca.ControlPlane.verify_held(slot) do
      :ok -> :ok
      :lost -> {:error, :not_owner}
    end
  end

  defp insert_receipts(athanor_id, rows, folder, attempt, now) do
    receipts =
      for row <- rows do
        %{
          id: Prima.UUID7.generate_id("frc"),
          athanor_id: athanor_id,
          offer_id: row.offer_id,
          sender_user_id: row.sender_user_id,
          recipient_user_id: row.recipient_user_id,
          filename: row.filename,
          digest: row.digest,
          size: row.size,
          folder: Enum.join(folder, "/"),
          custody_path: Enum.join(custody_path(row.offer_id, attempt, row.filename), "/"),
          status: "received",
          issued_paths: "[]",
          ever_issued: false,
          inserted_at: now,
          updated_at: now
        }
      end

    {count, _} = Arca.Repo.insert_all(FileReceipt, receipts)

    if count == length(receipts),
      do: {:ok, Enum.map(receipts, &struct(FileReceipt, &1))},
      else: {:error, :partial_insert}
  end

  defp turn_accepted(sender_athanor, offer_id, files, now) do
    query =
      from(o in FileOffer,
        where:
          o.athanor_id == ^sender_athanor and o.offer_id == ^offer_id and
            o.status == "offered" and o.expires_at > ^now
      )

    case Arca.Repo.update_all(query, set: [status: "accepted", updated_at: now]) do
      {^files, _} ->
        :ok

      {_other, _} ->
        status =
          from(o in FileOffer,
            where:
              o.athanor_id == ^sender_athanor and o.offer_id == ^offer_id and
                o.status != "offered",
            select: o.status,
            limit: 1
          )
          |> Arca.Repo.one()

        {:error, {:not_offered, status || "expired"}}
    end
  end

  defp sender_actor([%FileOffer{athanor_id: athanor_id} | _]),
    do: Prima.Actor.in_athanor(athanor_id)

  # Why a decline or withdrawal that wrote nothing wrote nothing: no such
  # offer for the caller, or one no longer `offered`.
  defp not_ended(nil), do: {:error, :not_found}
  defp not_ended(status), do: {:error, {:not_offered, status}}

  # ---------------------------------------------------------------------------
  # Completion internals
  # ---------------------------------------------------------------------------

  # The claim: a conditional write of this completer's token and lease
  # where the row holds no live claim and still has work.
  defp claim(athanor_id, receipt_id) do
    now = Arca.ServerMetaStorage.now!()
    token = token()

    query =
      from(r in FileReceipt,
        where:
          r.id == ^receipt_id and r.athanor_id == ^athanor_id and
            r.status in ["received", "published"] and
            (is_nil(r.completing_by) or r.completing_until <= ^now),
        select: r
      )

    case Arca.Repo.update_all(query,
           set: [
             completing_by: token,
             completing_until: DateTime.add(now, @lease_ms, :millisecond)
           ]
         ) do
      {1, [row]} ->
        {:claimed, row, token}

      {0, _} ->
        case Arca.Repo.get_by(FileReceipt, id: receipt_id, athanor_id: athanor_id) do
          nil ->
            {:error, :not_found}

          %FileReceipt{status: status} = row when status in ["completed", "failed"] ->
            {:done, row}

          _held ->
            {:error, :busy}
        end
    end
  end

  defp unclaim(athanor_id, receipt_id, token) do
    from(r in FileReceipt,
      where: r.id == ^receipt_id and r.athanor_id == ^athanor_id and r.completing_by == ^token
    )
    |> Arca.Repo.update_all(set: [completing_by: nil, completing_until: nil])

    :ok
  end

  defp token do
    generation =
      case Arca.ControlPlane.generation() do
        {:ok, generation} -> Integer.to_string(generation)
        _none -> "0"
      end

    generation <> ":" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp drive(_actor, _row, _token, budget) when budget <= 0, do: {:stop, :no_free_index}

  defp drive(actor, %FileReceipt{status: "published"} = row, token, _budget),
    do: finish(actor, row, token)

  defp drive(_actor, %FileReceipt{status: status} = row, _token, _budget)
       when status in ["completed", "failed"],
       do: {:done, row}

  defp drive(actor, %FileReceipt{attempt_path: nil} = row, token, budget) do
    chosen =
      with {:ok, path} <- first_path(actor, row) do
        record(row, token, attempt_path: path, attempt_state: "chosen")
      end

    case chosen do
      {:ok, row} -> drive(actor, row, token, budget)
      refused -> stopped(refused)
    end
  end

  defp drive(actor, %FileReceipt{ever_issued: true} = row, token, budget),
    do: reconcile(actor, row, token, budget)

  defp drive(actor, row, token, budget), do: issue(actor, row, token, budget)

  # What a write ever sent may have left: the current path when it is
  # `issued`, every earlier issued path when the current one is `chosen`.
  defp reconcile(actor, row, token, budget) do
    current_issued? = row.attempt_state == "issued"
    paths = if current_issued?, do: [row.attempt_path], else: issued_paths(row)

    outcome =
      Enum.reduce_while(paths, :write, fn path, acc ->
        case Arca.get(actor, path_segments(path)) do
          {:ok, bytes} ->
            cond do
              Prima.Digest.sha256(bytes) == row.digest -> {:halt, {:published_at, path}}
              current_issued? and path == row.attempt_path -> {:cont, :moved}
              true -> {:cont, acc}
            end

          {:error, :not_found} ->
            {:cont, acc}

          {:error, reason} ->
            {:halt, {:unanswerable, reason}}
        end
      end)

    case outcome do
      {:published_at, path} ->
        case record(row, token, status: "published", attempt_path: path, attempt_state: "issued") do
          {:ok, row} -> drive(actor, row, token, budget)
          refused -> stopped(refused)
        end

      {:unanswerable, reason} ->
        {:stop, {:unavailable, reason}}

      :moved ->
        chosen =
          with {:ok, path} <- probe(actor, row, index_of(row) + 1) do
            record(row, token, attempt_path: path, attempt_state: "chosen")
          end

        case chosen do
          {:ok, row} -> issue(actor, row, token, budget - 1)
          refused -> stopped(refused)
        end

      :write ->
        issue(actor, row, token, budget)
    end
  end

  # Send the create for the recorded path: the cap asked for the file's
  # size, the attempt marked `issued` (and the path kept in
  # `issued_paths`, `ever_issued` set) in one row write, then the
  # conditional create from the custody copy, outside the internal-write
  # scope.
  defp issue(actor, row, token, budget) do
    path = row.attempt_path

    issued =
      with {:ok, bytes} <- custody_bytes(actor, row),
           :ok <- Prima.Caps.check_storage(actor, row.size),
           {:ok, row} <-
             record(row, token,
               attempt_state: "issued",
               issued_paths: Jason.encode!(Enum.uniq(issued_paths(row) ++ [path])),
               ever_issued: true
             ) do
        {:ok, row, Arca.put_if_none_match(actor, path_segments(path), bytes)}
      end

    case issued do
      {:ok, row, :ok} ->
        case record(row, token, status: "published") do
          {:ok, row} -> drive(actor, row, token, budget)
          refused -> stopped(refused)
        end

      {:ok, row, {:error, reason}} when reason in [:exists, :unknown] ->
        reconcile(actor, row, token, budget - 1)

      {:ok, _row, {:error, reason}} ->
        {:stop, reason}

      refused ->
        stopped(refused)
    end
  end

  # Step 4: `completed` is written under the claim before anything is
  # released, so a completer whose claim was taken stops having released
  # nothing. The custody copy goes after it; a release that fails is left
  # to the receipts sweep, which releases the copy of every completed
  # receipt.
  defp finish(actor, row, token) do
    case record(row, token, status: "completed") do
      {:ok, row} ->
        with {:error, reason} <- release_custody(actor, row) do
          Logger.warning(
            "[Arca.FileOffers] custody of receipt #{row.id} not released: #{inspect(reason)}; " <>
              "the receipts retention sweep takes it"
          )
        end

        {:done, row}

      refused ->
        stopped(refused)
    end
  end

  # A step that ended on a refusal ends the drive with it: a lost claim as
  # itself, anything else as the reason the row was left as it was.
  defp stopped({:error, :claim_lost} = lost), do: lost
  defp stopped({:error, reason}), do: {:stop, reason}
  defp stopped(other), do: other

  # A row write under the claim, from the status it was read in.
  defp record(%FileReceipt{} = row, token, changes) do
    now = now()

    query =
      from(r in FileReceipt,
        where:
          r.id == ^row.id and r.athanor_id == ^row.athanor_id and r.completing_by == ^token and
            r.status == ^row.status
      )

    case Arca.Repo.update_all(query, set: Keyword.put(changes, :updated_at, now)) do
      {1, _} -> {:ok, struct(row, Keyword.put(changes, :updated_at, now))}
      {0, _} -> {:error, :claim_lost}
    end
  end

  # The path a receipt's first attempt writes: its file in the folder the
  # offer's files share. A sibling receipt that recorded a folder names it;
  # otherwise the first index whose folder holds nothing does.
  defp first_path(actor, row) do
    case offer_folder(row) do
      nil -> probe(actor, row, 1)
      dir -> {:ok, Enum.join(path_segments(row.folder) ++ [dir, row.filename], "/")}
    end
  end

  # The folder the other receipts of the row's offer recorded, the lowest
  # index among them, or nil while none has recorded one.
  defp offer_folder(%FileReceipt{} = row) do
    from(r in FileReceipt,
      where:
        r.athanor_id == ^row.athanor_id and r.offer_id == ^row.offer_id and r.id != ^row.id and
          not is_nil(r.attempt_path),
      select: r.attempt_path
    )
    |> Arca.Repo.all()
    |> Enum.map(&%{row | attempt_path: &1})
    |> Enum.min_by(&index_of/1, fn -> nil end)
    |> case do
      nil -> nil
      sibling -> sibling.attempt_path |> path_segments() |> Enum.at(-2)
    end
  end

  # The first index from `from` whose folder holds nothing.
  defp probe(_actor, _row, from) when from > @max_index, do: {:error, :no_free_index}

  defp probe(actor, row, from) do
    folder = path_segments(row.folder)

    Enum.reduce_while(from..@max_index, {:error, :no_free_index}, fn index, acc ->
      case Arca.list_typed(actor, folder ++ [dir_name(row.offer_id, index)]) do
        {:ok, []} ->
          {:halt, {:ok, Enum.join(folder ++ [dir_name(row.offer_id, index), row.filename], "/")}}

        {:ok, _entries} ->
          {:cont, acc}

        {:error, :not_found} ->
          {:halt, {:ok, Enum.join(folder ++ [dir_name(row.offer_id, index), row.filename], "/")}}

        {:error, :enotdir} ->
          {:cont, acc}

        {:error, reason} ->
          {:halt, {:error, {:unavailable, reason}}}
      end
    end)
  end

  defp dir_name(offer_id, 1), do: offer_id
  defp dir_name(offer_id, index), do: "#{offer_id}-#{index}"

  defp index_of(%FileReceipt{attempt_path: path, offer_id: offer_id}) do
    dir = path |> path_segments() |> Enum.at(-2)

    case dir do
      ^offer_id ->
        1

      _ ->
        case Integer.parse(String.replace_prefix(dir, offer_id <> "-", "")) do
          {index, ""} -> index
          _ -> 1
        end
    end
  end

  defp issued_paths(%FileReceipt{issued_paths: json}) do
    case Jason.decode(json || "[]") do
      {:ok, paths} when is_list(paths) -> Enum.filter(paths, &is_binary/1)
      _ -> []
    end
  end

  defp custody_bytes(actor, row) do
    case Arca.get(actor, path_segments(row.custody_path)) do
      {:ok, bytes} ->
        if Prima.Digest.sha256(bytes) == row.digest,
          do: {:ok, bytes},
          else: {:error, :custody_corrupt}

      {:error, :not_found} ->
        {:error, :custody_missing}

      {:error, reason} ->
        {:error, {:unavailable, reason}}
    end
  end

  defp reread(%Prima.Actor{athanor_id: athanor_id}, %FileReceipt{id: id} = row) do
    case Arca.Repo.Errors.with_db_rescue("Arca.FileOffers.accept", fn ->
           {:ok, Arca.Repo.get_by(FileReceipt, id: id, athanor_id: athanor_id)}
         end) do
      {:ok, %FileReceipt{} = fresh} -> receipt_view(fresh)
      _ -> receipt_view(row)
    end
  end

  # ---------------------------------------------------------------------------
  # Retention internals
  # ---------------------------------------------------------------------------

  # The status of each receipt of the listed offers, by the custody path
  # it records.
  defp receipt_states(athanor_id, keys) do
    offers = keys |> Enum.map(&Enum.at(&1, 2)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(r in FileReceipt,
      where: r.athanor_id == ^athanor_id and r.offer_id in ^offers,
      select: {r.custody_path, r.status}
    )
    |> Arca.Repo.all()
    |> Map.new()
  end

  defp releasable?(actor, key, states) do
    case Map.get(states, Enum.join(key, "/")) do
      nil -> aged?(actor, key)
      status -> status in ["completed", "failed"]
    end
  end

  defp offer_states(_athanor_id, []), do: %{}

  defp offer_states(athanor_id, offers) do
    from(o in FileOffer,
      where: o.athanor_id == ^athanor_id and o.offer_id in ^offers,
      select: {o.offer_id, o.status}
    )
    |> Arca.Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp snapshot_releasable?(actor, ["payloads", "offers", offer_id | _] = key, states) do
    case Map.get(states, offer_id) do
      nil -> aged?(actor, key)
      statuses -> not Enum.member?(statuses, "offered")
    end
  end

  defp snapshot_releasable?(_actor, _key, _states), do: false

  # Bytes no row names are kept for a day by the store's own clock, and
  # kept outright by an adapter that cannot date them.
  defp aged?(actor, key) do
    case Arca.Storage.last_modified(actor, key) do
      {:ok, at} -> DateTime.diff(DateTime.utc_now(), at, :second) > @orphan_age_s
      {:error, _} -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Storage
  # ---------------------------------------------------------------------------

  defp snapshot_path(offer_id, filename),
    do: Arca.Storage.offers_prefix() ++ [offer_id, filename]

  defp custody_path(offer_id, attempt, filename),
    do: Arca.Storage.receipts_prefix() ++ [offer_id, attempt, filename]

  # One acceptance's own custody directory, so two acceptances of one
  # offer never write, or release, the same path.
  defp attempt_token, do: "att_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp path_segments(path), do: path |> String.split("/") |> Enum.reject(&(&1 == ""))

  defp release_snapshot(sender, offer_id) do
    case Arca.Overlay.with_internal_writes(fn ->
           Arca.delete_tree(sender, Arca.Storage.offers_prefix() ++ [offer_id])
         end) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Arca.FileOffers] snapshot of offer #{offer_id} not released: #{inspect(reason)}; " <>
            "the offers retention sweep takes it"
        )

        {:error, reason}
    end
  end

  # A receipt's custody copy, by the path the receipt records.
  defp release_custody(actor, %FileReceipt{custody_path: path}),
    do: delete_reserved(actor, path_segments(path))

  # What a failed acceptance wrote: its own attempt's copies, and nothing
  # another acceptance's receipt may name.
  defp release_attempt(actor, rows, attempt) do
    Enum.each(rows, &delete_reserved(actor, custody_path(&1.offer_id, attempt, &1.filename)))
  end

  defp delete_reserved(actor, key) do
    case Arca.Overlay.with_internal_writes(fn -> Arca.delete(actor, key) end) do
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  # ---------------------------------------------------------------------------
  # Announcements and views
  # ---------------------------------------------------------------------------

  defp announce(:offered, row), do: emit([:cyfr, :arca, :file_offer, :offered], :offered, row)
  defp announce(:accepted, row), do: emit([:cyfr, :arca, :file_offer, :accepted], :accepted, row)
  defp announce(:declined, row), do: emit([:cyfr, :arca, :file_offer, :declined], :declined, row)

  defp announce(:withdrawn, row),
    do: emit([:cyfr, :arca, :file_offer, :withdrawn], :withdrawn, row)

  defp announce(:expired, row), do: emit([:cyfr, :arca, :file_offer, :expired], :expired, row)

  defp emit(event, kind, row) do
    :telemetry.execute(event, %{system_time: System.system_time()}, %{
      offer_id: row.offer_id,
      kind: kind,
      sender_user_id: row.sender_user_id,
      recipient_user_id: row.recipient_user_id,
      filename: row.filename
    })
  end

  defp offer_view(%FileOffer{} = row) do
    %{
      id: row.id,
      offer_id: row.offer_id,
      sender_user_id: row.sender_user_id,
      recipient_user_id: row.recipient_user_id,
      filename: row.filename,
      digest: row.digest,
      size: row.size,
      status: row.status,
      expires_at: row.expires_at,
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end

  defp receipt_view(%FileReceipt{} = row) do
    %{
      id: row.id,
      offer_id: row.offer_id,
      sender_user_id: row.sender_user_id,
      recipient_user_id: row.recipient_user_id,
      filename: row.filename,
      digest: row.digest,
      size: row.size,
      folder: row.folder,
      status: row.status,
      attempt_path: row.attempt_path,
      attempt_state: row.attempt_state,
      issued_paths: issued_paths(row),
      ever_issued: row.ever_issued,
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
