# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AttachmentWriteRaceTest do
  @moduledoc """
  Two members attaching a file of the same name under one message at once:
  whichever lands first keeps its bytes, unsent or sent, and the other's
  write leaves them as they are, since the check and the write are one
  conditional create (`Aqua.Attachments.store/4`).
  """

  use ExUnit.Case, async: false
  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Members}

  defmodule ParkedPut do
    @moduledoc false
    # The Local adapter, with the write of one member's bytes held until
    # the test releases it, whichever write the store makes.
    use Arca.Storage.TestDouble

    def put(actor, path, content) do
      park(content)
      Arca.Adapters.Local.put(actor, path, content)
    end

    def put_if_none_match(actor, path, content) do
      park(content)
      Arca.Adapters.Local.put_if_none_match(actor, path, content)
    end

    defp park(content) do
      if IO.iodata_to_binary(content) == "parked attack bytes" do
        owner = :persistent_term.get({__MODULE__, :owner})
        send(owner, {:put_parked, self()})

        receive do
          :continue_put -> :ok
        after
          10_000 -> raise "parked upload was never released"
        end
      end
    end
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    previous =
      for key <- [:storage_adapter, :base_path], do: {key, Application.fetch_env(:arca, key)}

    base = Path.join(System.tmp_dir!(), "astra_w4d_attach_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:arca, key, old)
          :error -> Application.delete_env(:arca, key)
        end
      end

      :persistent_term.erase({ParkedPut, :owner})
      File.rm_rf!(base)
    end)

    Application.put_env(:arca, :storage_adapter, ParkedPut)
    Application.put_env(:arca, :base_path, base)
    :persistent_term.put({ParkedPut, :owner}, self())
    Cyfr.Test.Sandbox.stop_work_on_exit()
    n = System.unique_integer([:positive])

    [alice, bob] =
      for name <- ["alice", "bob"] do
        {:ok, user} =
          Sanctum.Test.People.linked(%{
            id: "github|https://github.com|#{name}-race-#{n}",
            provider: "github",
            email: "#{name}-race-#{n}@example.com",
            verified: true
          })

        user.id
      end

    {:ok, group} = Athanors.create_group(alice, "Attachment race #{n}")
    {:ok, _} = Members.ensure(bob, scope: "athanor", athanor_id: group.id)

    [a, b] =
      for user <- [alice, bob] do
        Context.build(
          user_id: user,
          athanor_id: group.id,
          provider: "github",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
        |> Sanctum.TestContext.via(:prism)
        |> Map.put(:session_token_hash, :crypto.hash(:sha256, user))
      end

    {:ok, thread} = Arca.ThreadStorage.create(Context.actor(a))
    {:ok, a: a, b: b, thread: thread}
  end

  for sent <- [false, true] do
    @sent sent
    test "a member racing another on the same file leaves the other's #{if sent, do: "sent", else: "unsent"} bytes as they are",
         fixture do
      %{a: a, b: b, thread: thread} = fixture
      message = Prima.UUID7.generate_id("msg")
      task = Task.async(fn -> attach(a, thread.id, message, "parked attack bytes") end)
      assert_receive {:put_parked, writer}, 5_000
      assert {:ok, %{attachments: [ref]}} = attach(b, thread.id, message, "victim bytes")
      {:ok, path} = Aqua.attachment_blob_path(thread.id, message, ref)
      assert {:ok, "victim bytes"} = Arca.get(Context.actor(b), path)

      if @sent do
        assert {:ok, %{accepted: true}} =
                 Sanctum.Gate.call_external("thread", b, %{
                   "action" => "send",
                   "thread" => thread.id,
                   "message" => "with a file",
                   "id" => message,
                   "attachments" => [ref],
                   "client_id" => "race-sent"
                 })

        assert {:ok, _} = Arca.ThreadStorage.get_message(Context.actor(b), message)
      end

      send(writer, :continue_put)
      result = Task.await(task, 5_000)

      assert {:ok, "victim bytes"} == Arca.get(Context.actor(b), path),
             "other member's bytes changed after the competing upload returned #{inspect(result)}"
    end
  end

  defp attach(ctx, thread, message, bytes) do
    Sanctum.Gate.call_external("thread", ctx, %{
      "action" => "attach",
      "thread" => thread,
      "message_id" => message,
      "files" => [
        %{"filename" => "note.txt", "media_type" => "text/plain", "data" => Base.encode64(bytes)}
      ]
    })
  end
end
