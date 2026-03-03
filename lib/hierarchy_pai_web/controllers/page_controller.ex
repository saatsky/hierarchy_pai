defmodule HierarchyPaiWeb.PageController do
  use HierarchyPaiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
