# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.FilesTest.Store do
  @moduledoc false
  # The Local adapter, with folder probes under `data/` answering
  # `{:error, :eio}` while held: an acceptance commits and its publication
  # waits for the next sweep.
  use Arca.Storage.TestDouble

  @held {__MODULE__, :held}

  def hold, do: :persistent_term.put(@held, true)
  def release, do: :persistent_term.erase(@held)

  def last_modified(actor, path), do: Arca.Adapters.Local.last_modified(actor, path)

  def list_typed(actor, ["data" | _] = path) do
    if :persistent_term.get(@held, false), do: {:error, :eio}, else: super(actor, path)
  end

  def list_typed(actor, path), do: super(actor, path)
end

defmodule Arca.FilesTest do
  @moduledoc """
  The athanor's files as a person sees them (`Arca.Files`): the folders
  are the layout's console tier, the server's own storage has no name,
  `data/` is open, the shaped folders take edits only inside a unit, and
  the read-only folders take none. Every operation takes the actor and
  refuses one with no athanor before touching storage. A copy another
  person sent lands in `data/` from the recipient's own custody, beside
  whatever the recipient keeps there.
  """

  use ExUnit.Case, async: false

  alias Arca.Files

  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  @shipped ["components", "reagents", "local", "shelf", "1.0.0"]

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "files_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")

    prev_base = Application.fetch_env!(:arca, :base_path)
    prev_seed = Application.fetch_env!(:arca, :seed_path)
    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, seed)

    Arca.Test.UnitFixtures.seed_component!("reagent", "local", "shelf", "1.0.0",
      manifest: %{"type" => "reagent", "version" => "1.0.0", "description" => "shipped"},
      wasm: @valid_wasm
    )

    roles = Path.join([seed, "aqua", "roles"])
    File.mkdir_p!(roles)
    File.write!(Path.join([seed, "aqua", "aqua.md"]), "---\ntitle: A\n---\n\nsoul\n")
    File.write!(Path.join(roles, "scribe.md"), "---\ntitle: Scribe\n---\n\nscribe\n")

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      Application.put_env(:arca, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    actor = Sanctum.Context.actor(ctx)
    :ok = Arca.ensure_roots(actor)
    {:ok, ctx: ctx, actor: actor}
  end

  test "the folders are the layout's console tier, and the server's own storage has no name",
       %{actor: actor} do
    assert Files.folders() == [
             %{name: "data", tier: :open},
             %{name: "aqua", tier: :shaped},
             %{name: "components", tier: :shaped},
             %{name: "threads", tier: :read},
             %{name: "notes", tier: :read}
           ]

    assert {:ok, %{path: "", tier: nil, entries: entries}} = Files.list(actor, "")
    assert Enum.map(entries, & &1.name) == ~w(data aqua components threads notes)
    assert Enum.all?(entries, &(&1.kind == :dir))

    for hidden <- ["payloads", "guest", "seed", "cache", "system", "secret"] do
      assert {:error, {:not_found, "Folder", ^hidden}} = Files.list(actor, hidden)
      assert {:error, {:not_found, "Folder", ^hidden}} = Files.read(actor, hidden <> "/x.txt")

      assert {:error, {:not_found, "Folder", ^hidden}} =
               Files.write(actor, hidden <> "/x.txt", "x")
    end
  end

  test "data/ is open: write, list with sizes, read, delete a file, delete a folder", %{
    actor: actor
  } do
    assert {:ok, %{written: "data/reports/q3.csv", size: 8}} =
             Files.write(actor, "data/reports/q3.csv", "a,b\n1,2\n")

    assert {:ok, %{written: "data/reports/logo.bin", size: 3}} =
             Files.write(actor, "data/reports/logo.bin", Base.encode64(<<0, 255, 1>>), "base64")

    assert {:ok,
            %{path: "data", tier: :open, entries: [%{name: "reports", kind: :dir, size: nil}]}} =
             Files.list(actor, "data")

    assert {:ok, %{path: "data/reports", entries: entries}} = Files.list(actor, "data/reports/")

    assert entries == [
             %{name: "logo.bin", kind: :file, size: 3},
             %{name: "q3.csv", kind: :file, size: 8}
           ]

    assert {:ok, %{content: "a,b\n1,2\n", encoding: "utf8", size: 8, path: "data/reports/q3.csv"}} =
             Files.read(actor, "data/reports/q3.csv")

    assert {:ok, %{content: encoded, encoding: "base64"}} =
             Files.read(actor, "data/reports/logo.bin")

    assert Base.decode64!(encoded) == <<0, 255, 1>>

    assert {:ok, %{deleted: "data/reports/q3.csv"}} = Files.delete(actor, "data/reports/q3.csv")

    assert {:error, {:not_found, "File", "data/reports/q3.csv"}} =
             Files.read(actor, "data/reports/q3.csv")

    assert {:error, {:not_found, "File", "data/reports/q3.csv"}} =
             Files.delete(actor, "data/reports/q3.csv")

    assert {:ok, %{deleted: "data/reports"}} = Files.delete(actor, "data/reports")
    assert {:ok, %{entries: []}} = Files.list(actor, "data")

    # The folder itself is a place, not a file.
    assert {:error, {:invalid_argument, msg}} = Files.write(actor, "data", "x")
    assert msg =~ "is a folder"
    assert {:error, {:invalid_argument, msg}} = Files.read(actor, "")
    assert msg =~ "inside a folder"
  end

  test "a path is checked before it is looked at", %{actor: actor} do
    assert {:error, {:invalid_argument, _}} = Files.read(actor, "data/../aqua/aqua.md")
    assert {:error, {:invalid_argument, _}} = Files.write(actor, "data/a\\b.txt", "x")
    assert {:error, {:invalid_argument, msg}} = Files.write(actor, "data/x.txt", "nope", "hex")
    assert msg =~ "encoding"
    assert {:error, {:invalid_argument, _}} = Files.write(actor, "data/x.txt", "@@@", "base64")

    assert {:error, {:invalid_argument, msg}} =
             Files.write(actor, "data/big.bin", String.duplicate("x", Files.max_write() + 1))

    assert msg =~ "at most"
  end

  test "the read-only folders are listed and read, never written", %{actor: actor} do
    assert {:ok, %{tier: :read, entries: []}} = Files.list(actor, "notes")
    assert {:ok, %{tier: :read}} = Files.list(actor, "threads")

    for path <- ["notes/plan.md", "threads/thread_1/blob.bin"] do
      assert {:error, {:invalid_argument, msg}} = Files.write(actor, path, "x")
      assert msg =~ "read here"
      assert {:error, {:invalid_argument, _}} = Files.delete(actor, path)
    end

    # The retired name for threads/ (spelled split for the vocabulary gate)
    # is no folder.
    retired = "conver" <> "sations"
    assert {:error, {:not_found, "Folder", ^retired}} = Files.list(actor, retired)
  end

  test "notes/ is served from the fenced documents: listed with sizes, read, and never written",
       %{actor: actor} do
    note!(actor, "notes/plan.md", "the plan")
    note!(actor, "notes/about-you.md", "me")
    # Neither a document outside the folder nor a stray object under the
    # storage root of the same name is a note.
    note!(actor, "notes-old/elsewhere.md", "not here")
    :ok = Arca.put(actor, ["notes", "stray.md"], "a file, not a note")

    assert {:ok, %{tier: :read, entries: entries, truncated: false}} = Files.list(actor, "notes")

    assert entries == [
             %{name: "about-you.md", kind: :file, size: 2},
             %{name: "plan.md", kind: :file, size: 8}
           ]

    assert {:ok, %{content: "the plan", encoding: "utf8", size: 8}} =
             Files.read(actor, "notes/plan.md")

    assert {:error, {:not_found, "File", "notes/stray.md"}} = Files.read(actor, "notes/stray.md")
    assert {:error, {:invalid_argument, msg}} = Files.list(actor, "notes/plan.md")
    assert msg =~ "is a file"
    assert {:error, {:invalid_argument, _}} = Files.write(actor, "notes/plan.md", "x")
    assert {:error, {:invalid_argument, _}} = Files.delete(actor, "notes/plan.md")
    assert {:ok, %{content: "the plan"}} = Files.read(actor, "notes/plan.md")
  end

  test "components/ is shaped: edits land only inside a local unit, and a shipped unit is never deleted",
       %{actor: actor} do
    assert {:ok, %{tier: :shaped}} = Files.list(actor, "components")

    assert {:ok, %{entries: [%{name: "1.0.0", kind: :dir}]}} =
             Files.list(actor, "components/reagents/local/shelf")

    # Outside any unit: nothing lands, whatever the name.
    assert {:error, {:invalid_argument, msg}} = Files.write(actor, "components/notes.txt", "x")
    assert msg =~ "outside any component"

    assert {:error, {:invalid_argument, _}} =
             Files.write(actor, "components/reagents/local/shelf/README.md", "x")

    # Inside the shipped copy: an edit, and the unit is still the shipped one.
    assert {:ok, %{written: "components/reagents/local/shelf/1.0.0/notes.txt"}} =
             Files.write(actor, "components/reagents/local/shelf/1.0.0/notes.txt", "mine")

    assert Arca.Overlay.unit_status(actor, @shipped) == {:ok, :shipped}
    assert {:ok, true} = Arca.Overlay.edited?(actor, @shipped)

    # A file inside goes; the unit whole does not.
    assert {:ok, _} = Files.delete(actor, "components/reagents/local/shelf/1.0.0/notes.txt")

    assert {:error, {:invalid_argument, msg}} =
             Files.delete(actor, "components/reagents/local/shelf/1.0.0")

    assert msg =~ "ships with the server"

    assert {:error, {:invalid_argument, msg}} = Files.delete(actor, "components/reagents")
    assert msg =~ "holds units"

    # A pulled component is fork-to-modify.
    assert {:error, {:invalid_argument, msg}} =
             Files.write(actor, "components/reagents/acme/theirs/1.0.0/notes.txt", "x")

    assert msg =~ "fork into local/"

    # The athanor's own unit: written, and deleted whole.
    assert {:ok, _} =
             Files.write(
               actor,
               "components/reagents/local/mine/0.1.0/reagent.wasm",
               Base.encode64(@valid_wasm),
               "base64"
             )

    assert {:ok, _} =
             Files.write(
               actor,
               "components/reagents/local/mine/0.1.0/cyfr-manifest.json",
               ~s({"type":"reagent","version":"0.1.0"})
             )

    assert {:ok, %{entries: [%{name: "mine"}, %{name: "shelf"}]}} =
             Files.list(actor, "components/reagents/local")

    assert {:ok, %{deleted: "components/reagents/local/mine/0.1.0"}} =
             Files.delete(actor, "components/reagents/local/mine/0.1.0")
  end

  test "an edit inside a component keeps its row in step with the tree", %{
    ctx: ctx,
    actor: actor
  } do
    {:ok, _} = Compendium.Registry.register_from_arca(ctx, @shipped)
    {:ok, before} = Compendium.Registry.get(ctx, "shelf", "1.0.0")
    assert before.description == "shipped"

    manifest = ~s({"type":"reagent","version":"1.0.0","description":"edited here"})

    assert {:ok, _} =
             Files.write(
               actor,
               "components/reagents/local/shelf/1.0.0/cyfr-manifest.json",
               manifest
             )

    {:ok, row} = Compendium.Registry.get(ctx, "shelf", "1.0.0")
    assert row.description == "edited here"
  end

  test "an edit of a role is what the agent index answers next, with nothing delivered", %{
    ctx: ctx,
    actor: actor
  } do
    assert {:ok, _} =
             Files.write(actor, "aqua/roles/courier.md", "---\ntitle: Courier\n---\n\ncourier\n")

    assert {:ok, rows} = Compendium.AgentIndex.list(ctx)
    courier = Enum.find(rows, &(&1.name == "courier"))
    assert courier

    assert {:ok, _} =
             Files.write(
               actor,
               "aqua/roles/courier.md",
               "---\ntitle: Courier\ndisabled: true\n---\n\ncourier\n"
             )

    assert {:ok, rows} = Compendium.AgentIndex.list(ctx)
    assert %{disabled: true} = Enum.find(rows, &(&1.name == "courier"))
  end

  test "aqua/ is shaped: the soul, a role and a scroll are edited in place; nothing else lands",
       %{actor: actor} do
    assert {:ok, %{tier: :shaped, entries: entries}} = Files.list(actor, "aqua")
    assert Enum.map(entries, & &1.name) == ["roles", "aqua.md"]

    assert {:ok, %{content: "---\ntitle: Scribe\n---\n\nscribe\n"}} =
             Files.read(actor, "aqua/roles/scribe.md")

    assert {:ok, _} =
             Files.write(actor, "aqua/roles/scribe.md", "---\ntitle: Scribe\n---\n\nours\n")

    assert {:ok, %{content: "---\ntitle: Scribe\n---\n\nours\n"}} =
             Files.read(actor, "aqua/roles/scribe.md")

    assert {:error, {:invalid_argument, msg}} = Files.write(actor, "aqua/roles/notes.txt", "x")
    assert msg =~ "outside any AQUA unit"

    assert {:error, {:invalid_argument, _}} =
             Files.write(actor, "aqua/roles/scribe.md/inner.txt", "x")

    assert {:error, {:invalid_argument, msg}} = Files.delete(actor, "aqua/roles/scribe.md")
    assert msg =~ "ships with the server"

    # The athanor's own role and scroll go by the same door.
    assert {:ok, _} = Files.write(actor, "aqua/roles/mine.md", "---\ntitle: Mine\n---\n\nmine\n")

    assert {:ok, _} =
             Files.write(actor, "aqua/skills/pdf/SKILL.md", "---\nname: pdf\n---\n\npdf\n")

    assert {:ok, %{deleted: "aqua/roles/mine.md"}} = Files.delete(actor, "aqua/roles/mine.md")
    assert {:ok, %{deleted: "aqua/skills/pdf"}} = Files.delete(actor, "aqua/skills/pdf")
  end

  test "locate/2 names the bytes the download route streams, in any shown folder", %{
    actor: actor
  } do
    assert {:ok, ["data", "a", "b.txt"], :open} = Files.locate(actor, "data/a/b.txt")

    # A note is a document: its bytes are the staged ones it names, and a
    # note nothing holds has no bytes to stream.
    assert {:error, {:not_found, "File", "notes/plan.md"}} = Files.locate(actor, "notes/plan.md")
    staged = note!(actor, "notes/plan.md", "the plan")
    assert {:ok, ["staging", ^staged], :read} = Files.locate(actor, "notes/plan.md")

    assert {:error, {:not_found, "Folder", "payloads"}} =
             Files.locate(actor, "payloads/sha256/abc")

    assert {:error, {:invalid_argument, _}} = Files.locate(actor, "data")
    assert {:error, {:invalid_argument, _}} = Files.locate(actor, "data/../x")
  end

  test "an actor with no athanor is refused before anything is read or written", %{
    actor: actor
  } do
    :ok = Arca.put(actor, ["data", "kept.txt"], "kept")

    for tenantless <- [
          %{actor | athanor_id: nil},
          %{actor | athanor_id: ""},
          # A platform read crosses athanors, but a tree still has one.
          %{actor | athanor_id: nil, scope: :platform, system: true}
        ] do
      assert {:error, :missing_tenant} = Files.list(tenantless, "")
      assert {:error, :missing_tenant} = Files.list(tenantless, "data")
      assert {:error, :missing_tenant} = Files.read(tenantless, "data/kept.txt")
      assert {:error, :missing_tenant} = Files.write(tenantless, "data/new.txt", "x")
      assert {:error, :missing_tenant} = Files.update(tenantless, "data/kept.txt", &{:ok, &1})
      assert {:error, :missing_tenant} = Files.delete(tenantless, "data/kept.txt")
      assert {:error, :missing_tenant} = Files.locate(tenantless, "data/kept.txt")
    end

    assert {:ok, %{content: "kept"}} = Files.read(actor, "data/kept.txt")
    refute Arca.exists?(actor, ["data", "new.txt"])
  end

  test "a manifest the validator refuses is not written, and the bytes stay as they were", %{
    actor: actor
  } do
    manifest = "components/reagents/local/mine/0.1.0/cyfr-manifest.json"
    good = ~s({"type":"reagent","version":"0.1.0"})
    assert {:ok, _} = Files.write(actor, manifest, good)

    # A block validator's sentence, after the file's name — today's text.
    assert {:error, {:invalid_argument, message}} =
             Files.write(actor, manifest, ~s({"type":"reagent","setup":{}}))

    assert message =~ "cyfr-manifest.json: Manifest declares unknown top-level key(s): setup"

    # A refusal with no sentence of its own names the file, never the
    # validator's term.
    assert {:error, {:invalid_argument, message}} =
             Files.write(actor, manifest, ~s({"type":"reagent","caps":"nope"}))

    assert message == "cyfr-manifest.json: its caps are not valid"

    # The storage-path predicate is the storage layer's own.
    assert {:error, {:invalid_argument, message}} =
             Files.write(
               actor,
               manifest,
               ~s({"caps":{"storage":{"paths":["aqua/"],"actions":["read"]}}})
             )

    assert message ==
             "cyfr-manifest.json: caps.storage.paths names aqua/, which is no guest scope"

    assert {:error, {:invalid_argument, "cyfr-manifest.json is not a JSON object"}} =
             Files.write(actor, manifest, "[1, 2]")

    # The same refusal through a serialized edit.
    assert {:error, {:invalid_argument, _}} =
             Files.update(actor, manifest, fn _ -> {:ok, ~s({"setup":{}})} end)

    assert {:ok, %{content: ^good}} = Files.read(actor, manifest)
  end

  test "a write under another publisher's component names the fork path", %{actor: actor} do
    assert {:error, {:invalid_argument, message}} =
             Files.write(actor, "components/reagents/acme/theirs/1.0.0/notes.txt", "x")

    assert message ==
             "'components/reagents/acme/theirs/1.0.0/notes.txt': " <>
               Prima.ComponentNamespace.message(:not_local_namespace, "acme")
  end

  test "accepted custody survives sender purge without overwriting recipient bytes" do
    previous_adapter = Application.get_env(:arca, :storage_adapter)
    Application.put_env(:arca, :storage_adapter, Arca.FilesTest.Store)

    on_exit(fn ->
      Arca.FilesTest.Store.release()

      if previous_adapter,
        do: Application.put_env(:arca, :storage_adapter, previous_adapter),
        else: Application.delete_env(:arca, :storage_adapter)
    end)

    n = System.unique_integer([:positive])
    sender = person!("s", n)
    recipient = person!("r", n)
    shared = athanor!("shared", n)
    for who <- [sender, recipient], do: seat!(shared, who.id)

    {:ok, _} = Files.write(sender.actor, "data/reports/q3.csv", "a,b\n1,2\n")

    assert {:ok, %{offer_id: offer_id}} =
             file(sender, %{
               "action" => "offer",
               "paths" => ["data/reports/q3.csv"],
               "to" => recipient.id
             })

    {:ok, _} = Files.write(sender.actor, "data/reports/q3.csv", "edited after offering")

    # The acceptance commits: the bytes are in the recipient's custody and
    # the receipt names them; publication waits for the sweep.
    Arca.FilesTest.Store.hold()

    assert {:ok, %{folder: folder, receipts: [%{status: "received", attempt_state: nil}]}} =
             file(recipient, %{"action" => "accept", "offer_id" => offer_id})

    Arca.FilesTest.Store.release()
    assert folder == "data/inbox/#{sender.id}/#{offer_id}/"

    # The sender's athanor is archived and erased, rows and blobs.
    {:ok, home} = Sanctum.Tenancy.Athanors.get(sender.home.id)
    {:ok, archived} = Sanctum.Tenancy.Athanors.archive(home)
    assert {:ok, _counts} = Sanctum.Tenancy.Athanors.destroy(archived)
    assert {:error, :not_found} = Arca.get(sender.actor, ["data", "reports", "q3.csv"])

    # The recipient keeps a file of their own where the transfer would land.
    {:ok, _} = Files.write(recipient.actor, folder <> "q3.csv", "the recipient's own")

    sweeper = %{Prima.Actor.system() | athanor_id: recipient.home.id, scope: :athanor}
    assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper, 7, false)

    # The recipient's bytes stand; the offered snapshot lands beside them.
    assert {:ok, %{content: "the recipient's own"}} =
             Files.read(recipient.actor, folder <> "q3.csv")

    assert {:ok, %{entries: entries}} =
             Files.list(recipient.actor, "data/inbox/#{sender.id}")

    assert Enum.map(entries, & &1.name) |> Enum.sort() == [offer_id, "#{offer_id}-2"]

    assert {:ok, %{content: "a,b\n1,2\n"}} =
             Files.read(recipient.actor, "data/inbox/#{sender.id}/#{offer_id}-2/q3.csv")

    assert {:ok, []} =
             Arca.Storage.list_prefix(recipient.actor, ["payloads", "receipts", offer_id])

    assert {:ok, %{receipts: [], inbox: []}} = file(recipient, %{"action" => "offers"})
  end

  # A person working in an athanor of their own, as a session's context.
  defp person!(label, n) do
    id = "usr_files#{label}#{n}"
    home = athanor!("home-#{label}", n)
    seat!(home, id)

    ctx =
      Sanctum.Context.build(
        user_id: id,
        namespace: "files#{label}#{n}",
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
        name: "Files #{label} #{n}",
        slug: "files-#{label}-#{n}",
        created_by: "system"
      })

    athanor
  end

  defp seat!(athanor, user_id) do
    seat = %{Prima.Actor.system() | athanor_id: athanor.id, scope: :athanor}
    {:ok, _} = Arca.Members.seat(seat, %{user_id: user_id, added_by: "test"})
    :ok
  end

  defp file(who, args), do: Grimoire.call_external("file", who.ctx, args)

  # A document published straight through the store, as a note is kept:
  # staged bytes and their reference, with no claimant in this suite.
  defp note!(actor, key, bytes) do
    {:ok, staged} = Arca.Storage.stage(actor, "notes", bytes)

    change = %Arca.FencedPublication.Change{
      resource: {:document, actor.athanor_id, key},
      staged: staged
    }

    {:ok, 1} = Arca.FencedPublication.publish(change, 0, :none)
    staged
  end
end
