# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CompanyLoginLive do
  @moduledoc """
  `/company-login`: the one page open to a person whose session this
  CYFR refuses for the company sign-in it requires and nothing else
  (`Sanctum.CompanyLogin.held/1`). Every protected page sends them here
  (`CyfrWeb.ContextGuard`).

  It offers two things: signing in with their company, a POST to
  `/auth/company` under the browser pipeline's CSRF token, and signing
  out. It holds no context: a session that stands goes to `/`, and one
  refused for anything else to the sign-in page. An `error` the callback
  sent back (`sentence/1`) is shown above the button.

  Its controls carry `data-test` names: `company-login`,
  `company-login-start`, `company-login-error` and `company-login-sign-out`.
  """

  use PrismWeb, :live_view

  @errors %{
    "refused" => "The company sign-in did not finish, so nothing changed. Start it again.",
    "wrong_organization" =>
      "That account belongs to another organization than the one this CYFR requires.",
    "unavailable" => "Your company's sign-in could not be reached just now. Try again shortly."
  }

  @doc """
  The sentence the page shows for an `error` the callback names: one of
  `refused`, `wrong_organization`, `unavailable` and `subject_bound`.
  """
  @spec sentence(String.t()) :: String.t()
  def sentence("subject_bound"), do: Prima.Refusal.message(:company_subject_bound)
  def sentence(error), do: Map.get(@errors, error, @errors["refused"])

  @impl true
  def mount(params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Sign in with your company")
      |> assign(:error, error(params))

    case Sanctum.CompanyLogin.held(session[to_string(CyfrWeb.ContextGuard.session_key())]) do
      {:ok, _owner} ->
        {:ok, socket, layout: false}

      {:error, :standing} ->
        {:ok, redirect(socket, to: ~p"/"), layout: false}

      {:error, reason} when reason in [:unavailable, :identity_stale] ->
        {:ok, assign(socket, :error, @errors["unavailable"]), layout: false}

      {:error, _refused} ->
        {:ok, redirect(socket, to: ~p"/login"), layout: false}
    end
  end

  defp error(%{"error" => error}) when is_binary(error), do: sentence(error)
  defp error(_params), do: nil

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :required, Prima.Refusal.message(:company_login_required))

    ~H"""
    <.flash_group flash={@flash} />
    <div class="min-h-screen flex items-center justify-center bg-gray-950 px-4 py-8">
      <div class="max-w-md w-full space-y-6">
        <div class="text-center space-y-3">
          <img
            src={~p"/images/logo.jpg"}
            alt="AQUA"
            class="h-14 w-14 rounded-full mx-auto ring-2 ring-indigo-400/30"
          />
          <h1 class="text-2xl font-bold tracking-tight text-indigo-200">
            Sign in with your company
          </h1>
        </div>

        <div data-test="company-login" class="bg-gray-900 rounded-lg shadow-xl p-6 space-y-4">
          <div
            :if={@error}
            role="alert"
            data-test="company-login-error"
            class="rounded-lg bg-red-900/50 border border-red-800 px-4 py-3 text-sm text-red-300"
          >
            {@error}
          </div>

          <p class="text-sm text-gray-300 leading-relaxed">{@required}</p>
          <p class="text-sm text-gray-400 leading-relaxed">
            You are still signed in to this CYFR. Your company's account does not sign you in
            here: it confirms you belong, and until it does, nothing else here opens.
          </p>

          <.link
            href={~p"/auth/company"}
            method="post"
            data-test="company-login-start"
            class="block w-full text-center px-4 py-3 bg-indigo-700 hover:bg-indigo-600 text-white rounded-lg transition-colors"
          >
            Sign in with your company
          </.link>

          <.link
            href={~p"/auth/logout"}
            method="post"
            data-test="company-login-sign-out"
            class="block w-full text-center px-4 py-3 text-sm text-gray-300 hover:text-white border border-gray-700 rounded-lg"
          >
            Sign out
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
