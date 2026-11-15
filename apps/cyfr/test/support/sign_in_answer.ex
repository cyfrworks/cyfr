# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.SignInAnswer do
  @moduledoc """
  The sign-in page's answer to the account pages' sign-in, awaited on the
  page's own events, never a clock.

  The page checks the answer off the event, in a task of its own
  (`PrismWeb.LoginLive`'s `start_async`), and a sign-in's check runs the
  fill's local half for a person whose athanor is not filled before it
  answers (`Sanctum.Provisioning.after_sign_in/1`), so on a loaded host
  it takes as long as that work does. `redirected!/2` waits for the check
  task's end, after which its result is already in the page's mailbox,
  then for the page's own end, which a redirect is. A page that acts on
  the result and stays fails, naming what it says.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import Phoenix.LiveViewTest, only: [render: 1, render_hook: 3]

  @doc """
  Hand `view`, the sign-in page, the account pages' `answer`, and answer
  the path the page redirects the browser to.
  """
  @spec redirected!(Phoenix.LiveViewTest.View.t(), String.t()) :: String.t()
  def redirected!(view, answer) when is_binary(answer) do
    ends = Process.monitor(view.pid)
    render_hook(view, "account_answer", %{"answer" => answer})

    for task <- checks(view.pid) do
      ref = Process.monitor(task)
      receive do: ({:DOWN, ^ref, :process, ^task, _reason} -> :ok)
    end

    # A call the page answers comes after the result in its mailbox: one
    # it answers means it acted on the result and stayed.
    try do
      :sys.get_state(view.pid)
    catch
      :exit, _gone -> :gone
    else
      _state -> flunk("the sign-in page acted on the answer and stayed:\n#{render(view)}")
    end

    receive do
      {:DOWN, ^ends, :process, _pid, {:shutdown, {:redirect, %{to: to}}}} ->
        to

      {:DOWN, ^ends, :process, _pid, reason} ->
        flunk("the sign-in page stopped without a redirect: #{inspect(reason)}")
    end
  end

  # The page's checks still running: its tasks under `Prism.TaskSupervisor`.
  defp checks(page) do
    for task <- Task.Supervisor.children(Prism.TaskSupervisor),
        {:dictionary, dictionary} <- [Process.info(task, :dictionary)],
        page in Keyword.get(dictionary, :"$callers", []),
        do: task
  end
end
