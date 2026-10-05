# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Providers.FilesTest.Store do
  @moduledoc false
  # The Local adapter, with the process that reaches an armed point
  # killed there: `:probe` (a folder probe under `data/`, after the
  # acceptance committed and its completer claimed the receipt),
  # `:create` (a conditional create, killed once its bytes landed and
  # before it answers) and `:release` (the delete of a custody copy). A
  # probe may instead `:fail`, answering `{:error, :eio}`.
  use Arca.Storage.TestDouble

  @points {__MODULE__, :points}

  def arm(points) when is_map(points), do: :persistent_term.put(@points, points)
  def reset, do: :persistent_term.erase(@points)

  def last_modified(actor, path), do: Arca.Adapters.Local.last_modified(actor, path)

  def list_typed(actor, ["data" | _] = path) do
    case point(:probe) do
      :kill -> die()
      :fail -> {:error, :eio}
      nil -> super(actor, path)
    end
  end

  def list_typed(actor, path), do: super(actor, path)

  def put_if_none_match(actor, path, content) do
    result = super(actor, path, content)
    if point(:create) == :kill, do: die(), else: result
  end

  def delete(actor, ["payloads", "receipts" | _] = path) do
    if point(:release) == :kill, do: die(), else: super(actor, path)
  end

  def delete(actor, path), do: super(actor, path)

  defp point(kind), do: @points |> :persistent_term.get(%{}) |> Map.get(kind)

  defp die do
    Process.exit(self(), :kill)

    receive do
    after
      :infinity -> :ok
    end
  end
end

