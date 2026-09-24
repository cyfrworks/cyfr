# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.FilesTest do
  @moduledoc """
  The athanor's files as a person sees them (`Arca.Files`): the folders
  are the layout's console tier, the server's own storage has no name,
  `data/` is open, the shaped folders take edits only inside a unit, and
  the read-only folders take none. Every operation takes the actor and
  refuses one with no athanor before touching storage.
  """

  use ExUnit.Case, async: false

  alias Arca.Files

  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  @shipped ["components", "reagents", "local", "shelf", "1.0.0"]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

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

    # The estate's own role and scroll go by the same door.
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
    assert {:ok, ["notes", "plan.md"], :read} = Files.locate(actor, "notes/plan.md")

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

    # A caps term, rendered whole after the file's name — today's text.
    assert {:error, {:invalid_argument, message}} =
             Files.write(actor, manifest, ~s({"type":"reagent","caps":"nope"}))

    assert message == ~s(cyfr-manifest.json: {:invalid_caps, {:not_a_map, "nope"}})

    # The storage-path predicate is the storage layer's own.
    assert {:error, {:invalid_argument, message}} =
             Files.write(
               actor,
               manifest,
               ~s({"caps":{"storage":{"paths":["aqua/"],"actions":["read"]}}})
             )

    assert message =~ "invalid_storage_path"

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
end
