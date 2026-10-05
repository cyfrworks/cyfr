# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Providers.Files do
  @moduledoc """
  The `file` tool: the athanor's files on the wire, exactly as the Files
  page shows them, and the copies a person sends another.

  The door is `Arca.Files`; this module is its operation declaration.
  Paths are the console's — `data/…`, `components/…`, `aqua/…`,
  `notes/…`, `threads/…` — and what each folder allows is its tier,
  decided at the door. Reads take `storage_read`, writes and deletes
  `storage_write`; a key with the permission may use them, so a script can
  fill `data/` unattended. The actions are external-plane only: a chain
  reaches files through its own consented hands.

  `list`, `read`, `write` and `delete` name their file or folder by
  `path`, relative to the athanor root, and declare it as their resource
  (`resource:`), so a standing approval may be constrained to paths.

  ## Sending a copy

  `offer`, `offers`, `accept`, `decline` and `withdraw` are
  `Arca.FileOffers` on the wire. `offer` copies up to ten files under
  `data/` for a person the caller shares an athanor with; `accept` takes
  the copy into a folder under `data/` of the caller's focused athanor,
  `data/inbox/<sender>/` unless the caller names another. An offer is the
  sender's decision and an acceptance the recipient's, and the store
  reads an inbox and decides a decline by person, across athanors, so
  `offer`, `offers`, `accept` and `decline` are interactive
  (`consent: :interactive`): no key reaches them. `withdraw` is the
  sender's own row in the athanor the call is in, behind `storage_write`.
  `offer` names its files by `paths`, a list, and so declares no
  resource. An acceptance first reads the caller's seat in the focused
  athanor and refuses `:not_member` without one. `offers` lists the
  receipts of the focused athanor that are the caller's own, never
  another member's: those still landing and those that failed to. Each
  incoming offer it lists names the `folder` an acceptance without one
  lands in, by the one rule the acceptance uses. A refusal names the
  caller's own path, folder or offer and never another person's tree.
  The lifecycle's telemetry is the store's, emitted once after each
  transition commits; these handlers emit none.

  The provider declares `context_kind: :actor`: the gate authorizes the
  call with the caller's full context and hands this handler the
  `Prima.Actor` it projects, and nothing else.
  """

  @behaviour Prima.Provider

  require Logger

  alias Arca.FileOffers
  alias Arca.Files

  # The most files one offer carries.
  @max_offer_files 10

  @no_person {:invalid_argument, "Only a person sends, accepts or declines an offer"}

  @impl true
  def service, do: "arca"

  @impl true
  def context_kind, do: :actor

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    alias Prima.{Arg, Operation}

    path =
      Arg.new("path", :string, description: "A folder-relative path, like data/reports/q3.csv")

    offer_id = Arg.new("offer_id", :string, required: true, description: "The offer, ofr_…")

    Operation.tool(
      [
        Operation.new(
          "file",
          "list",
          "List a folder; an omitted or empty path lists the root folders",
          [path],
          kind: :read,
          planes: [:external],
          permission: :storage_read,
          resource: {"path", :storage_path}
        ),
        Operation.new("file", "read", "Read a file as text or base64 bytes", [Arg.required(path)],
          kind: :read,
          planes: [:external],
          permission: :storage_read,
          resource: {"path", :storage_path}
        ),
        Operation.new(
          "file",
          "write",
          "Write file content",
          [
            Arg.required(path),
            Arg.new("content", :string,
              required: true,
              description: "Text or base64-encoded content"
            ),
            Arg.new("encoding", :string,
              enum: ["utf8", "base64"],
              description: "Content encoding; defaults to utf8"
            )
          ],
          kind: :write,
          planes: [:external],
          permission: :storage_write,
          resource: {"path", :storage_path}
        ),
        Operation.new("file", "delete", "Delete a file or folder", [Arg.required(path)],
          kind: :destructive,
          planes: [:external],
          permission: :storage_write,
          resource: {"path", :storage_path}
        ),
        Operation.new(
          "file",
          "offer",
          "Offer a copy of files under data/ to a person you share an athanor with",
          [
            Arg.new("paths", {:array, Arg.new(nil, :string)},
              required: true,
              min: 1,
              max: @max_offer_files,
              description: "The files to send, under data/, like data/reports/q3.csv"
            ),
            Arg.new("to", :string,
              required: true,
              description: "The person to offer them to, by person id (usr_…)"
            )
          ],
          kind: :write,
          planes: [:external],
          permission: :storage_write,
          consent: :interactive
        ),
        Operation.new(
          "file",
          "offers",
          "The offers sent to you and by you, and accepted files still landing " <>
            "or that failed to land",
          [],
          kind: :read,
          planes: [:external],
          permission: :storage_read,
          consent: :interactive
        ),
        Operation.new(
          "file",
          "accept",
          "Accept an offer into a folder under data/",
          [
            offer_id,
            Arg.new("folder", :string,
              description: "A folder under data/ to accept into; data/inbox/<sender>/ by default"
            )
          ],
          kind: :write,
          planes: [:external],
          permission: :storage_write,
          consent: :interactive
        ),
        Operation.new("file", "decline", "Decline an offer sent to you", [offer_id],
          kind: :write,
          planes: [:external],
          permission: :storage_write,
          consent: :interactive
        ),
        Operation.new(
          "file",
          "withdraw",
          "Withdraw an offer you sent that is not yet accepted",
          [offer_id],
          kind: :write,
          planes: [:external],
          permission: :storage_write
        )
      ],
      title: "Files",
      description:
        "The athanor's files, as the Files page shows them. data/ is yours to fill; " <>
          "components/ and aqua/ hold shaped units you may edit in place; notes/ and " <>
          "threads/ are read here and managed on their own pages. Paths are " <>
          "folder-relative, like data/reports/q3.csv. An offer sends a copy of files " <>
          "under data/ to a person you share an athanor with, who accepts it into " <>
          "their own data/."
    )
  end

  @impl true
  def handle("file", %Prima.Actor{} = actor, args), do: dispatch(actor, args)
  def handle(tool, %Prima.Actor{}, _args), do: {:error, {:not_found, "tool", tool}}

  defp dispatch(actor, %{"action" => "list"} = args),
    do: Files.list(actor, Map.get(args, "path", ""))

  defp dispatch(actor, %{"action" => "read", "path" => path}) when is_binary(path),
    do: Files.read(actor, path)

  defp dispatch(actor, %{"action" => "write", "path" => path, "content" => content} = args)
       when is_binary(path) and is_binary(content),
       do: Files.write(actor, path, content, Map.get(args, "encoding", "utf8"))

  defp dispatch(actor, %{"action" => "delete", "path" => path}) when is_binary(path),
    do: Files.delete(actor, path)

  defp dispatch(actor, %{"action" => "offer", "paths" => paths, "to" => to})
       when is_list(paths) and is_binary(to),
       do: offer(actor, paths, to)

  defp dispatch(actor, %{"action" => "offers"}), do: offers(actor)

  defp dispatch(actor, %{"action" => "accept", "offer_id" => offer_id} = args)
       when is_binary(offer_id),
       do: accept(actor, offer_id, Map.get(args, "folder"))

  defp dispatch(actor, %{"action" => "decline", "offer_id" => offer_id})
       when is_binary(offer_id),
       do: decline(actor, offer_id)

  defp dispatch(actor, %{"action" => "withdraw", "offer_id" => offer_id})
       when is_binary(offer_id),
       do: withdraw(actor, offer_id)

  defp dispatch(_actor, %{"action" => action}) when action in ~w(read delete),
    do: {:error, {:invalid_argument, "Missing required argument: path"}}

  defp dispatch(_actor, %{"action" => "write"}),
    do: {:error, {:invalid_argument, "write needs path and content"}}

  defp dispatch(_actor, %{"action" => "offer"}),
    do: {:error, {:invalid_argument, "offer needs paths and to"}}

  defp dispatch(_actor, %{"action" => action}) when action in ~w(accept decline withdraw),
    do: {:error, {:invalid_argument, "Missing required argument: offer_id"}}

  defp dispatch(_actor, %{"action" => action}), do: {:error, {:unknown_action, "file.#{action}"}}
  defp dispatch(_actor, _args), do: {:error, :action_missing}

  # ---------------------------------------------------------------------------
  # Sending a copy
  # ---------------------------------------------------------------------------

  defp offer(actor, paths, to) do
    with :ok <- person(actor),
         :ok <- offer_paths(paths),
         :ok <- not_self(actor, to) do
      case FileOffers.offer(actor, to, paths) do
        {:ok, %{offer_id: offer_id, expires_at: expires_at, files: files}} ->
          {:ok,
           %{
             offer_id: offer_id,
             recipient: to,
             expires_at: expires_at,
             files: Enum.map(files, &Map.take(&1, [:filename, :size]))
           }}

        {:error, reason} ->
          offer_refusal(actor, reason, paths, to)
      end
    end
  end

  defp offer_paths([]),
    do: {:error, {:invalid_argument, "An offer names at least one file under data/"}}

  defp offer_paths(paths) when length(paths) > @max_offer_files,
    do: {:error, {:invalid_argument, "An offer carries at most #{@max_offer_files} files"}}

  defp offer_paths(paths) do
    if Enum.all?(paths, &is_binary/1),
      do: :ok,
      else: {:error, {:invalid_argument, "Each of paths is a path under data/"}}
  end

  defp not_self(%Prima.Actor{user_id: to}, to),
    do:
      {:error,
       {:invalid_argument,
        "An offer goes to another person; to copy a file within your own athanor, write it"}}

  defp not_self(_actor, _to), do: :ok

  defp offers(actor) do
    with :ok <- person(actor), do: listed(actor)
  end

  # The store answers every receipt of the athanor; another member's are
  # not the caller's to see. A sender's default folder is read once per
  # sender in the listing.
  defp listed(%Prima.Actor{user_id: user_id} = actor) do
    with {:ok, inbox} <- FileOffers.inbox(actor),
         {:ok, outbox} <- FileOffers.outbox(actor),
         {:ok, receipts} <- FileOffers.receipts(actor, status: ["received", "failed"]) do
      folders =
        inbox
        |> Enum.map(& &1.sender_user_id)
        |> Enum.uniq()
        |> Map.new(&{&1, default_folder(&1)})

      {:ok,
       %{
         inbox:
           Enum.map(inbox, fn row ->
             row
             |> offer_item(:sender, row.sender_user_id)
             |> Map.put(:folder, Map.fetch!(folders, row.sender_user_id))
           end),
         outbox: Enum.map(outbox, &offer_item(&1, :recipient, &1.recipient_user_id)),
         receipts:
           for(%{recipient_user_id: ^user_id} = receipt <- receipts, do: receipt_item(receipt))
       }}
    else
      {:error, reason} -> refusal("offers", reason)
    end
  end

  # The seat comes first: nothing of the offer, the sender or the storage
  # is read for a caller who holds no seat in the athanor they would
  # accept into.
  defp accept(actor, offer_id, folder) do
    with :ok <- person(actor),
         :ok <- seated(actor),
         {:ok, folder} <- destination(actor, offer_id, folder) do
      case FileOffers.accept(actor, offer_id, folder) do
        {:ok, %{offer_id: offer_id, folder: folder, receipts: receipts}} ->
          {:ok,
           %{
             offer_id: offer_id,
             folder: landed_in(receipts, folder, offer_id),
             receipts: Enum.map(receipts, &receipt_item/1)
           }}

        {:error, reason} ->
          accept_refusal(reason, offer_id, folder)
      end
    end
  end

  defp seated(%Prima.Actor{user_id: user_id} = actor) do
    case Arca.Members.find(actor, user_id) do
      {:ok, %{status: "active"}} -> :ok
      {:ok, _invited} -> {:error, :not_member}
      {:error, :not_found} -> {:error, :not_member}
      {:error, reason} -> refusal("seat", reason)
    end
  end

  # The folder the caller named, or `data/inbox/<sender slug>` for the
  # offer addressed to them; storage holds a named folder to `data/`.
  defp destination(_actor, _offer_id, folder) when is_binary(folder), do: {:ok, folder}

  defp destination(actor, offer_id, nil) do
    with {:ok, inbox} <- FileOffers.inbox(actor) do
      case Enum.find(inbox, &(&1.offer_id == offer_id)) do
        nil -> {:error, {:not_found, "Offer", offer_id}}
        row -> {:ok, default_folder(row.sender_user_id)}
      end
    else
      {:error, reason} -> refusal("offer #{offer_id}", reason)
    end
  end

  defp destination(_actor, _offer_id, _folder),
    do: {:error, {:invalid_argument, "folder is a folder under data/"}}

  # Where an offer from `sender` lands when its recipient names no folder:
  # the one rule, for the acceptance and for the inbox that shows it first.
  defp default_folder(sender), do: "data/inbox/" <> sender_slug(sender)

  # The sender's namespace when it is one storage path segment, their
  # person id otherwise. The person row is read under the platform's
  # actor, as the store reads the membership that admits the offer.
  defp sender_slug(sender) do
    case Arca.Users.get(Prima.Actor.system(), sender) do
      {:ok, %{namespace: namespace}} when is_binary(namespace) ->
        if segment?(namespace), do: namespace, else: sender

      _none ->
        sender
    end
  end

  defp segment?(name),
    do:
      name != "" and not String.contains?(name, "/") and
        Prima.PathSafety.validate_segments([name]) == :ok

  # The folder the first receipt to record a path chose (which carries a
  # `-<n>` suffix when the offer's folder already existed), or the offer's
  # own folder under the destination while none has.
  defp landed_in(receipts, folder, offer_id) do
    case Enum.find(receipts, &is_binary(&1.attempt_path)) do
      %{attempt_path: path} ->
        (path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")) <> "/"

      nil ->
        String.trim_trailing(folder, "/") <> "/" <> offer_id <> "/"
    end
  end

  defp decline(actor, offer_id) do
    with :ok <- person(actor) do
      case FileOffers.decline(actor, offer_id) do
        :ok ->
          {:ok, %{offer_id: offer_id, status: "declined"}}

        # The sender's own offer is theirs to withdraw, not to decline.
        {:error, :not_found} ->
          if listed?(FileOffers.outbox(actor), offer_id),
            do:
              {:error,
               {:invalid_argument,
                "Offer #{offer_id} is one you sent — withdraw it instead of declining it"}},
            else: {:error, {:not_found, "Offer", offer_id}}

        {:error, reason} ->
          ended_refusal(reason, offer_id)
      end
    end
  end

  defp withdraw(actor, offer_id) do
    with :ok <- person(actor) do
      case FileOffers.withdraw(actor, offer_id) do
        :ok ->
          {:ok, %{offer_id: offer_id, status: "withdrawn"}}

        # An offer addressed to the caller is theirs to decline.
        {:error, :not_found} ->
          if listed?(FileOffers.inbox(actor), offer_id),
            do:
              {:error,
               {:invalid_argument,
                "Offer #{offer_id} was sent to you — decline it instead of withdrawing it"}},
            else: {:error, {:not_found, "Offer", offer_id}}

        {:error, reason} ->
          ended_refusal(reason, offer_id)
      end
    end
  end

  defp listed?({:ok, rows}, offer_id), do: Enum.any?(rows, &(&1.offer_id == offer_id))
  defp listed?(_unread, _offer_id), do: false

  # Who sends, accepts or declines is a person in an athanor.
  defp person(%Prima.Actor{athanor_id: athanor_id})
       when not is_binary(athanor_id) or athanor_id == "",
       do: {:error, :missing_tenant}

  defp person(%Prima.Actor{user_id: user_id}) when is_binary(user_id) and user_id != "",
    do: :ok

  defp person(%Prima.Actor{}), do: {:error, @no_person}

  defp offer_item(row, role, person) do
    row
    |> Map.take([:offer_id, :status, :filename, :size, :expires_at])
    |> Map.put(role, person)
  end

  defp receipt_item(receipt),
    do: Map.take(receipt, [:offer_id, :filename, :size, :status, :attempt_state])

  # ---------------------------------------------------------------------------
  # Refusals, in the door's words
  # ---------------------------------------------------------------------------

  defp offer_refusal(actor, reason, paths, to) do
    case reason do
      {:outside_data, path} ->
        {:error,
         {:invalid_argument,
          "'#{shown(path)}' is not a file under data/ — only files under data/ are offered"}}

      :duplicate_filename ->
        {:error,
         {:invalid_argument,
          "Two of the files share a name — an offer's files land in one folder, so each name must differ"}}

      {:too_large, filename} ->
        {:error,
         {:invalid_argument,
          "'#{named(paths, filename)}' is larger than #{Files.max_write()} bytes, " <>
            "the most one offered file may be"}}

      :not_shared ->
        {:error,
         {:invalid_argument,
          "You share no athanor with #{to} — an offer goes to someone you share an athanor with"}}

      # Refused under the parties' locks: a denial or an archive landed
      # while the offer was being made.
      :denied ->
        {:error, :denied}

      :athanor_archived ->
        {:error, :archived}

      :not_found ->
        {:error, {:not_found, "File", missing(actor, paths)}}

      {:limit_reached, :athanor_storage_bytes, cap} ->
        {:error,
         {:invalid_argument,
          "The athanor's storage is at its limit (#{cap} bytes) — an offer keeps a copy " <>
            "of its files until it ends, so remove something first"}}

      :no_files ->
        offer_paths([])

      reason ->
        refusal("offer", reason)
    end
  end

  defp accept_refusal(reason, offer_id, folder) do
    case reason do
      {:outside_data, _folder} ->
        {:error,
         {:invalid_argument,
          "'#{folder}' is not a folder under data/ — an offer is accepted into data/"}}

      {:limit_reached, :athanor_storage_bytes, cap} ->
        {:error,
         {:invalid_argument,
          "The athanor's storage is at its limit (#{cap} bytes) — accepting holds two " <>
            "copies until the files land, so it needs twice their size free"}}

      :snapshot_corrupt ->
        {:error, {:corrupt, {:digest, "The offered copy"}}}

      reason ->
        ended_refusal(reason, offer_id)
    end
  end

  defp ended_refusal(reason, offer_id) do
    case reason do
      :not_found -> {:error, {:not_found, "Offer", offer_id}}
      {:not_offered, status} -> {:error, {:conflict, not_offered(offer_id, status)}}
      reason -> refusal("offer #{offer_id}", reason)
    end
  end

  defp not_offered(offer_id, "accepted"),
    do: "Offer #{offer_id} was accepted — the copy is the recipient's"

  defp not_offered(offer_id, "declined"), do: "Offer #{offer_id} was declined"
  defp not_offered(offer_id, "withdrawn"), do: "Offer #{offer_id} was withdrawn by its sender"
  defp not_offered(offer_id, "expired"), do: "Offer #{offer_id} has expired"
  defp not_offered(offer_id, status), do: "Offer #{offer_id} is #{status}"

  # The store's own vocabulary where the refusal table reads it as is;
  # anything else is a storage failure, logged here and answered as one.
  defp refusal(subject, reason) do
    case reason do
      :no_athanor ->
        {:error, :missing_tenant}

      :no_person ->
        {:error, @no_person}

      :storage_unverifiable ->
        {:error, {:unavailable, "Storage usage"}}

      reason when reason in [:database_error, :not_owner] ->
        {:error, reason}

      reason ->
        Logger.error("[Arca.Providers.Files] #{subject} failed: #{inspect(reason)}")
        {:error, {:unavailable, "Storage"}}
    end
  end

  defp shown(path) when is_binary(path), do: path
  defp shown(path) when is_list(path), do: Enum.join(path, "/")
  defp shown(path), do: inspect(path)

  # The caller's path whose file carries `filename`.
  defp named(paths, filename),
    do: Enum.find(paths, filename, &(&1 |> String.split("/") |> List.last() == filename))

  # The caller's first path that names no file, read in the caller's own
  # athanor after the store refused.
  defp missing(actor, paths) do
    Enum.find(paths, Enum.join(paths, ", "), fn path ->
      not Arca.exists?(actor, String.split(path, "/", trim: true))
    end)
  end
end
