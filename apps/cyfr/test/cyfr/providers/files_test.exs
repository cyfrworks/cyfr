# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Providers.FilesTest do
  @moduledoc """
  The stream `files.changes`: the person's recent files under `data/` and
  the offers waiting for them, first as the refresh lists them and then
  as the bridge tells them when a file or an offer moves. Every refresh
  item and live payload is read as a canvas reads it: projected by the
  grant, passed through JSON and held to the declared shape. A file
  enters on its write and leaves on its delete or its folder's; an offer
  enters its recipient's own files and leaves on each end; another
  athanor hears none of it; and no item carries a file's contents, a
  download link or a person's identifier.
  """

  # The bus subscriptions and the telemetry the bridge handles are the
  # node's, and the rows are written through the shared sandbox.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Cyfr.Bus
  alias Cyfr.Bus.FileListed
  alias Cyfr.Providers.Files, as: Provider
  alias Prima.Canvas.Shape
  alias Sanctum.Context

  @stream "files.changes"
  @private "PRIVATE-FILES-7c41"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Sanctum.Test.Newcomers.directory!()
    %{ctx: ctx} = person!("me")
    %{ctx: other_ctx} = person!("other")
    actor = Context.actor(ctx)

    :ok = Bus.subscribe(actor, Bus.files(actor))

    {:ok, ctx: ctx, actor: actor, other_ctx: other_ctx}
  end

  # A person with their own athanor, and the context their session
  # establishes there.
  defp person!(label) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|files-#{label}-#{n}",
        provider: "github",
        email: "files-#{label}-#{n}@example.com",
        verified: true
      })

    athanor = Sanctum.Test.People.athanor!(user)

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "passkey",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
    %{user: user, athanor: athanor, ctx: ctx}
  end

  # ---------------------------------------------------------------------------
  # The declaration
  # ---------------------------------------------------------------------------

  describe "the declaration" do
    test "is one canvas-readable stream on the athanor's files topic, refreshed" do
      assert [stream] = Provider.streams()
      assert Prima.Provider.Stream.valid?(stream)
      assert stream.name == @stream
      assert stream.topic == :files
      assert stream.projection == ~w(kind id name type changed_at from revision at)

      # A removal reaches a canvas as a fresh picture: a folder takes every
      # file under it, and the next newest file takes a removed one's place.
      assert {stream.key, stream.removal, stream.reread, stream.stale_after} ==
               {"id", "removed", ["removed"], 900}

      assert stream.subject == nil
      assert stream.bind == nil
      assert stream.filter == nil
      assert stream.deadline_bound == 86_400
      assert Cyfr.Bus.grantable?(stream.topic, false)

      assert {:ok, stream.shape} == Shape.validate(stream.shape)
      assert Enum.sort(Map.keys(stream.shape["fields"])) == Enum.sort(stream.projection)
      assert Enum.sort(stream.shape["required"]) == Enum.sort(stream.projection)

      assert stream.shape["fields"]["kind"]["values"] ==
               Enum.map(FileListed.kinds(), &Atom.to_string/1)

      assert :ok = Shape.check(stream.shape, Shape.fixture(stream.shape))

      assert {Provider, :listed} = stream.refresh
      assert {:ok, {Provider, ^stream}} = Sanctum.Catalog.lookup_stream(@stream)
      assert Provider.tools() == []
      assert Provider in Sanctum.Catalog.configured_providers()
    end

    test "the canvas catalog lists it with its shape", %{ctx: ctx} do
      {:ok, %{streams: streams}} = Compendium.Canvas.catalog(ctx)
      [listed] = Enum.filter(streams, &(&1.name == @stream))
      [stream] = Provider.streams()
      assert listed.shape == stream.shape
      assert listed.refresh == true
    end

    test "the gate opens it on the caller's own athanor and takes no subject", %{ctx: ctx} do
      assert {:ok, grant} = Sanctum.Gate.open_stream(ctx, @stream)
      assert grant.subject == nil
      assert Bus.granted_topic(Context.actor(ctx), grant) == Bus.files(Context.actor(ctx))
      assert {:error, %Prima.Refusal{}} = Sanctum.Gate.open_stream(ctx, @stream, "usr_x")
    end
  end

  # ---------------------------------------------------------------------------
  # The refresh
  # ---------------------------------------------------------------------------

  describe "the refresh" do
    test "is empty for a person with no files and no offers", %{ctx: ctx} do
      assert {:ok, []} = Provider.listed(ctx, nil)
    end

    test "lists the files under data/, newest first, by path, name, type and last change", %{
      ctx: ctx,
      actor: actor
    } do
      write!(actor, "data/trip.md")
      write!(actor, "data/receipts/oct.pdf")
      write!(actor, "data/cover.png")
      write!(actor, "data/gone.txt")
      {:ok, _} = Arca.Files.delete(actor, "data/gone.txt")
      t = ~U[2026-11-09 10:00:00.000000Z]
      settled_at!(actor, "data/trip.md", t)
      settled_at!(actor, "data/receipts/oct.pdf", DateTime.add(t, 60))
      settled_at!(actor, "data/cover.png", DateTime.add(t, 120))

      assert refreshed(ctx) == [
               file("data/cover.png", "cover.png", "image/png", DateTime.add(t, 120)),
               file("data/receipts/oct.pdf", "oct.pdf", "application/pdf", DateTime.add(t, 60)),
               file("data/trip.md", "trip.md", "text/markdown", t)
             ]
    end

    test "lists at most twenty files, the newest", %{ctx: ctx, actor: actor} do
      t = ~U[2026-11-09 10:00:00.000000Z]

      for n <- 1..22 do
        write!(actor, "data/f#{n}.txt")
        settled_at!(actor, "data/f#{n}.txt", DateTime.add(t, n))
      end

      ids = ctx |> refreshed() |> Enum.map(& &1["id"])
      assert length(ids) == 20
      assert hd(ids) == "data/f22.txt"
      refute "data/f1.txt" in ids
      refute "data/f2.txt" in ids
    end

    test "lists an offer to the person once, by its first file and its sender's name, while it waits",
         %{ctx: ctx, other_ctx: other_ctx} do
      offer = offer!(other_ctx, ctx.user_id, ["zeta.csv", "alpha.csv"])
      offer!(other_ctx, ctx.user_id, ["declined.csv"], status: "declined")

      offer!(other_ctx, ctx.user_id, ["late.csv"],
        expires_at: DateTime.add(DateTime.utc_now(), -60)
      )

      offer!(ctx, other_ctx.user_id, ["mine-to-them.csv"])

      assert [item] = refreshed(ctx)

      assert %{
               "kind" => "offer",
               "id" => ^offer,
               "name" => "alpha.csv",
               "type" => "text/csv",
               "from" => from
             } = item

      assert from == Sanctum.Tenancy.Users.public_name(other_ctx.user_id)
      refute from =~ "@example.com"
      refute inspect(item) =~ other_ctx.user_id
    end
  end

  # ---------------------------------------------------------------------------
  # Live
  # ---------------------------------------------------------------------------

  describe "live" do
    test "a written file is told as the refresh lists it, and its delete removes it", %{
      ctx: ctx,
      actor: actor
    } do
      write!(actor, "data/notes/plan.txt")
      assert_receive %FileListed{kind: :file} = told
      assert [read_as(told)] == refreshed(ctx)
      assert told.athanor_id == ctx.athanor_id
      refute inspect(told) =~ @private

      {:ok, _} = Arca.Files.delete(actor, "data/notes/plan.txt")
      assert_receive %FileListed{kind: :removed} = left
      assert removed?(left, "data/notes/plan.txt")
    end

    test "a folder deleted whole is removed by its path", %{actor: actor} do
      write!(actor, "data/old/a.txt")
      write!(actor, "data/old/b.txt")
      assert_receive %FileListed{kind: :file, id: "data/old/a.txt"}
      assert_receive %FileListed{kind: :file, id: "data/old/b.txt"}

      {:ok, _} = Arca.Files.delete(actor, "data/old")
      assert_receive %FileListed{kind: :removed} = left
      assert removed?(left, "data/old")
      refute_receive %FileListed{}, 200
    end

    test "data/ deleted whole is removed as data", %{actor: actor} do
      write!(actor, "data/a.txt")
      assert_receive %FileListed{kind: :file, id: "data/a.txt"}

      :ok = Arca.delete_tree(actor, ["data"])
      assert_receive %FileListed{kind: :removed} = left
      assert removed?(left, "data")
    end

    test "a write outside data/ tells nothing", %{actor: actor} do
      :ok = Arca.put(actor, ["threads", "thr_files", "m.json"], "{}")
      refute_receive %FileListed{}, 200
    end

    test "an offer enters its recipient's own files once per file and leaves on each end", %{
      ctx: ctx,
      other_ctx: other_ctx
    } do
      offer = offer!(other_ctx, ctx.user_id, ["b.csv", "a.csv"])
      other = Context.actor(other_ctx)
      :ok = Bus.subscribe(other, Bus.files(other))

      for filename <- ["b.csv", "a.csv"], do: offered(:offered, offer, other_ctx, ctx, filename)

      assert_receive %FileListed{kind: :offer, athanor_id: athanor} = first
      assert_receive %FileListed{kind: :offer} = second
      assert athanor == ctx.athanor_id
      assert read_as(first) == read_as(second)
      assert [read_as(first)] == refreshed(ctx)

      for kind <- [:landed, :failed], do: offered(kind, offer, other_ctx, ctx, "a.csv")
      refute_receive %FileListed{}, 200

      for kind <- [:accepted, :declined, :withdrawn, :expired] do
        offered(kind, offer, other_ctx, ctx, "a.csv")
        assert_receive %FileListed{kind: :removed, athanor_id: athanor} = left
        assert athanor == ctx.athanor_id
        assert removed?(left, offer)
      end

      # The sender's own files hear nothing of the offer.
      sender = other_ctx.athanor_id
      refute_received %FileListed{athanor_id: ^sender}
    end

    test "another athanor hears none of the person's files", %{
      actor: actor,
      other_ctx: other_ctx
    } do
      other = Context.actor(other_ctx)
      :ok = Bus.unsubscribe(actor, Bus.files(actor))
      :ok = Bus.subscribe(other, Bus.files(other))

      write!(actor, "data/mine.txt")
      refute_receive %FileListed{}, 200
    end
  end

  # ---------------------------------------------------------------------------

  defp write!(actor, path) do
    {:ok, _} = Arca.Files.write(actor, path, "contents #{@private}")
  end

  defp settled_at!(actor, path, at) do
    {1, _} =
      from(r in Arca.Schemas.ObjectRevision,
        where: r.athanor_id == ^actor.athanor_id and r.path == ^path
      )
      |> Arca.Repo.update_all(set: [settled_at: at])
  end

  defp file(id, name, type, at),
    do: %{
      "kind" => "file",
      "id" => id,
      "name" => name,
      "type" => type,
      "changed_at" => DateTime.to_iso8601(at),
      "from" => nil
    }

  defp refreshed(ctx) do
    {:ok, items} = Provider.listed(ctx, nil)
    Enum.map(items, &read_as/1)
  end

  # A refresh item or a live payload as a canvas reads it: projected by the
  # grant, passed through JSON, and held to the declared shape, its
  # delivery fields (its revision, its time in microseconds) checked and
  # set aside.
  defp read_as(payload) do
    {:ok, {Provider, stream}} = Sanctum.Catalog.lookup_stream(@stream)

    grant = %Prima.StreamGrant{
      topic: stream.topic,
      projection: stream.projection,
      subject: nil,
      deadline: DateTime.utc_now(),
      grant_id: "sgr_files"
    }

    data = grant |> Prima.StreamGrant.project(payload) |> Jason.encode!() |> Jason.decode!()
    assert :ok = Shape.check(stream.shape, data), inspect(data)
    assert Enum.sort(Map.keys(data)) == Enum.sort(stream.projection)
    {:ok, at, 0} = DateTime.from_iso8601(data["at"])
    assert data["revision"] == DateTime.to_unix(at, :microsecond)
    Map.drop(data, ~w(revision at))
  end

  defp removed?(payload, id) do
    read_as(payload) == %{
      "kind" => "removed",
      "id" => id,
      "name" => nil,
      "type" => nil,
      "changed_at" => nil,
      "from" => nil
    }
  end

  # An offer of `files` from `from_ctx`'s person to `recipient`, its rows in
  # the sender's athanor as `Arca.FileOffers.offer/3` writes them: answers
  # the offer's id.
  defp offer!(from_ctx, recipient, files, opts \\ []) do
    offer_id = Prima.UUID7.generate_id("ofr")
    now = DateTime.utc_now()

    for filename <- files do
      Arca.Repo.insert!(%Arca.Schemas.FileOffer{
        id: Prima.UUID7.generate_id("fof"),
        athanor_id: from_ctx.athanor_id,
        offer_id: offer_id,
        sender_user_id: from_ctx.user_id,
        recipient_user_id: recipient,
        filename: filename,
        digest: "sha256:" <> String.duplicate("0", 64),
        size: 1,
        status: Keyword.get(opts, :status, "offered"),
        expires_at: Keyword.get(opts, :expires_at, DateTime.add(now, 3_600)),
        inserted_at: now,
        updated_at: now
      })
    end

    offer_id
  end

  # An offer's transition as `Arca.FileOffers` emits it, per file.
  defp offered(kind, offer_id, from_ctx, to_ctx, filename) do
    :telemetry.execute([:cyfr, :arca, :file_offer, kind], %{system_time: 0}, %{
      offer_id: offer_id,
      kind: kind,
      sender_user_id: from_ctx.user_id,
      recipient_user_id: to_ctx.user_id,
      filename: filename
    })
  end
end
