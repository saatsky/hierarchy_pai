defmodule HierarchyPai.McpClient do
  @moduledoc """
  HTTP MCP client for calling external MCP servers.

  Uses the Streamable HTTP transport (JSON-RPC 2.0 via POST requests).
  Each `connect/1` or `call_tool/3` call opens a fresh session via the
  MCP `initialize` handshake, then performs the requested operation.

  Only HTTP/HTTPS endpoints are supported. stdio-based servers are not.

  ## Usage

      # Fetch available tools (stores them in McpServerStore)
      {:ok, tools} = HierarchyPai.McpClient.connect("http://localhost:9000/mcp")

      # Call a tool directly
      {:ok, result} = HierarchyPai.McpClient.call_tool(
        "http://localhost:9000/mcp",
        "brave_search",
        %{"query" => "elixir phoenix"}
      )

  """

  require Logger

  @protocol_version "2024-11-05"
  @client_info %{"name" => "HierarchyPai", "version" => "1.0"}
  @req_timeout 30_000

  @doc """
  Connects to the MCP server at `url`, performs the initialize handshake,
  and retrieves the server's tool list.

  Returns `{:ok, tools}` where `tools` is a list of MCP tool definition maps,
  each with at minimum `"name"`, `"description"`, and `"inputSchema"` keys.
  Returns `{:error, reason}` on any failure.
  """
  @spec connect(String.t()) :: {:ok, list()} | {:error, String.t()}
  def connect(url) do
    with {:ok, session_id} <- initialize(url) do
      list_tools(url, session_id)
    end
  end

  @doc """
  Calls the named tool on the MCP server at `url` with `args`.

  Opens a fresh session, invokes `tools/call`, and returns the concatenated
  text content from the response.

  Returns `{:ok, result_text}` or `{:error, reason}`.
  """
  @spec call_tool(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def call_tool(url, tool_name, args) do
    with {:ok, session_id} <- initialize(url) do
      do_call_tool(url, session_id, tool_name, args)
    end
  end

  ## Private

  defp initialize(url) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => @client_info
      }
    }

    case post(url, body, nil) do
      {:ok, %Req.Response{status: 200, headers: headers, body: resp_body}} ->
        session_id = extract_session_id(headers)

        case resp_body do
          %{"result" => _} ->
            send_initialized(url, session_id)
            {:ok, session_id}

          %{"error" => err} ->
            msg = err["message"] || inspect(err)
            {:error, "MCP initialize error: #{msg}"}

          _ ->
            {:error, "Unexpected MCP initialize response: #{inspect(resp_body)}"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status} from MCP server during initialize"}

      {:error, reason} ->
        {:error, "Connection to MCP server failed: #{format_reason(reason)}"}
    end
  end

  defp send_initialized(url, session_id) do
    notify = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    post(url, notify, session_id)
    :ok
  end

  defp list_tools(url, session_id) do
    body = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}

    case post(url, body, session_id) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        case resp_body do
          %{"result" => %{"tools" => tools}} when is_list(tools) ->
            {:ok, tools}

          %{"result" => result} ->
            {:ok, Map.get(result, "tools", [])}

          %{"error" => err} ->
            msg = err["message"] || inspect(err)
            {:error, "tools/list error: #{msg}"}

          _ ->
            {:ok, []}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status} from MCP server during tools/list"}

      {:error, reason} ->
        {:error, "tools/list request failed: #{format_reason(reason)}"}
    end
  end

  defp do_call_tool(url, session_id, tool_name, args) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => args
      }
    }

    case post(url, body, session_id) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        case resp_body do
          %{"result" => %{"content" => content}} when is_list(content) ->
            text =
              content
              |> Enum.filter(&(&1["type"] == "text"))
              |> Enum.map_join("\n", & &1["text"])

            {:ok, text}

          %{"result" => result} ->
            {:ok, inspect(result)}

          %{"error" => err} ->
            msg = err["message"] || inspect(err)
            {:error, "#{tool_name} error: #{msg}"}

          _ ->
            {:error, "Unexpected tools/call response: #{inspect(resp_body)}"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status} from MCP server calling #{tool_name}"}

      {:error, reason} ->
        {:error, "tools/call request failed: #{format_reason(reason)}"}
    end
  end

  # Sends a POST JSON-RPC request to `url`.
  # Attaches the `mcp-session-id` header when `session_id` is non-nil.
  defp post(url, body, session_id) do
    extra_headers =
      if session_id do
        [{"mcp-session-id", session_id}]
      else
        []
      end

    headers =
      [{"content-type", "application/json"}, {"accept", "application/json"}] ++ extra_headers

    Req.post(url, json: body, headers: headers, receive_timeout: @req_timeout)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Extracts the `mcp-session-id` from a Req response headers list.
  # Returns nil when the header is absent (stateless servers).
  defp extract_session_id(headers) when is_list(headers) do
    Enum.find_value(headers, nil, fn
      {"mcp-session-id", id} -> id
      _ -> nil
    end)
  end

  defp extract_session_id(_), do: nil

  defp format_reason(%{__struct__: Req.TransportError, reason: reason}),
    do: transport_reason_message(reason)

  defp format_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_reason(reason) when is_atom(reason), do: transport_reason_message(reason)
  defp format_reason(reason), do: inspect(reason)

  defp transport_reason_message(:econnrefused), do: "connection refused (is the server running?)"
  defp transport_reason_message(:nxdomain), do: "hostname not found"
  defp transport_reason_message(:econnreset), do: "connection reset by peer"
  defp transport_reason_message(:timeout), do: "connection timed out"
  defp transport_reason_message(:closed), do: "connection closed unexpectedly"
  defp transport_reason_message(reason), do: inspect(reason)
end
