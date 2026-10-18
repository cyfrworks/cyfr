# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.AttachmentBytesLogTest do
  @moduledoc """
  A file attached to a message reaches the request log as its size and
  digest, never its bytes, whether the gate admits the call or refuses it
  at admission (`thread.attach`, whose `files[].data` the operation
  declares as bulk content).
  """

  use ExUnit.Case, async: false

  setup do
    Cyfr.Test.Sandbox.setup!()
    ctx = Sanctum.TestContext.local(:prism)
    {:ok, thread} = Arca.ThreadStorage.create(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, thread: thread}
  end

  defp measured(bytes),
    do: %{
      "size" => byte_size(bytes),
      "digest" => "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    }

  defp logged_input(call_id) do
    %{input: input} = Arca.Repo.get(Arca.Schemas.McpLog, call_id)
    input
  end

  describe "a file attached to a message" do
    test "reaches the request log as its size and digest, never its bytes", %{
      ctx: ctx,
      thread: thread
    } do
      data = Base.encode64(:crypto.strong_rand_bytes(3_000))
      call_id = Prima.UUID7.generate_id("call")

      assert {:ok, %{attachments: [_ref]}} =
               Sanctum.Gate.call_external(
                 "thread",
                 ctx,
                 %{
                   "action" => "attach",
                   "thread" => thread.id,
                   "message_id" => Prima.UUID7.generate_id("msg"),
                   "files" => [
                     %{"filename" => "n.bin", "media_type" => "text/plain", "data" => data}
                   ]
                 },
                 call_id: call_id
               )

      stored = logged_input(call_id)
      refute stored =~ binary_part(data, 0, 64)

      assert %{"files" => [%{"filename" => "n.bin", "data" => logged}]} = Jason.decode!(stored)
      assert logged == measured(data)
    end

    test "a call refused at admission is logged without the bytes too", %{
      ctx: ctx,
      thread: thread
    } do
      data = Base.encode64(:crypto.strong_rand_bytes(3_000))
      call_id = Prima.UUID7.generate_id("call")

      assert {:error, %Prima.Refusal{stage: :admission}} =
               Sanctum.Gate.call_external(
                 "thread",
                 ctx,
                 %{
                   "action" => "attach",
                   "thread" => thread.id,
                   "message_id" => Prima.UUID7.generate_id("msg"),
                   "files" => %{"filename" => "n.bin", "data" => data}
                 },
                 call_id: call_id
               )

      refute logged_input(call_id) =~ binary_part(data, 0, 64)
    end
  end
end
