defmodule HierarchyPai.McpServerStoreTest do
  use ExUnit.Case, async: false

  alias HierarchyPai.McpServerStore

  # The stores are started by the application supervision tree, so we use them
  # directly. Each test cleans up the entries it creates.

  describe "save/get/list/delete" do
    test "saves and retrieves an entry" do
      {:ok, saved} = McpServerStore.save(%{name: "Test Server", url: "http://test/mcp"})

      assert saved.id != nil
      assert saved.name == "Test Server"
      assert saved.url == "http://test/mcp"
      assert saved.status == :disconnected
      assert saved.tools == []
      assert saved.tool_count == 0

      found = McpServerStore.get(saved.id)
      assert found.id == saved.id
      assert found.name == "Test Server"
    end

    test "list returns all entries sorted by name" do
      {:ok, b} = McpServerStore.save(%{name: "Beta", url: "http://beta/mcp"})
      {:ok, a} = McpServerStore.save(%{name: "Alpha", url: "http://alpha/mcp"})

      names = McpServerStore.list() |> Enum.map(& &1.name)
      alpha_idx = Enum.find_index(names, &(&1 == "Alpha"))
      beta_idx = Enum.find_index(names, &(&1 == "Beta"))
      assert alpha_idx < beta_idx

      # cleanup
      McpServerStore.delete(a.id)
      McpServerStore.delete(b.id)
    end

    test "delete removes the entry" do
      {:ok, saved} = McpServerStore.save(%{name: "To Delete", url: "http://delete/mcp"})
      assert McpServerStore.get(saved.id) != nil
      :ok = McpServerStore.delete(saved.id)
      assert McpServerStore.get(saved.id) == nil
    end

    test "get returns nil for unknown id" do
      assert McpServerStore.get("nonexistent") == nil
    end

    test "save updates an existing entry when id is provided" do
      {:ok, original} = McpServerStore.save(%{name: "Original", url: "http://old/mcp"})

      {:ok, updated} =
        McpServerStore.save(%{id: original.id, name: "Updated", url: "http://new/mcp"})

      assert updated.id == original.id
      assert updated.name == "Updated"
      assert updated.url == "http://new/mcp"

      McpServerStore.delete(original.id)
    end
  end

  describe "update_status/4" do
    test "updates status, tools and error" do
      {:ok, saved} = McpServerStore.save(%{name: "Status Test", url: "http://status/mcp"})

      tools = [%{"name" => "tool1", "description" => "desc"}]
      :ok = McpServerStore.update_status(saved.id, :connected, tools, nil)

      entry = McpServerStore.get(saved.id)
      assert entry.status == :connected
      assert entry.tools == tools
      assert entry.tool_count == 1
      assert entry.error == nil

      :ok = McpServerStore.update_status(saved.id, :error, [], "Connection refused")
      entry = McpServerStore.get(saved.id)
      assert entry.status == :error
      assert entry.error == "Connection refused"
      assert entry.tool_count == 0

      McpServerStore.delete(saved.id)
    end

    test "update_status on unknown id is a no-op" do
      assert :ok = McpServerStore.update_status("ghost", :connected, [], nil)
    end
  end
end
