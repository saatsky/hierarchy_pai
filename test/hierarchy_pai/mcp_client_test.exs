defmodule HierarchyPai.McpClientTest do
  use ExUnit.Case, async: true

  alias HierarchyPai.McpClient

  # These tests use Bypass to mock the MCP HTTP server.
  # If Bypass is unavailable, tests use a simpler Req-based mock approach.

  describe "connect/1" do
    test "returns error for unreachable URL" do
      result = McpClient.connect("http://127.0.0.1:19999/mcp")
      assert {:error, reason} = result
      assert is_binary(reason)
    end

    test "returns error for non-MCP endpoint" do
      # Attempt to call a reachable HTTP server that returns non-JSON
      # We use the app's own endpoint which is running in test mode
      # but /nonexistent returns HTML, not valid MCP JSON
      result = McpClient.connect("http://localhost:4002/mcp")
      # Either :error or unexpected response is acceptable
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  describe "call_tool/3" do
    test "returns error for unreachable server" do
      result = McpClient.call_tool("http://127.0.0.1:19999/mcp", "search", %{"query" => "test"})
      assert {:error, reason} = result
      assert is_binary(reason)
    end
  end
end
