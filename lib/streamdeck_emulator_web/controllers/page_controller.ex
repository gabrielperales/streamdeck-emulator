defmodule StreamdeckEmulatorWeb.PageController do
  use StreamdeckEmulatorWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
