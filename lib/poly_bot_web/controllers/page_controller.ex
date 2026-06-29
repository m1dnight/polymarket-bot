defmodule PolyBotWeb.PageController do
  use PolyBotWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
