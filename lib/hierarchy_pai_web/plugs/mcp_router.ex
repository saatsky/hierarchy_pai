defmodule HierarchyPaiWeb.MCPRouter do
  @moduledoc """
  Custom MCP router that wraps the AshAi.Mcp.Router/Server with two fixes:

  1. **Flat-args normalisation** — ash_ai generates `inputSchema` with all action
     arguments nested under an `"input"` key (its internal convention).  MCP
     clients (VS Code Copilot, Jan.ai, Cursor) send arguments flat at the top
     level because the underlying LLM does not preserve the nesting.  Before
     forwarding a `tools/call` request to ash_ai we wrap the flat arguments map
     under `"input"` so ash_ai can find them.

  2. **Schema flattening** — `tools/list` responses expose the nested `"input"`
     wrapper to the client.  We rewrite each tool's `inputSchema` to remove
     that wrapper, giving clients a clean flat schema that matches what they
     actually send.  This is consistent with the MCP specification which
     requires a plain JSON-Schema object for `inputSchema`.

  All other methods (`initialize`, `notifications/`, resource methods, etc.)
  are forwarded to `AshAi.Mcp.Server.process_message/3` without modification.

  GET and DELETE requests are forwarded to the underlying ash_ai handlers
  directly.
  """

  use Plug.Router, copy_opts_to_assign: :router_opts

  alias AshAi.Mcp.Server

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  post "/" do
    session_id = get_session_id(conn)
    opts = build_opts(conn)

    msg = normalize_tool_call(conn.params)

    result = Server.process_message(msg, session_id, opts)

    case result do
      {:initialize_response, json, new_session_id} ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.put_resp_header("mcp-session-id", new_session_id)
        |> Plug.Conn.send_resp(200, json)

      {:json_response, json, _session_id} ->
        json = transform_tools_list(json, conn.params)

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(200, json)

      {:no_response, _json, _session_id} ->
        Plug.Conn.send_resp(conn, 202, "")

      _other ->
        Plug.Conn.send_resp(conn, 500, "Unexpected MCP server response")
    end
  end

  get "/" do
    session_id = get_session_id(conn)
    Server.handle_get(conn, session_id)
  end

  delete "/" do
    session_id = get_session_id(conn)
    Server.handle_delete(conn, session_id)
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  # --- private ---

  # Wraps flat tool arguments under "input" for ash_ai compatibility.
  # ash_ai extracts action inputs from arguments["input"]; MCP clients
  # send them flat (e.g. %{"task" => "..."}). We normalise here so ash_ai
  # receives %{"input" => %{"task" => "..."}} as it expects.
  defp normalize_tool_call(%{"method" => "tools/call", "params" => params} = msg)
       when is_map(params) do
    args = params["arguments"] || %{}

    if Map.has_key?(args, "input") do
      msg
    else
      put_in(msg, ["params", "arguments"], %{"input" => args})
    end
  end

  defp normalize_tool_call(msg), do: msg

  # Rewrites tools/list response to expose flat inputSchema.
  # ash_ai wraps all properties under an "input" key. We unwrap it so
  # clients see a standard flat JSON-Schema, matching what they actually send.
  defp transform_tools_list(json, %{"method" => "tools/list"}) do
    case Jason.decode(json) do
      {:ok, %{"result" => %{"tools" => tools}} = response} ->
        flattened = Enum.map(tools, &flatten_input_schema/1)
        response |> put_in(["result", "tools"], flattened) |> Jason.encode!()

      _ ->
        json
    end
  end

  defp transform_tools_list(json, _), do: json

  defp flatten_input_schema(
         %{
           "inputSchema" => %{
             "properties" => %{"input" => %{"properties" => inner_props} = input_obj}
           }
         } = tool
       ) do
    flat_schema = %{
      "type" => "object",
      "properties" => inner_props,
      "required" => input_obj["required"] || [],
      "additionalProperties" => false
    }

    Map.put(tool, "inputSchema", flat_schema)
  end

  defp flatten_input_schema(tool), do: tool

  defp build_opts(conn) do
    router_opts = conn.assigns.router_opts

    [
      actor: Ash.PlugHelpers.get_actor(conn),
      tenant: Ash.PlugHelpers.get_tenant(conn),
      context: Ash.PlugHelpers.get_context(conn) || %{}
    ]
    |> Keyword.merge(router_opts)
  end

  defp get_session_id(conn) do
    case Plug.Conn.get_req_header(conn, "mcp-session-id") do
      [id | _] -> id
      [] -> nil
    end
  end
end
