# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.RuntimeHTTP2Test do
  @moduledoc """
  The worker listener serves HTTP/1.1 alone: a connection that opens with
  the HTTP/2 prior-knowledge preface (h2c) is closed unanswered, never
  answered with an HTTP/2 SETTINGS frame, while an HTTP/1.1 request on the
  same listener is answered by `Locus.Runtime.WorkerListener`. The
  listener is the one `Locus.Runtime.Supervisor` runs, on the address the
  suite's credentials name.
  """

  # The listener is the application's own, and logs the refusal it
  # answers.
  use ExUnit.Case, async: false

  # The HTTP/2 connection preface a client with prior knowledge sends
  # (RFC 9113 §3.4), then an empty SETTINGS frame: length 0, type 4, no
  # flags, stream 0.
  @h2c_preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  @empty_settings <<0::24, 4, 0, 0::32>>

  # No worker route answers a GET: the listener refuses it itself.
  @not_a_route "GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n"

  defp connect({ip, port}) do
    {:ok, socket} = :gen_tcp.connect(ip, port, [:binary, active: false], 5_000)
    socket
  end

  # What the listener sends first to a connection that opens with the
  # HTTP/2 preface: its first bytes, or `:closed` when it closes the
  # connection having sent none. A listener that reads the preface alone
  # and closes leaves the SETTINGS frame unread, which resets the
  # connection.
  defp h2c_answer(address) do
    socket = connect(address)
    :ok = :gen_tcp.send(socket, @h2c_preface <> @empty_settings)

    answer =
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, bytes} -> bytes
        {:error, reason} when reason in [:closed, :econnreset] -> :closed
        {:error, :timeout} -> flunk("the listener neither answered the h2c preface nor closed")
      end

    :ok = :gen_tcp.close(socket)
    answer
  end

  defp settings_frame?(<<_length::24, 4, _flags, _stream::32, _rest::binary>>), do: true
  defp settings_frame?(_answer), do: false

  # The status line and body of the answer to `request`, read to the
  # connection's close.
  defp http1_answer(address, request) do
    socket = connect(address)
    :ok = :gen_tcp.send(socket, request)
    response = read_to_close(socket, "", System.monotonic_time(:millisecond) + 5_000)
    :ok = :gen_tcp.close(socket)
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    {head |> String.split("\r\n") |> hd(), body}
  end

  defp read_to_close(socket, acc, deadline) do
    case :gen_tcp.recv(socket, 0, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, bytes} -> read_to_close(socket, acc <> bytes, deadline)
      {:error, :closed} -> acc
      {:error, :timeout} -> flunk("the listener did not close after its answer: #{inspect(acc)}")
    end
  end

  @tag :capture_log
  test "the worker listener closes an h2c connection unanswered and serves HTTP/1.1" do
    assert {Locus.Runtime.WorkerListener, listener, _type, _modules} =
             Locus.Runtime.Supervisor
             |> Supervisor.which_children()
             |> List.keyfind(Locus.Runtime.WorkerListener, 0)

    {:ok, address} = ThousandIsland.listener_info(listener)

    # The listener is the worker listener and answers HTTP/1.1.
    assert {"HTTP/1.1 404 Not Found", body} = http1_answer(address, @not_a_route)
    assert Jason.decode!(body) == %{"v" => 1, "error" => "not_found"}

    answer = h2c_answer(address)

    refute settings_frame?(answer),
           "the worker listener answered the h2c preface with an HTTP/2 SETTINGS frame: " <>
             inspect(answer, limit: 64)

    assert answer == :closed
  end
end
