defmodule HierarchyPaiWeb.Plugs.SuppressMcpPolling do
  @moduledoc """
  Suppresses Phoenix request logging for MCP SSE keepalive GET requests.

  MCP clients maintain a persistent SSE connection via repeated GET /mcp requests.
  These are normal protocol behaviour but flood the console. POST requests (tool calls)
  are still logged at the normal level.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{method: "GET"} = conn, _opts) do
    put_private(conn, :phoenix_log_level, false)
  end

  def call(conn, _opts), do: conn
end
