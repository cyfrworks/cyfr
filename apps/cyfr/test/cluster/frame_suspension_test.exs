# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.FrameSuspensionTest do
  @moduledoc """
  A frame suspended on one member, observed by the other at its
  credential's next use.

  The shell suspends a hidden frame's credential on the member that
  serves the person's page (`Sanctum.TinctureAuth.suspend_frame/2`); the
  frame's next request may reach another member of the cell, which
  establishes it from the bearer (`Sanctum.Caller.establish/2`'s
  `:frame_credential` door, the one every data route goes through). That
  member holds no memo of the frame: the row is the standing, read at
  every use, so the suspension is refused there whether or not anything
  was announced, and a resumption opens the frame there again.
  """

  use Cyfr.Cluster.Case, async: false

  alias Cyfr.Cluster.Fixtures

  @digest "sha256:" <> String.duplicate("b", 64)
  @reference %{publisher: "local", name: "suspension-probe", version: "1.0.0"}

  # A frame the person's page opened on member `:a`: its bearer and row.
  defp frame!(person) do
    {:ok, ctx} = Cell.call(:a, Fixtures, :context, [person.token])
    frame_id = "frame-#{System.unique_integer([:positive])}"

    {:ok, %{credential: bearer, id: id}} =
      Cell.call(:a, Sanctum.TinctureAuth, :mint_frame_credential, [
        ctx,
        @reference,
        @digest,
        0,
        frame_id
      ])

    %{ctx: ctx, bearer: bearer, id: id, frame_id: frame_id}
  end

  # The frame's next request, on member `id`: established as a data route
  # establishes it.
  defp use_on(id, bearer) do
    case Cell.call(id, Sanctum.Caller, :establish, [
           {:frame_credential, bearer},
           [client_ip: "127.0.0.1"]
         ]) do
      {:ok, ctx} -> {:ok, ctx.frame.frame_id}
      {:error, reason} -> {:error, reason}
    end
  end

  describe "a frame suspended on one member" do
    test "is refused at its credential's next use on the other, and opens there once resumed" do
      person = Cell.call(:a, Fixtures, :person!, [])
      frame = frame!(person)

      # Before: the other member admits the frame's request.
      assert {:ok, frame.frame_id} == use_on(:b, frame.bearer)

      assert {:ok, _suspended} =
               Cell.call(:a, Sanctum.TinctureAuth, :suspend_frame, [frame.ctx, frame.id])

      assert {:error, :suspended} = use_on(:b, frame.bearer)
      assert {:error, :suspended} = use_on(:a, frame.bearer)

      assert {:ok, _resumed} =
               Cell.call(:a, Sanctum.TinctureAuth, :resume_frame, [frame.ctx, frame.id])

      assert {:ok, frame.frame_id} == use_on(:b, frame.bearer)
    end

    test "is refused on the other with the control channel cut, since nothing announced is read" do
      person = Cell.call(:a, Fixtures, :person!, [])
      frame = frame!(person)
      assert {:ok, frame.frame_id} == use_on(:b, frame.bearer)

      Cell.partition(:a, :b)
      assert Cell.call(:b, Node, :list, []) == []

      assert {:ok, _suspended} =
               Cell.call(:a, Sanctum.TinctureAuth, :suspend_frame, [frame.ctx, frame.id])

      assert {:error, :suspended} = use_on(:b, frame.bearer),
             "the other member admitted a suspended frame it was never told about"

      Cell.heal(:a, :b)
    end
  end
end
