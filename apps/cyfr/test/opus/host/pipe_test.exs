# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host.PipeTest do
  @moduledoc """
  A read's answer is budgeted on what crosses the wire: the answer as
  `Opus.Host` writes it, sealed as the host listener seals it, within
  `Prima.HostAPI.max_answer_bytes/0`; a read replayed by its `after`
  carries the same lines.
  """

  use ExUnit.Case, async: true

  alias Prima.{HostAPI, WorkerAuth, WorkerWire}

  @call %{
    athanor_id: "ath_01a09fee-045b-770b-b745-a62792bb8798",
    execution_id: "exec_01a09fee-07cc-791f-a598-e7f90608c9e2",
    attempt: "att_01a09fee-0a31-7a2b-8f0c-3d1e5b7c9a42",
    fence: 2,
    generation: 7,
    service: "wrk_4f3c2a1e9d8b7c6a",
    boot: "boot_01a09fee-2e4f-7a5b-9c6d-7e8f9a0b1c2d",
    runner: "run_01a09fee-1c2d-7e3f-8a4b-5c6d7e8f9a0b",
    member: "cyfr@10.0.0.1#boot_01a09fee-5d7e-7f80-91a2-b3c4d5e6f708",
    ts: 1_789_305_251_930,
    nonce: "n_pipe_fit"
  }

  # The bytes that cross for `answer`: written as `Opus.Host` writes it and
  # sealed as the host listener seals it.
  defp crossing(answer) do
    {:ok, sealed} =
      WorkerAuth.seal_call(:crypto.strong_rand_bytes(32), :answer, @call, encoded(answer))

    sealed
  end

  defp encoded(answer), do: Jason.encode!(WorkerWire.ok(answer))

  test "four 1 MiB lines: the answer carries what fits sealed, and a replay the same lines" do
    text = String.duplicate("a", 1_048_576)
    lines = for seq <- 1..4, do: %{seq: seq, text: text}
    read = %{lines: lines, dropped: 0, running: true}

    assert {:ok, %{lines: kept} = answer} = Opus.Host.Pipe.fit(read)
    assert kept != [] and length(kept) < 4
    assert kept == Enum.take(lines, length(kept))
    assert byte_size(crossing(answer)) <= HostAPI.max_answer_bytes()

    # What the budget counts is what crosses.
    assert WorkerAuth.sealed_bytes(byte_size(encoded(answer))) == byte_size(crossing(answer))

    # The lines left are read next; the same read again carries the same.
    assert answer.running
    assert {:ok, ^answer} = Opus.Host.Pipe.fit(read)
  end

  test "a line no sealed answer can carry is refused, never held forever" do
    text = String.duplicate("\u0001", 1_048_576)

    assert {:error, {:guest_error, "too_large", _}} =
             Opus.Host.Pipe.fit(%{lines: [%{seq: 1, text: text}], dropped: 0, running: true})
  end
end
