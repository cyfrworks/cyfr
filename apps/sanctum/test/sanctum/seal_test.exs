# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SealTest do
  @moduledoc """
  The personal seal: read for the system layer by the person's own
  interactive client alone, and by nothing else whatever is stored; chosen
  once, at first use, from the fixed words and glyphs; kept apart from the
  person's row, so no read of the person carries it; and inspected without
  its words.
  """

  # The rate limiter's table is the node's, and a pairing in these tests
  # spends from it.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Prima.DeviceCert.{Challenge, Proof}
  alias Sanctum.{Context, DeviceCerts, Pairing, Seal}
  alias Sanctum.Tenancy.{Athanors, Users}

  @source "198.51.100.40"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)

    seated!()
  end

  # A person seated in a group of their own, and the context their browser
  # session establishes there, admitted on the console's interactive path.
  defp seated! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|seal-#{n}",
        provider: "github",
        email: "seal#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "Seal #{n}")

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)

    {:ok, session_ctx} =
      Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)

    %{user: user, athanor: athanor, ctx: %{session_ctx | origin: :interactive}}
  end

  # A device paired through the ceremony, and the context its channel
  # mints from a connect proof.
  defp device!(ctx) do
    {device_key, private} = :crypto.generate_key(:eddsa, :ed25519)

    digest = Prima.Device.key_digest(device_key)

    {:ok, invitation} =
      ctx
      |> Sanctum.TestContext.confirmed(:device_pairing, Pairing.invitation_change(digest))
      |> Pairing.begin(%{key_digest: digest})

    glass = Context.build(%{authenticated: false, client_ip: @source})
    submission = %{device_key: device_key}

    {:ok, %{challenge: challenge}} =
      Pairing.complete(glass, invitation.invitation_secret, submission)

    {:ok, %{client_id: client_id, certificate: certificate}} =
      Pairing.complete(
        glass,
        invitation.invitation_secret,
        Map.put(submission, :proof, Proof.sign(challenge, private))
      )

    {:ok, connect} =
      Challenge.new(
        purpose: :connect,
        home: certificate.audience,
        athanor: certificate.athanor,
        client_id: client_id,
        device_key: certificate.device_key,
        nonce: :crypto.strong_rand_bytes(Challenge.nonce_bytes()),
        now: System.system_time(:millisecond)
      )

    {:ok, device_ctx} =
      DeviceCerts.verify_connect(
        %{client_id: client_id, certificate: certificate, source: @source},
        Proof.sign(connect, private),
        connect
      )

    %{ctx: device_ctx, client_id: client_id}
  end

  defp chosen!(ctx, attrs \\ %{text: "amber heron", glyph: "★"}) do
    {:ok, seal} = Seal.choose(ctx, attrs)
    seal
  end

  defp stored(user_id) do
    Arca.Repo.one(
      from(s in "person_seals",
        where: s.user_id == ^user_id,
        select: %{text: s.text, glyph: s.glyph}
      )
    )
  end

  describe "for_system_layer/1" do
    test "reads none until the person chooses, never a default", %{ctx: ctx} do
      assert Seal.for_system_layer(ctx) == :none
    end

    test "answers the person's own browser session its seal once chosen", %{ctx: ctx} do
      seal = chosen!(ctx)

      assert {:ok, %Seal{text: "amber heron", glyph: "★", set_at: %DateTime{}}} =
               Seal.for_system_layer(ctx)

      assert {:ok, ^seal} = Seal.for_system_layer(ctx)
    end

    test "answers the person's paired device while its client stands", %{ctx: ctx} do
      chosen!(ctx)
      %{ctx: device_ctx, client_id: client_id} = device!(ctx)

      assert {device_ctx.auth_method, device_ctx.origin} == {:device, :interactive}
      assert {:ok, %Seal{text: "amber heron"}} = Seal.for_system_layer(device_ctx)

      {:ok, _revoked} =
        ctx
        |> Sanctum.TestContext.confirmed(:pairing_revocation, %{
          operation: "pairing.revoke",
          arguments: %{"client_id" => client_id},
          resource: client_id
        })
        |> Pairing.revoke(client_id)

      assert Seal.for_system_layer(device_ctx) == :none
    end

    test "refuses every context but the person's own interactive client, whatever is stored",
         %{ctx: ctx} do
      chosen!(ctx)

      refused = %{
        "a frame" => %{
          ctx
          | auth_method: :tincture,
            session_token_hash: nil,
            frame: %{
              id: "fcr_seal",
              frame_id: "frame-1",
              reference: %{publisher: "acme", name: "notes", version: "1.0.0"},
              version_digest: "sha256:" <> String.duplicate("0", 64),
              grant_revision: 1,
              mode: :live
            }
        },
        "a frame on the console's path" => %{
          ctx
          | frame: %{
              id: "fcr_seal",
              frame_id: "frame-1",
              reference: %{publisher: "acme", name: "notes", version: "1.0.0"},
              version_digest: "sha256:" <> String.duplicate("0", 64),
              grant_revision: 1,
              mode: :live
            }
        },
        "a key" => %{
          ctx
          | auth_method: :api_key,
            api_key_id: "key_seal",
            session_token_hash: nil,
            origin: :programmatic
        },
        "a key on the interactive path" => %{
          ctx
          | auth_method: :api_key,
            api_key_id: "key_seal",
            session_token_hash: nil
        },
        "a webhook" => %{ctx | auth_method: :webhook, session_token_hash: nil, origin: :webhook},
        "a schedule" => %{
          ctx
          | auth_method: :scheduled,
            session_token_hash: nil,
            origin: :schedule
        },
        "the command line" => %{ctx | origin: :programmatic},
        "a session admitted on no path" => %{ctx | origin: nil},
        "a session naming a paired client" => %{ctx | client_id: "pcl_seal"},
        "a session holding no session" => %{ctx | session_token_hash: nil},
        "a device naming no client that stands" => %{
          ctx
          | auth_method: :device,
            client_id: "pcl_seal",
            session_token_hash: nil
        },
        "the guest plane" => Context.enter_guest(ctx),
        "the system" => Context.internal(athanor_id: ctx.athanor_id),
        "an anonymous caller" => %{ctx | anonymous: true},
        "an unauthenticated caller" => %{ctx | authenticated: false}
      }

      for {name, refused_ctx} <- refused do
        assert Seal.for_system_layer(refused_ctx) == :none, "#{name} read the seal"

        assert Seal.choose(refused_ctx, %{text: "oak"}) == {:error, :refused},
               "#{name} chose a seal"
      end

      assert %{text: "amber heron"} = stored(ctx.user_id)
    end

    test "never reads another person's seal", %{ctx: ctx} do
      %{ctx: other} = seated!()
      chosen!(other, %{text: "oak"})

      assert Seal.for_system_layer(ctx) == :none
      assert {:error, :cross_tenant} = Arca.PersonSeals.get(Context.actor(ctx), other.user_id)

      assert {:error, :cross_tenant} =
               Arca.PersonSeals.get(Prima.Actor.system(), other.user_id)
    end
  end

  describe "choose/2" do
    test "sets the first seal once; a second choice is refused and changes nothing", %{ctx: ctx} do
      chosen!(ctx, %{text: "willow", glyph: ""})

      assert {:ok, %Seal{text: "willow", glyph: nil}} = Seal.for_system_layer(ctx)
      assert Seal.choose(ctx, %{text: "oak", glyph: "☾"}) == {:error, :already_set}
      assert stored(ctx.user_id) == %{text: "willow", glyph: nil}
    end

    test "of two first choices made at once, exactly one is written", %{ctx: ctx} do
      choices = [%{text: "oak"}, %{text: "pine"}]

      answers =
        choices
        |> Enum.map(fn attrs -> Task.async(fn -> Seal.choose(ctx, attrs) end) end)
        |> Task.await_many(15_000)

      assert Enum.count(answers, &match?({:ok, %Seal{}}, &1)) == 1
      assert Enum.count(answers, &(&1 == {:error, :already_set})) == 1

      [{:ok, %Seal{text: text}}] = Enum.filter(answers, &match?({:ok, _seal}, &1))
      assert stored(ctx.user_id) == %{text: text, glyph: nil}
    end

    test "takes one listed word or two different ones and one listed glyph, nothing else",
         %{ctx: ctx} do
      for attrs <- [
            %{text: "correct horse"},
            %{text: "my own words"},
            %{text: "amber amber"},
            %{text: "amber  heron"},
            %{text: "Amber"},
            %{text: "amber heron wren"},
            %{text: ""},
            %{text: nil},
            %{glyph: "★"},
            %{text: "amber", glyph: "x"},
            %{text: "amber", glyph: "★★"},
            %{text: "amber", glyph: 1}
          ] do
        assert Seal.choose(ctx, attrs) == {:error, :invalid_seal}, inspect(attrs)
      end

      assert stored(ctx.user_id) == nil
    end

    test "a drawn pair is two different listed words, and a seal", %{ctx: ctx} do
      for _draw <- 1..50 do
        [first, second] = String.split(Seal.generate(), " ")
        assert first != second
        assert first in Seal.words() and second in Seal.words()
      end

      text = Seal.generate()
      assert {:ok, %Seal{text: ^text}} = Seal.choose(ctx, %{text: text, glyph: hd(Seal.glyphs())})
    end
  end

  describe "change/2" do
    # The person's seal-change confirmations, by state.
    defp records(user_id) do
      Arca.Repo.all(
        from(c in "pending_confirmations",
          where: c.user_id == ^user_id and c.operation == "seal.change",
          select: %{operation: c.operation, state: c.state}
        )
      )
    end

    test "without a fresh seal_change proof, asks one and changes nothing", %{ctx: ctx} do
      chosen!(ctx, %{text: "oak"})

      assert {:error, {:confirmation_required, %{id: id, operation: "seal.change"}}} =
               Seal.change(ctx, %{text: "pine", glyph: "☘"})

      assert is_binary(id)
      assert stored(ctx.user_id) == %{text: "oak", glyph: nil}
      assert [%{operation: "seal.change", state: "pending"}] = records(ctx.user_id)

      # A secret that names a record never proven waits on it, and still
      # changes nothing.
      assert {:error, {:confirmation_required, %{id: ^id}}} =
               Seal.change(%{ctx | confirmation_id: id}, %{text: "pine", glyph: "☘"})

      assert stored(ctx.user_id) == %{text: "oak", glyph: nil}
    end

    test "under a proof of that exact change, replaces the seal once", %{ctx: ctx} do
      chosen!(ctx, %{text: "oak"})
      new = %{text: "pine", glyph: "☘"}

      assert {:ok, %Seal{text: "pine", glyph: "☘"}} =
               Sanctum.TestContext.confirming(ctx, &Seal.change(&1, new))

      assert {:ok, %Seal{text: "pine", glyph: "☘"}} = Seal.for_system_layer(ctx)
      assert [%{state: "consumed"}] = records(ctx.user_id)
    end

    test "a proof is spent once, and binds the seal it was asked for", %{ctx: ctx} do
      chosen!(ctx, %{text: "oak"})

      proven =
        Sanctum.TestContext.confirmed(ctx, :seal_change, %{
          operation: "seal.change",
          arguments: %{"text" => "pine", "glyph" => nil}
        })

      # Another seal under that proof asks again and changes nothing.
      assert {:error, {:confirmation_required, _ask}} = Seal.change(proven, %{text: "wren"})
      assert stored(ctx.user_id) == %{text: "oak", glyph: nil}

      assert {:ok, %Seal{text: "pine"}} = Seal.change(proven, %{text: "pine"})

      # The same proof a second time: spent, so it is asked again.
      assert {:error, {:confirmation_required, _ask}} = Seal.change(proven, %{text: "pine"})
      assert stored(ctx.user_id) == %{text: "pine", glyph: nil}
    end

    test "the record it opens carries nothing of the seal", %{ctx: ctx} do
      chosen!(ctx, %{text: "oak"})

      {:error, {:confirmation_required, %{id: id}}} =
        Seal.change(ctx, %{text: "saffron kestrel", glyph: "⚓"})

      {:ok, row} =
        Arca.PendingConfirmations.get(Context.actor(ctx), Prima.Confirmation.ref(id))

      refute inspect(row, limit: :infinity) =~ "saffron"
      refute inspect(row, limit: :infinity) =~ "⚓"
    end

    test "a person with no seal is not_set, and no confirmation opens", %{ctx: ctx} do
      assert Seal.change(ctx, %{text: "pine"}) == {:error, :not_set}
      assert records(ctx.user_id) == []
    end

    test "is refused from every context but the person's own interactive client, opening nothing",
         %{ctx: ctx} do
      chosen!(ctx, %{text: "oak"})

      for refused <- [
            %{ctx | origin: :programmatic},
            %{ctx | auth_method: :api_key, api_key_id: "key_seal", session_token_hash: nil},
            %{ctx | anonymous: true},
            Context.enter_guest(ctx)
          ] do
        assert Seal.change(refused, %{text: "pine"}) == {:error, :refused}
      end

      assert Seal.change(ctx, %{text: "my own words"}) == {:error, :invalid_seal}
      assert records(ctx.user_id) == []
      assert stored(ctx.user_id) == %{text: "oak", glyph: nil}
    end
  end

  describe "under a depleted storage reserve" do
    # The latch is the node's: put back as it was, the restore registered
    # before the change.
    defp depleted! do
      before = Arca.StorageReserve.state()
      on_exit(fn -> Arca.StorageReserve.put(before) end)
      :ok = Arca.StorageReserve.put(:depleted)
    end

    defp reserve_refused?(answer),
      do: match?({:error, %Prima.Refusal{reason: {:unavailable, :storage_reserve}}}, answer)

    test "a first choice is refused, writes nothing, and is made once the reserve clears",
         %{ctx: ctx} do
      depleted!()

      assert reserve_refused?(Seal.choose(ctx, %{text: "oak"}))
      assert stored(ctx.user_id) == nil

      :ok = Arca.StorageReserve.put(:ok)
      assert {:ok, %Seal{text: "oak"}} = Seal.choose(ctx, %{text: "oak"})
    end

    test "a change is refused before its confirmation opens, and asks once the reserve clears",
         %{ctx: ctx} do
      chosen!(ctx, %{text: "oak"})
      depleted!()

      assert reserve_refused?(Seal.change(ctx, %{text: "pine"}))
      assert records(ctx.user_id) == []
      assert stored(ctx.user_id) == %{text: "oak", glyph: nil}

      :ok = Arca.StorageReserve.put(:ok)
      assert {:error, {:confirmation_required, _ask}} = Seal.change(ctx, %{text: "pine"})
    end

    test "a proven change is refused without spending its proof, which replaces the seal once the reserve clears",
         %{ctx: ctx} do
      chosen!(ctx, %{text: "oak"})

      proven =
        Sanctum.TestContext.confirmed(ctx, :seal_change, %{
          operation: "seal.change",
          arguments: %{"text" => "pine", "glyph" => nil}
        })

      depleted!()

      assert reserve_refused?(Seal.change(proven, %{text: "pine"}))
      assert stored(ctx.user_id) == %{text: "oak", glyph: nil}
      refute Enum.any?(records(ctx.user_id), &(&1.state == "consumed"))

      :ok = Arca.StorageReserve.put(:ok)
      assert {:ok, %Seal{text: "pine"}} = Seal.change(proven, %{text: "pine"})
      assert [%{state: "consumed"}] = records(ctx.user_id)
    end
  end

  describe "where the seal never appears" do
    test "no read of the person carries it, and a seal inspects without its words",
         %{ctx: ctx, user: user} do
      seal = chosen!(ctx, %{text: "saffron kestrel", glyph: "⚓"})

      {:ok, person} = Users.get(user.id)
      {:ok, row} = Arca.Users.get(Prima.Actor.system(), user.id)

      for read <- [person, row] do
        refute inspect(read, limit: :infinity) =~ "saffron"
        refute Enum.any?(Map.values(read), &(&1 == "saffron kestrel"))
      end

      refute inspect(seal) =~ "saffron"
      refute inspect(seal) =~ "⚓"
      refute inspect(Arca.Repo.get!(Arca.Schemas.PersonSeal, user.id)) =~ "saffron"
    end
  end
end