defmodule Arca.Providers.FilesTest do
  @moduledoc """
  The `file` tool is `Arca.Files` on the wire: the same folders, the same
  refusals, reads behind `storage_read` and changes behind
  `storage_write`, external-plane only, and a handler given the caller's
  actor alone. Its offer actions are `Arca.FileOffers` on the wire: what
  the handlers add over the store (the count, the sender, the seat, the
  default folder, the answers' shapes and the refusals' words), and a
  transfer finished once whatever point a crash leaves it at.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Grimoire.Catalog
  alias Arca.Providers.Files, as: Tool
  alias Arca.Providers.FilesTest.Store
  alias Arca.Schemas.{FileOffer, FileReceipt}

  @events for kind <- ~w(offered accepted declined withdrawn expired)a,
              do: [:cyfr, :arca, :file_offer, kind]

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "file_tool_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "the annotations: reads behind storage_read, changes behind storage_write, no chain" do
    actions = Tool.definition().annotations.actions

    assert actions["list"] == %{
             kind: :read,
             planes: [:external],
             permission: :storage_read,
             auth: :required
           }

    assert actions["read"] == %{
             kind: :read,
             planes: [:external],
             permission: :storage_read,
             auth: :required
           }

    assert actions["write"] == %{
             kind: :write,
             planes: [:external],
             permission: :storage_write,
             auth: :required
           }

    assert actions["delete"] == %{
             kind: :destructive,
             auth: :required,
             planes: [:external],
             permission: :storage_write
           }

    assert :ok = Catalog.audit_action_kinds([Tool])
    assert "file" in Enum.map(Grimoire.list_tools(), & &1["name"])
  end

  test "the offer actions: all but a withdrawal are interactive, and none is a chain's" do
    actions = Tool.definition().annotations.actions
    write = %{kind: :write, planes: [:external], permission: :storage_write, auth: :required}

    assert actions["offer"] == Map.put(write, :consent, :interactive)
    assert actions["accept"] == Map.put(write, :consent, :interactive)
    assert actions["decline"] == Map.put(write, :consent, :interactive)
    assert actions["withdraw"] == write

    assert actions["offers"] == %{
             kind: :read,
             planes: [:external],
             permission: :storage_read,
             consent: :interactive,
             auth: :required
           }

    # `paths` is a list, which no resource declaration names; the four
    # path actions keep theirs.
    resources = Map.new(Tool.definition().operations, &{&1.action, &1.resource})
    assert resources["offer"] == nil
    assert resources["read"] == {"path", :storage_path}

    schema = Tool.definition().input_schema
    assert %{"type" => "array", "minItems" => 1, "maxItems" => 10} = schema["properties"]["paths"]
  end

  test "the catalog serves the tree in the console's words", %{ctx: ctx} do
    assert {:ok, %{entries: folders}} = Grimoire.call_external("file", ctx, %{"action" => "list"})
    assert Enum.map(folders, & &1.name) == ~w(data aqua components threads notes)

    assert {:ok, %{written: "data/hello.txt", size: 5}} =
             Grimoire.call_external("file", ctx, %{
               "action" => "write",
               "path" => "data/hello.txt",
               "content" => "hello"
             })

    assert {:ok, %{content: "hello", encoding: "utf8"}} =
             Grimoire.call_external("file", ctx, %{"action" => "read", "path" => "data/hello.txt"})

    assert {:ok, %{entries: [%{name: "hello.txt", kind: :file, size: 5}]}} =
             Grimoire.call_external("file", ctx, %{"action" => "list", "path" => "data"})

    assert {:ok, %{deleted: "data/hello.txt"}} =
             Grimoire.call_external("file", ctx, %{
               "action" => "delete",
               "path" => "data/hello.txt"
             })

    assert {:error, {:not_found, "File", "data/hello.txt"}} =
             Grimoire.call_external("file", ctx, %{"action" => "read", "path" => "data/hello.txt"})

    assert {:error, {:not_found, "Folder", "payloads"}} =
             Grimoire.call_external("file", ctx, %{"action" => "list", "path" => "payloads"})
  end

  test "a missing argument and an unknown action answer in words", %{ctx: ctx} do
    actor = Sanctum.Context.actor(ctx)

    assert {:error, {:invalid_argument, "Missing required argument: path"}} =
             Tool.handle("file", actor, %{"action" => "read"})

    assert {:error, {:invalid_argument, "write needs path and content"}} =
             Tool.handle("file", actor, %{"action" => "write", "path" => "data/x"})

    assert {:error, {:invalid_argument, "offer needs paths and to"}} =
             Tool.handle("file", actor, %{"action" => "offer", "paths" => ["data/x"]})

    for action <- ~w(accept decline withdraw) do
      assert {:error, {:invalid_argument, "Missing required argument: offer_id"}} =
               Tool.handle("file", actor, %{"action" => action})
    end

    assert {:error, {:unknown_action, "file.move"}} =
             Tool.handle("file", actor, %{"action" => "move"})

    assert {:error, :action_missing} = Tool.handle("file", actor, %{})
  end

  test "the handler is declared for the actor, and a context is not one", %{ctx: ctx} do
    assert Tool.context_kind() == :actor
    assert Prima.Provider.context_kind(Tool) == :actor
    assert Tool.service() == "arca"

    assert_raise FunctionClauseError, fn ->
      Tool.handle("file", ctx, %{"action" => "list"})
    end
  end

  test "an actor with no athanor is refused at the door", %{ctx: ctx} do
    tenantless = %{Sanctum.Context.actor(ctx) | athanor_id: nil}
    assert {:error, :missing_tenant} = Tool.handle("file", tenantless, %{"action" => "list"})

    assert {:error, :missing_tenant} =
             Tool.handle("file", tenantless, %{"action" => "read", "path" => "data/x"})

    for args <- [
          %{"action" => "offer", "paths" => ["data/x"], "to" => "usr_other"},
          %{"action" => "offers"},
          %{"action" => "accept", "offer_id" => "ofr_x"},
          %{"action" => "decline", "offer_id" => "ofr_x"},
          %{"action" => "withdraw", "offer_id" => "ofr_x"}
        ] do
      assert {:error, :missing_tenant} = Tool.handle("file", tenantless, args)
    end
  end

  test "a key with storage_read reads and cannot write", %{ctx: ctx} do
    reader = %{
      ctx
      | auth_method: :api_key,
        api_key_type: :application,
        permissions: MapSet.new([:storage_read])
    }

    assert {:ok, %{entries: _}} = Grimoire.call_external("file", reader, %{"action" => "list"})

    assert {:error, _refused} =
             Grimoire.call_external("file", reader, %{
               "action" => "write",
               "path" => "data/x.txt",
               "content" => "x"
             })

    refute Arca.exists?(Sanctum.Context.actor(ctx), ["data", "x.txt"])
  end

  # ---------------------------------------------------------------------------
  # Sending a copy
  # ---------------------------------------------------------------------------

  describe "sending a copy" do
    setup do
      previous_adapter = Application.get_env(:arca, :storage_adapter)
      Application.put_env(:arca, :storage_adapter, Store)

      n = System.unique_integer([:positive])
      sender = person!("s", n)
      recipient = person!("r", n)
      stranger = person!("x", n)
      shared = athanor!("shared", n)

      for who <- [sender, recipient], do: seat!(shared, who.id)

      on_exit(fn ->
        Store.reset()

        if previous_adapter,
          do: Application.put_env(:arca, :storage_adapter, previous_adapter),
          else: Application.delete_env(:arca, :storage_adapter)

        Arca.Cache.delete_match({:athanor_usage, :_, :_})
      end)

      {:ok, sender: sender, recipient: recipient, stranger: stranger}
    end

    test "acceptance publishes the offered snapshot once across a crash and retry",
         %{sender: sender, recipient: recipient} do
      # The four points between the acceptance's commit and `completed`:
      # before the create, after it landed and before `published`, after
      # `published` and before `completed`, after `completed` and before
      # the custody copy's release.
      for point <- [:probe, :create, :published, :release] do
        name = "#{point}.txt"
        offered = "offered #{point} bytes"
        source!(sender, name, offered)

        assert {:ok, %{offer_id: offer_id}} =
                 call(sender, %{
                   "action" => "offer",
                   "paths" => ["data/docs/#{name}"],
                   "to" => recipient.id
                 })

        # Later edits do not follow the offer: the copy is the snapshot.
        :ok = Arca.put(sender.actor, ["data", "docs", name], "edited after offering")

        accept = fn ->
          Tool.handle("file", recipient.actor, %{"action" => "accept", "offer_id" => offer_id})
        end

        killed_at!(if(point == :published, do: :create, else: point), accept)
        inbox = ["data", "inbox", sender.id]

        # What the kill left: the receipt names the next step.
        case point do
          :probe ->
            assert [%{status: "received", attempt_path: nil}] = receipt_rows(offer_id)

          create when create in [:create, :published] ->
            assert [%{status: "received", attempt_state: "issued", ever_issued: true}] =
                     receipt_rows(offer_id)

            assert {:ok, ^offered} = Arca.get(recipient.actor, inbox ++ [offer_id, name])

          :release ->
            assert [%{status: "completed"}] = receipt_rows(offer_id)
            assert {:ok, [_copy]} = custody(recipient, offer_id)
        end

        # No storage call separates `published` from `completed`, so the
        # row is left as a kill between the two would leave it.
        if point == :published, do: set_receipts!(offer_id, status: "published")

        # The killed completer's lease runs out; the sweep takes over.
        set_receipts!(offer_id, completing_until: DateTime.add(DateTime.utc_now(), -60, :second))
        assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)

        assert {:ok, folders} = Arca.list(recipient.actor, inbox)
        assert offer_id in folders
        refute "#{offer_id}-2" in folders
        assert {:ok, [^name]} = Arca.list(recipient.actor, inbox ++ [offer_id])
        assert {:ok, ^offered} = Arca.get(recipient.actor, inbox ++ [offer_id, name])

        assert [%{status: "completed"}] = receipt_rows(offer_id)
        assert {:ok, []} = custody(recipient, offer_id)

        assert {:ok, []} =
                 Arca.Storage.list_prefix(sender.actor, ["payloads", "offers", offer_id])

        # A retried acceptance is refused: the transfer has one outcome.
        assert {:error, {:conflict, message}} =
                 Tool.handle("file", recipient.actor, %{
                   "action" => "accept",
                   "offer_id" => offer_id
                 })

        assert message =~ "was accepted"
        assert {:ok, [^name]} = Arca.list(recipient.actor, inbox ++ [offer_id])
      end

      assert {:ok, %{receipts: [], inbox: inbox}} = call(recipient, %{"action" => "offers"})
      assert length(inbox) == 4
      assert Enum.all?(inbox, &(&1.status == "accepted" and &1.sender == sender.id))
    end

    test "an offer and its acceptance answer in the operation's shapes, the store announcing once",
         %{sender: sender, recipient: recipient} do
      test_pid = self()
      handler = "file-tool-offers-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler,
          @events,
          fn event, _measurements, metadata, _config ->
            send(test_pid, {:offer_event, event, metadata.offer_id})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      source!(sender, "a.txt", "alpha")
      source!(sender, "b.txt", "beta-bytes")

      assert {:ok, %{offer_id: offer_id, recipient: to, expires_at: %DateTime{}, files: files}} =
               call(sender, %{
                 "action" => "offer",
                 "paths" => ["data/docs/a.txt", "data/docs/b.txt"],
                 "to" => recipient.id
               })

      assert to == recipient.id

      assert Enum.sort_by(files, & &1.filename) == [
               %{filename: "a.txt", size: 5},
               %{filename: "b.txt", size: 10}
             ]

      assert {:ok, %{inbox: inbox, outbox: [], receipts: []}} =
               call(recipient, %{"action" => "offers"})

      assert Enum.sort_by(inbox, & &1.filename) == [
               %{
                 offer_id: offer_id,
                 status: "offered",
                 filename: "a.txt",
                 size: 5,
                 expires_at: hd(inbox).expires_at,
                 sender: sender.id,
                 folder: "data/inbox/#{sender.id}"
               },
               %{
                 offer_id: offer_id,
                 status: "offered",
                 filename: "b.txt",
                 size: 10,
                 expires_at: hd(inbox).expires_at,
                 sender: sender.id,
                 folder: "data/inbox/#{sender.id}"
               }
             ]

      assert {:ok, %{inbox: [], outbox: outbox}} = call(sender, %{"action" => "offers"})
      assert Enum.all?(outbox, &(&1.recipient == recipient.id and &1.status == "offered"))
      refute Enum.any?(outbox, &Map.has_key?(&1, :sender))
      refute Enum.any?(outbox, &Map.has_key?(&1, :folder))

      assert {:ok, %{offer_id: ^offer_id, folder: folder, receipts: receipts}} =
               call(recipient, %{"action" => "accept", "offer_id" => offer_id})

      assert folder == "data/inbox/#{sender.id}/#{offer_id}/"

      assert Enum.sort_by(receipts, & &1.filename) == [
               %{
                 offer_id: offer_id,
                 filename: "a.txt",
                 size: 5,
                 status: "completed",
                 attempt_state: "issued"
               },
               %{
                 offer_id: offer_id,
                 filename: "b.txt",
                 size: 10,
                 status: "completed",
                 attempt_state: "issued"
               }
             ]

      assert {:ok, %{content: "beta-bytes"}} =
               Arca.Files.read(recipient.actor, folder <> "b.txt")

      # One announcement per file per transition, the store's; the
      # handlers add none.
      for kind <- [:offered, :accepted], _file <- 1..2 do
        assert_receive {:offer_event, [:cyfr, :arca, :file_offer, ^kind], ^offer_id}
      end

      refute_receive {:offer_event, _event, _offer_id}, 100
    end

    test "the handler refuses more than ten files, none, and an offer to oneself, before the store",
         %{sender: sender, recipient: recipient} do
      source!(sender, "a.txt", "alpha")
      eleven = for i <- 1..11, do: "data/docs/f#{i}.txt"

      assert {:error, {:invalid_argument, "An offer carries at most 10 files"}} =
               Tool.handle("file", sender.actor, %{
                 "action" => "offer",
                 "paths" => eleven,
                 "to" => recipient.id
               })

      assert {:error, {:invalid_argument, "An offer names at least one file under data/"}} =
               Tool.handle("file", sender.actor, %{
                 "action" => "offer",
                 "paths" => [],
                 "to" => recipient.id
               })

      assert {:error,
              {:invalid_argument,
               "An offer goes to another person; to copy a file within your own athanor, write it"}} =
               Tool.handle("file", sender.actor, %{
                 "action" => "offer",
                 "paths" => ["data/docs/a.txt"],
                 "to" => sender.id
               })

      # The gate refuses the count from the declaration as well.
      for paths <- [eleven, []] do
        assert {:error, %Prima.Refusal{stage: :admission}} =
                 call(sender, %{"action" => "offer", "paths" => paths, "to" => recipient.id})
      end

      assert {:ok, %{outbox: []}} = call(sender, %{"action" => "offers"})
      assert {:ok, []} = Arca.Storage.list_prefix(sender.actor, ["payloads", "offers"])
    end

    test "an offer from an athanor archived since is refused as archived, nothing of it standing",
         %{sender: sender, recipient: recipient} do
      source!(sender, "a.txt", "alpha")

      assert {:ok, _} =
               Arca.SecurityTransitions.archive_athanor(Prima.Actor.system(), sender.home.id,
                 verify: fn _rows -> :ok end
               )

      assert {:error, :archived} =
               Tool.handle("file", sender.actor, %{
                 "action" => "offer",
                 "paths" => ["data/docs/a.txt"],
                 "to" => recipient.id
               })

      assert Prima.Refusal.message(:archived) == "This athanor is archived — nothing runs in it"
      assert {:ok, []} = Arca.Storage.list_prefix(sender.actor, ["payloads", "offers"])
    end

    test "refusals name the caller's own path, folder or offer",
         %{sender: sender, recipient: recipient, stranger: stranger} do
      source!(sender, "a.txt", "alpha")

      assert {:error, {:invalid_argument, message}} =
               offer(sender, ["data/docs/a.txt"], stranger.id)

      assert message =~ "You share no athanor with #{stranger.id}"

      for outside <- ["notes/n.md", "components/reagents/local/x/0.1.0/x.wasm"] do
        assert {:error, {:invalid_argument, message}} = offer(sender, [outside], recipient.id)

        assert message ==
                 "'#{outside}' is not a file under data/ — only files under data/ are offered"
      end

      assert {:error, {:not_found, "File", "data/docs/gone.txt"}} =
               offer(sender, ["data/docs/a.txt", "data/docs/gone.txt"], recipient.id)

      assert {:ok, %{offer_id: offer_id}} = offer(sender, ["data/docs/a.txt"], recipient.id)

      # Into components/: refused, the offer still open.
      assert {:error, {:invalid_argument, message}} =
               call(recipient, %{
                 "action" => "accept",
                 "offer_id" => offer_id,
                 "folder" => "components/reagents"
               })

      assert message =~ "'components/reagents' is not a folder under data/"

      # The sender declines nothing: withdrawing is theirs. The recipient
      # withdraws nothing: declining is theirs.
      assert {:error, {:invalid_argument, message}} =
               call(sender, %{"action" => "decline", "offer_id" => offer_id})

      assert message =~ "withdraw it instead"

      assert {:error, {:invalid_argument, message}} =
               call(recipient, %{"action" => "withdraw", "offer_id" => offer_id})

      assert message =~ "decline it instead"

      # Another person's offer is not found, whoever asks.
      for action <- ~w(accept decline withdraw) do
        assert {:error, {:not_found, "Offer", ^offer_id}} =
                 call(stranger, %{"action" => action, "offer_id" => offer_id})
      end

      assert [%{status: "offered"}] = offer_rows(offer_id)

      # Expired: refused.
      set_offers!(offer_id, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))

      assert {:error, {:conflict, message}} =
               call(recipient, %{"action" => "accept", "offer_id" => offer_id})

      assert message == "Offer #{offer_id} has expired"

      # Accepted: withdrawing and declining are refused, the copy stands.
      assert {:ok, %{offer_id: second}} = offer(sender, ["data/docs/a.txt"], recipient.id)
      assert {:ok, _} = call(recipient, %{"action" => "accept", "offer_id" => second})

      assert {:error, {:conflict, message}} =
               call(sender, %{"action" => "withdraw", "offer_id" => second})

      assert message =~ "was accepted"

      assert {:error, {:conflict, _}} =
               call(recipient, %{"action" => "decline", "offer_id" => second})

      assert {:ok, "alpha"} =
               Arca.get(recipient.actor, ["data", "inbox", sender.id, second, "a.txt"])

      # Declined and withdrawn: each said once.
      assert {:ok, %{offer_id: third}} = offer(sender, ["data/docs/a.txt"], recipient.id)

      assert {:ok, %{offer_id: ^third, status: "declined"}} =
               call(recipient, %{"action" => "decline", "offer_id" => third})

      assert {:error, {:conflict, message}} =
               call(recipient, %{"action" => "accept", "offer_id" => third})

      assert message =~ "was declined"

      assert {:ok, %{offer_id: fourth}} = offer(sender, ["data/docs/a.txt"], recipient.id)

      assert {:ok, %{offer_id: ^fourth, status: "withdrawn"}} =
               call(sender, %{"action" => "withdraw", "offer_id" => fourth})

      assert {:error, {:conflict, message}} =
               call(recipient, %{"action" => "accept", "offer_id" => fourth})

      assert message =~ "was withdrawn by its sender"
    end

    test "an acceptance past the recipient's cap is refused: nothing written, the offer open",
         %{sender: sender, recipient: recipient} do
      Cyfr.Test.Settings.put("athanor_storage_bytes", 200)
      Arca.Cache.delete_match({:athanor_usage, :_, :_})
      source!(sender, "a.txt", :binary.copy("a", 40))
      :ok = Arca.put(recipient.actor, ["data", "full.bin"], :binary.copy("f", 150), cap: :exempt)
      Arca.Cache.delete_match({:athanor_usage, :_, :_})

      assert {:ok, %{offer_id: offer_id}} = offer(sender, ["data/docs/a.txt"], recipient.id)

      # 150 used, and acceptance holds 2 × 40 until the copy lands.
      assert {:error, {:invalid_argument, message}} =
               call(recipient, %{"action" => "accept", "offer_id" => offer_id})

      assert message =~ "at its limit (200 bytes)"
      assert message =~ "twice their size"

      assert [%{status: "offered"}] = offer_rows(offer_id)
      assert receipt_rows(offer_id) == []
      assert {:ok, []} = custody(recipient, offer_id)
      assert {:ok, ["full.bin"]} = Arca.list(recipient.actor, ["data"])
    end

    test "a publication the cap refuses waits as a receipt, then lands once space frees",
         %{sender: sender, recipient: recipient} do
      Cyfr.Test.Settings.put("athanor_storage_bytes", 200)
      Arca.Cache.delete_match({:athanor_usage, :_, :_})
      source!(sender, "a.txt", :binary.copy("a", 40))
      assert {:ok, %{offer_id: offer_id}} = offer(sender, ["data/docs/a.txt"], recipient.id)

      # The acceptance commits; its publication cannot start yet.
      Store.arm(%{probe: :fail})

      assert {:ok, %{folder: folder, receipts: [%{status: "received", attempt_state: nil}]}} =
               call(recipient, %{"action" => "accept", "offer_id" => offer_id})

      assert folder == "data/inbox/#{sender.id}/#{offer_id}/"
      Store.reset()

      # The recipient fills the space the publication needs.
      :ok = Arca.put(recipient.actor, ["data", "full.bin"], :binary.copy("f", 150), cap: :exempt)
      Arca.Cache.delete_match({:athanor_usage, :_, :_})

      assert {:ok, 0} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)

      assert {:ok,
              %{
                receipts: [
                  %{
                    offer_id: ^offer_id,
                    filename: "a.txt",
                    size: 40,
                    status: "received",
                    attempt_state: "chosen"
                  }
                ]
              }} = call(recipient, %{"action" => "offers"})

      :ok = Arca.delete(recipient.actor, ["data", "full.bin"])
      Arca.Cache.delete_match({:athanor_usage, :_, :_})

      assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)
      assert {:ok, %{receipts: []}} = call(recipient, %{"action" => "offers"})

      assert {:ok, %{content: content}} = Arca.Files.read(recipient.actor, folder <> "a.txt")
      assert content == :binary.copy("a", 40)
    end

    test "an acceptance into an athanor the caller holds no seat in is refused before anything is read",
         %{sender: sender, recipient: recipient} do
      source!(sender, "a.txt", "alpha")
      assert {:ok, %{offer_id: offer_id}} = offer(sender, ["data/docs/a.txt"], recipient.id)

      # The recipient's context focused on the sender's own athanor.
      elsewhere = %{recipient.actor | athanor_id: sender.home.id}

      # The seat comes first: an offer that does not exist answers the same.
      for id <- [offer_id, "ofr_none"], folder <- [nil, "data/in"] do
        args = %{"action" => "accept", "offer_id" => id}
        args = if folder, do: Map.put(args, "folder", folder), else: args
        assert {:error, :not_member} = Tool.handle("file", elsewhere, args)
      end

      assert [%{status: "offered"}] = offer_rows(offer_id)
      assert receipt_rows(offer_id) == []
      assert {:ok, []} = custody(%{actor: elsewhere}, offer_id)
      assert {:ok, []} = custody(recipient, offer_id)
    end

    test "a key reaches no offer, inbox, acceptance or decline; a sender's key withdraws", %{
      sender: sender,
      recipient: recipient
    } do
      source!(sender, "a.txt", "alpha")
      assert {:ok, %{offer_id: offer_id}} = offer(sender, ["data/docs/a.txt"], recipient.id)

      key = fn who ->
        %{
          who.ctx
          | auth_method: :api_key,
            api_key_type: :application,
            permissions: MapSet.new([:storage_read, :storage_write])
        }
      end

      # An inbox is read and decided by person across athanors, so it is a
      # session's, as an offer and an acceptance are.
      for {who, args} <- [
            {sender,
             %{"action" => "offer", "paths" => ["data/docs/a.txt"], "to" => recipient.id}},
            {recipient, %{"action" => "offers"}},
            {recipient, %{"action" => "accept", "offer_id" => offer_id}},
            {recipient, %{"action" => "decline", "offer_id" => offer_id}}
          ] do
        assert {:error,
                %Prima.Refusal{
                  stage: :admission,
                  reason: {:consent_class_required, {:surface_not_permitted, :api_key}}
                }} = Grimoire.call_external("file", key.(who), args),
               "file.#{args["action"]} answered a key"
      end

      assert [%{status: "offered"}] = offer_rows(offer_id)
      assert receipt_rows(offer_id) == []
      assert {:ok, %{outbox: [%{status: "offered"}]}} = call(sender, %{"action" => "offers"})

      # A withdrawal is the sender's own row in the sender's athanor.
      assert {:ok, %{status: "withdrawn"}} =
               Grimoire.call_external("file", key.(sender), %{
                 "action" => "withdraw",
                 "offer_id" => offer_id
               })
    end

    test "offers lists the caller's own receipts, never another member's",
         %{sender: sender, recipient: recipient} do
      # A second member of the recipient's athanor, in a session of theirs.
      other = member!(recipient.home, "m", System.unique_integer([:positive]))

      source!(sender, "secret-name.txt", "for the recipient alone")

      assert {:ok, %{offer_id: offer_id}} =
               offer(sender, ["data/docs/secret-name.txt"], recipient.id)

      # The acceptance commits and its publication waits: a receipt
      # `received` in the athanor both members share.
      Store.arm(%{probe: :fail})

      assert {:ok, %{receipts: [%{status: "received"}]}} =
               call(recipient, %{"action" => "accept", "offer_id" => offer_id})

      Store.reset()

      assert {:ok, %{receipts: [%{offer_id: ^offer_id, filename: "secret-name.txt"}]}} =
               call(recipient, %{"action" => "offers"})

      assert {:ok, %{inbox: [], outbox: [], receipts: []}} = call(other, %{"action" => "offers"})
    end

    test "the default folder is the sender's namespace when it is one path segment, " <>
           "and the inbox names it before acceptance",
         %{sender: sender, recipient: recipient} do
      named = person!("n", System.unique_integer([:positive]))
      seat!(recipient.home, named.id)
      user!(named.id, "alice-#{System.unique_integer([:positive])}")
      {:ok, %{namespace: namespace}} = Arca.Users.get(Prima.Actor.system(), named.id)

      odd = person!("o", System.unique_integer([:positive]))
      seat!(recipient.home, odd.id)
      user!(odd.id, "has/slash-#{System.unique_integer([:positive])}")

      for {who, slug} <- [{named, namespace}, {odd, odd.id}, {sender, sender.id}] do
        source!(who, "a.txt", "from #{who.id}")

        assert {:ok, %{offer_id: offer_id}} = offer(who, ["data/docs/a.txt"], recipient.id)

        # The inbox names the folder an acceptance without one lands in.
        assert {:ok, %{inbox: inbox}} = call(recipient, %{"action" => "offers"})
        assert [%{folder: named_folder}] = Enum.filter(inbox, &(&1.offer_id == offer_id))
        assert named_folder == "data/inbox/#{slug}"

        assert {:ok, %{folder: folder}} =
                 call(recipient, %{"action" => "accept", "offer_id" => offer_id})

        assert folder == "data/inbox/#{slug}/#{offer_id}/"
        assert folder == named_folder <> "/" <> offer_id <> "/"
      end

      # A folder the recipient names is the destination.
      source!(sender, "b.txt", "beta")
      assert {:ok, %{offer_id: offer_id}} = offer(sender, ["data/docs/b.txt"], recipient.id)

      assert {:ok, %{folder: folder}} =
               call(recipient, %{
                 "action" => "accept",
                 "offer_id" => offer_id,
                 "folder" => "data/from-sender"
               })

      assert folder == "data/from-sender/#{offer_id}/"
      assert {:ok, "beta"} = Arca.get(recipient.actor, ["data", "from-sender", offer_id, "b.txt"])
    end

    test "offers lists the caller's receipts still landing and those that failed, with their status",
         %{sender: sender, recipient: recipient} do
      source!(sender, "a.txt", "alpha")
      source!(sender, "b.txt", "beta")
      assert {:ok, %{offer_id: waiting}} = offer(sender, ["data/docs/a.txt"], recipient.id)
      assert {:ok, %{offer_id: lost}} = offer(sender, ["data/docs/b.txt"], recipient.id)

      # Both acceptances commit, and neither publication can start.
      Store.arm(%{probe: :fail})

      for offer_id <- [waiting, lost] do
        assert {:ok, %{receipts: [%{status: "received"}]}} =
                 call(recipient, %{"action" => "accept", "offer_id" => offer_id})
      end

      # One was received past `file_receipt_days` and no write was ever
      # sent for it: the sweep fails it.
      set_receipts!(lost, inserted_at: DateTime.add(DateTime.utc_now(), -10 * 86_400, :second))

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)
      end)

      Store.reset()

      assert {:ok, %{receipts: receipts}} = call(recipient, %{"action" => "offers"})

      assert Enum.sort_by(receipts, & &1.filename) == [
               %{
                 offer_id: waiting,
                 filename: "a.txt",
                 size: 5,
                 status: "received",
                 attempt_state: nil
               },
               %{offer_id: lost, filename: "b.txt", size: 4, status: "failed", attempt_state: nil}
             ]

      # A receipt that has landed is listed no longer; a failed one stays.
      assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)

      assert {:ok, %{receipts: [%{offer_id: ^lost, status: "failed"}]}} =
               call(recipient, %{"action" => "offers"})
    end

    test "the sender's snapshot outlives the staging sweep", %{
      sender: sender,
      recipient: recipient
    } do
      source!(sender, "a.txt", "kept past the reservation window")
      assert {:ok, %{offer_id: offer_id}} = offer(sender, ["data/docs/a.txt"], recipient.id)

      snapshot = ["payloads", "offers", offer_id, "a.txt"]
      full = Arca.Adapters.Local.build_path(sender.actor, snapshot)
      :ok = File.touch!(full, System.os_time(:second) - 16 * 60)

      sweeper = sweeper(sender)
      assert {:ok, _} = Arca.Retention.FencedStaging.prune(sweeper, 1, false)
      assert {:ok, _} = Arca.Retention.FileOffers.prune(sweeper, 7, false)
      assert {:ok, "kept past the reservation window"} = Arca.get(sender.actor, snapshot)

      assert {:ok, %{receipts: [%{status: "completed"}]}} =
               call(recipient, %{"action" => "accept", "offer_id" => offer_id})
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A person working in an athanor of their own, as a session's context.
  defp person!(label, n), do: member!(athanor!("home-#{label}", n), label, n)

  # A person seated in `home` and working in it, as a session's context.
  defp member!(home, label, n) do
    id = "usr_f0#{label}#{n}"
    seat!(home, id)

    ctx =
      Sanctum.Context.build(
        user_id: id,
        namespace: "f0#{label}#{n}",
        athanor_id: home.id,
        permissions: Sanctum.Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    %{id: id, home: home, ctx: ctx, actor: Sanctum.Context.actor(ctx)}
  end

  defp athanor!(label, n) do
    {:ok, athanor} =
      Arca.Athanors.insert(Prima.Actor.system(), %{
        kind: "group",
        name: "F0 #{label} #{n}",
        slug: "f0-#{label}-#{n}",
        created_by: "system"
      })

    athanor
  end

  defp seat_actor(athanor), do: %{Prima.Actor.system() | athanor_id: athanor.id, scope: :athanor}

  defp seat!(athanor, user_id) do
    case Arca.Members.find(seat_actor(athanor), user_id) do
      {:ok, _seated} ->
        :ok

      {:error, :not_found} ->
        {:ok, _} = Arca.Members.seat(seat_actor(athanor), %{user_id: user_id, added_by: "test"})
        :ok
    end
  end

  # A person row carrying `namespace`.
  defp user!(id, namespace) do
    now = DateTime.utc_now()

    {1, _} =
      Arca.Repo.insert_all(Arca.Schemas.User, [
        %{
          id: id,
          provider: "local",
          namespace: namespace,
          status: "active",
          first_seen_at: now,
          last_seen_at: now,
          created_at: now,
          updated_at: now
        }
      ])

    :ok
  end

  defp call(who, args), do: Grimoire.call_external("file", who.ctx, args)

  defp offer(who, paths, to),
    do: call(who, %{"action" => "offer", "paths" => paths, "to" => to})

  defp source!(who, name, content), do: :ok = Arca.put(who.actor, ["data", "docs", name], content)

  # The retention sweep's actor for the athanor: the server's own, narrowed.
  defp sweeper(who), do: %{Prima.Actor.system() | athanor_id: who.home.id, scope: :athanor}

  # Run `fun` in a process of its own, killed at the double's `point`.
  defp killed_at!(point, fun) do
    Store.arm(%{point => :kill})
    {pid, ref} = spawn_monitor(fun)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 10_000
    Store.reset()
    assert reason == :killed, "the acceptance ended #{inspect(reason)} before #{point}"
  end

  defp custody(who, offer_id),
    do: Arca.Storage.list_prefix(who.actor, ["payloads", "receipts", offer_id])

  defp offer_rows(offer_id),
    do: Arca.Repo.all(from(o in FileOffer, where: o.offer_id == ^offer_id))

  defp receipt_rows(offer_id),
    do: Arca.Repo.all(from(r in FileReceipt, where: r.offer_id == ^offer_id))

  defp set_offers!(offer_id, set) do
    {_, _} = Arca.Repo.update_all(from(o in FileOffer, where: o.offer_id == ^offer_id), set: set)
    :ok
  end

  defp set_receipts!(offer_id, set) do
    {_, _} =
      Arca.Repo.update_all(from(r in FileReceipt, where: r.offer_id == ^offer_id), set: set)

    :ok
  end
end

defmodule Arca.Providers.FilesRaceTest do
  @moduledoc """
  `file/accept` racing `file/withdraw` on one offer of several files, each
  on a real connection of its own outside the sandbox: whichever reaches
  the offer's rows first decides it, and the other is refused naming how
  the offer ended. A third connection holds the rows until both sides
  are waiting for them — on PostgreSQL by locking them `FOR UPDATE`, each
  side seen waiting in `pg_stat_activity`; on SQLite by holding the write
  lock. PostgreSQL grants the rows in the order the sides queued, so
  there the side queued first is the one that wins.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Providers.Files, as: Tool
  alias Arca.Schemas.{Athanor, FileOffer, FileReceipt}
  alias Ecto.Adapters.SQL.Sandbox

  # Listed out of filename order, so the rows' order in the table is not
  # the order an index on the filename returns them in.
  @files ~w(c.txt a.txt b.txt)

  setup do
    no_claimant!()

    base = Path.join(System.tmp_dir!(), "file_race_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    n = System.unique_integer([:positive])

    {sender, recipient, shared} =
      unboxed(fn ->
        shared = athanor!("shared", n)
        sender = person!("s", n)
        recipient = person!("r", n)
        for who <- [sender, recipient], do: seat!(shared.id, who.id)
        {sender, recipient, shared}
      end)

    on_exit(fn ->
      unboxed(fn ->
        ids = [sender.actor.athanor_id, recipient.actor.athanor_id, shared.id]

        for id <- ids do
          {:ok, _} = Arca.TenantTables.delete_all_for(Prima.Actor.in_athanor(id))
        end

        Arca.Repo.delete_all(from(a in Athanor, where: a.id in ^ids))
      end)

      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    {:ok, sender: sender, recipient: recipient}
  end

  # An acceptance is fenced by this member's slot. No claimant runs in a
  # test, so none is held and none is asked for; the switch is restored
  # after the case.
  defp no_claimant! do
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    Application.put_env(:arca, :control_plane_claim_enabled, false)

    on_exit(fn ->
      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)
  end

  test "an acceptance and a withdrawal racing on real connections: one wins, the other is refused",
       %{sender: sender, recipient: recipient} do
    for first <- [:withdraw, :accept] do
      offer_id = offered!(sender, recipient)
      {winner, results} = race!(first, sender, recipient, offer_id)

      statuses = unboxed(fn -> offer_statuses(offer_id) end)
      receipts = unboxed(fn -> receipt_count(offer_id) end)
      custody = unboxed(fn -> custody(recipient, offer_id) end)
      inbox = ["data", "inbox", sender.id, offer_id]

      case winner do
        :accept ->
          assert {:ok, %{offer_id: ^offer_id, receipts: [_, _, _]}} = results.accept

          assert results.withdraw ==
                   {:error,
                    {:conflict, "Offer #{offer_id} was accepted — the copy is the recipient's"}}

          assert statuses == ["accepted"]
          assert receipts == length(@files)

          for name <- @files do
            assert {:ok, "#{name} bytes"} ==
                     unboxed(fn -> Arca.get(recipient.actor, inbox ++ [name]) end)
          end

        :withdraw ->
          assert results.withdraw == {:ok, %{offer_id: offer_id, status: "withdrawn"}}

          assert results.accept ==
                   {:error, {:conflict, "Offer #{offer_id} was withdrawn by its sender"}}

          assert statuses == ["withdrawn"]
          assert receipts == 0
          assert custody == []
          refute unboxed(fn -> Arca.exists?(recipient.actor, inbox) end)
      end

      # PostgreSQL grants the rows in the order the two queued for them.
      if postgres?(), do: assert(winner == first, "#{first} queued first and lost")
    end
  end

  # The rows held on a third connection; each side started and seen
  # waiting for them, `first` first; then the rows let go.
  defp race!(first, sender, recipient, offer_id) do
    test = self()
    holder = Task.async(fn -> unboxed(fn -> hold(offer_id, test) end) end)
    assert_receive {:holding, holding}, 10_000

    sides = if first == :withdraw, do: [:withdraw, :accept], else: [:accept, :withdraw]

    tasks =
      for side <- sides do
        task =
          Task.async(fn ->
            unboxed(fn ->
              send(test, {:backend, side, backend()})
              decide(side, sender, recipient, offer_id)
            end)
          end)

        assert_receive {:backend, ^side, pid}, 10_000
        await_waiting!(side, task, pid, recipient, offer_id)
        {side, task}
      end

    send(holding, :go)
    assert {:ok, :held} = Task.await(holder, 20_000)

    results = Map.new(tasks, fn {side, task} -> {side, Task.await(task, 20_000)} end)

    winner =
      case results do
        %{accept: {:ok, _}, withdraw: {:error, _}} -> :accept
        %{accept: {:error, _}, withdraw: {:ok, _}} -> :withdraw
        other -> flunk("not one winner: #{inspect(other)}")
      end

    {winner, results}
  end

  defp decide(:accept, _sender, recipient, offer_id),
    do: Tool.handle("file", recipient.actor, %{"action" => "accept", "offer_id" => offer_id})

  defp decide(:withdraw, sender, _recipient, offer_id),
    do: Tool.handle("file", sender.actor, %{"action" => "withdraw", "offer_id" => offer_id})

  # PostgreSQL: the offer's rows locked. SQLite: the write lock, which a
  # transaction takes as it starts.
  defp hold(offer_id, test) do
    Arca.Repo.transaction(fn ->
      if postgres?() do
        Arca.Repo.all(from(o in FileOffer, where: o.offer_id == ^offer_id, lock: "FOR UPDATE"))
      end

      send(test, {:holding, self()})

      receive do
        :go -> :held
      end
    end)
  end

  # A side is waiting for the rows: on PostgreSQL its backend blocks on a
  # lock where it takes the offer's rows, in their one order, before its
  # update (`Arca.FileOffers`' ordered lock); on SQLite the acceptance has
  # written its custody copies, the last step before its transaction. The
  # side has decided nothing while the rows are held.
  defp await_waiting!(side, task, backend, recipient, offer_id) do
    cond do
      postgres?() -> await_lock!(backend, [~s(FROM "file_offers"), "FOR UPDATE"])
      side == :accept -> await_custody!(recipient, offer_id)
      true -> :ok
    end

    refute Task.yield(task, 300), "#{side} decided while the offer's rows were held"
  end

  defp await_lock!(backend, fragments, tries \\ 250) do
    [[type, event, query]] =
      unboxed(fn ->
        Arca.Repo.query!(
          "SELECT wait_event_type, wait_event, query FROM pg_stat_activity WHERE pid = $1",
          [backend]
        ).rows
      end)

    cond do
      type == "Lock" and Enum.all?(fragments, &String.contains?(query, &1)) ->
        :ok

      tries == 0 ->
        flunk("backend #{backend} is not waiting at #{inspect(fragments)}: #{type} #{event}")

      true ->
        Process.sleep(20)
        await_lock!(backend, fragments, tries - 1)
    end
  end

  defp await_custody!(recipient, offer_id, tries \\ 250) do
    keys = unboxed(fn -> custody(recipient, offer_id) end)

    cond do
      length(keys) == length(@files) ->
        :ok

      tries == 0 ->
        flunk("the acceptance wrote #{length(keys)} custody copies of #{length(@files)}")

      true ->
        Process.sleep(20)
        await_custody!(recipient, offer_id, tries - 1)
    end
  end

  defp offered!(sender, recipient) do
    unboxed(fn ->
      for name <- @files,
          do: :ok = Arca.put(sender.actor, ["data", "docs", name], "#{name} bytes")

      {:ok, %{offer_id: offer_id}} =
        Tool.handle("file", sender.actor, %{
          "action" => "offer",
          "paths" => Enum.map(@files, &"data/docs/#{&1}"),
          "to" => recipient.id
        })

      offer_id
    end)
  end

  defp offer_statuses(offer_id) do
    from(o in FileOffer, where: o.offer_id == ^offer_id, select: o.status)
    |> Arca.Repo.all()
    |> Enum.uniq()
  end

  defp receipt_count(offer_id),
    do: Arca.Repo.aggregate(from(r in FileReceipt, where: r.offer_id == ^offer_id), :count)

  # Every custody copy of the offer in the recipient's tree.
  defp custody(recipient, offer_id) do
    {:ok, keys} = Arca.Storage.list_prefix(recipient.actor, ["payloads", "receipts", offer_id])
    keys
  end

  defp person!(label, n) do
    home = athanor!("home-#{label}", n)
    id = "usr_fr#{label}#{n}"
    seat!(home.id, id)

    %{
      id: id,
      actor: %Prima.Actor{athanor_id: home.id, user_id: id, scope: :athanor, authenticated: true}
    }
  end

  defp athanor!(label, n) do
    {:ok, athanor} =
      Arca.Athanors.insert(Prima.Actor.system(), %{
        kind: "group",
        name: "Race #{label} #{n}",
        slug: "file-race-#{label}-#{n}",
        created_by: "system"
      })

    athanor
  end

  defp seat!(athanor_id, user_id) do
    seat = %{Prima.Actor.system() | athanor_id: athanor_id, scope: :athanor}
    {:ok, _} = Arca.Members.seat(seat, %{user_id: user_id, added_by: "test"})
    :ok
  end

  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres

  defp backend do
    if postgres?(), do: hd(hd(Arca.Repo.query!("SELECT pg_backend_pid()").rows))
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
end
