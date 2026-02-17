defmodule PrismWeb.ErrorHTML do
  @moduledoc """
  Error pages for Prism.
  """

  use PrismWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
