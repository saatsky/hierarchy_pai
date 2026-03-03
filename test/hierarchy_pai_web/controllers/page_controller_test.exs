defmodule HierarchyPaiWeb.PageControllerTest do
  use HierarchyPaiWeb.ConnCase

  test "GET /info", %{conn: conn} do
    conn = get(conn, ~p"/info")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end
end
