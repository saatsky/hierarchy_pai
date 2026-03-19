defmodule HierarchyPaiWeb.PlannerLiveMcpTest do
  use HierarchyPaiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HierarchyPai.McpServerStore
  alias HierarchyPai.PlanStore
  alias HierarchyPai.RunStore

  @sample_plan %{
    "goal" => "Implement a feature",
    "assumptions" => [],
    "steps" => [
      %{
        "id" => 1,
        "title" => "Research",
        "instruction" => "Research the topic",
        "tool" => "llm",
        "agent_type" => "trend_researcher",
        "expected_output" => "Research notes",
        "depends_on" => []
      },
      %{
        "id" => 2,
        "title" => "Implement",
        "instruction" => "Write the code",
        "tool" => "llm",
        "agent_type" => "backend_architect",
        "expected_output" => "Code snippet",
        "depends_on" => [1]
      }
    ]
  }

  describe "MCP server CRUD" do
    test "can add and view an MCP server", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view |> element("button[phx-click=open_mcp_server_form]") |> render_click()

      assert has_element?(view, "form#mcp-server-form")

      view
      |> form("#mcp-server-form", %{
        mcp_server: %{name: "Test Server", url: "http://localhost:9000/mcp"}
      })
      |> render_submit()

      assert has_element?(view, "#mcp-servers-panel", "Test Server")
    end

    test "can delete a saved MCP server", %{conn: conn} do
      {:ok, srv} = McpServerStore.save(%{name: "Delete Me", url: "http://del/mcp"})
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#mcp-servers-panel", "Delete Me")

      view
      |> element("button[phx-click=delete_mcp_server][phx-value-id='#{srv.id}']")
      |> render_click()

      refute has_element?(view, "#mcp-servers-panel", "Delete Me")

      # cleanup in case test framework didn't
      McpServerStore.delete(srv.id)
    end
  end

  describe "Plan save / load / delete" do
    test "save plan modal appears when plan exists in review state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Simulate plan loaded via replay_plan event
      run_id = "test_replay_#{System.unique_integer([:positive])}"

      RunStore.put(%{
        id: run_id,
        task: "test task",
        status: :done,
        plan: @sample_plan,
        steps: [],
        answer: "done",
        error: nil
      })

      view
      |> element("button[phx-click=replay_plan][phx-value-run_id='#{run_id}']")
      |> render_click()

      # Should now be in review_plan status — plan review shows
      assert has_element?(view, "#save-plan-modal") == false

      view |> element("button[phx-click=open_save_plan_modal]") |> render_click()

      assert has_element?(view, "#save-plan-modal")
    end

    test "save plan stores it in PlanStore and shows flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      run_id = "test_save_#{System.unique_integer([:positive])}"

      RunStore.put(%{
        id: run_id,
        task: "My research task",
        status: :done,
        plan: @sample_plan,
        steps: [],
        answer: "ans",
        error: nil
      })

      view
      |> element("button[phx-click=replay_plan][phx-value-run_id='#{run_id}']")
      |> render_click()

      view |> element("button[phx-click=open_save_plan_modal]") |> render_click()

      view
      |> element("#save-plan-modal input[type=text]")
      |> render_keyup(%{"value" => "My Saved Plan", "key" => "Enter"})

      view |> element("#save-plan-modal button[phx-click=save_plan]") |> render_click()

      assert has_element?(view, "#saved-plans-panel", "My Saved Plan")
    end

    test "load_saved_plan loads plan into planner", %{conn: conn} do
      {:ok, entry} = PlanStore.save("Loaded Plan", "the task", @sample_plan)
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#saved-plans-panel", "Loaded Plan")

      view
      |> element("button[phx-click=load_saved_plan][phx-value-id='#{entry.id}']")
      |> render_click()

      # Should now show plan review
      assert has_element?(view, "h2", "Plan Review")

      PlanStore.delete(entry.id)
    end

    test "delete_saved_plan removes it from the UI", %{conn: conn} do
      {:ok, entry} = PlanStore.save("To Remove", "task", @sample_plan)
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#saved-plans-panel", "To Remove")

      view
      |> element("button[phx-click=delete_saved_plan][phx-value-id='#{entry.id}']")
      |> render_click()

      refute has_element?(view, "#saved-plans-panel", "To Remove")
    end
  end

  describe "Plan upload via plan_uploaded event" do
    test "valid plan JSON loads into planner", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "plan_uploaded", %{"plan" => @sample_plan})

      assert has_element?(view, "h2", "Plan Review")
      assert has_element?(view, "[id^=step-cfg-]")
    end

    test "invalid plan JSON shows flash error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "plan_uploaded", %{"plan" => %{"not_goal" => "broken"}})

      assert has_element?(view, "[role=alert]")
    end
  end

  describe "replay_plan from run history" do
    test "loads plan into planner and shows review screen", %{conn: conn} do
      run_id = "replay_#{System.unique_integer([:positive])}"

      RunStore.put(%{
        id: run_id,
        task: "Replay task",
        status: :done,
        plan: @sample_plan,
        steps: [],
        answer: "ans",
        error: nil
      })

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "button[phx-click=replay_plan][phx-value-run_id='#{run_id}']")

      view
      |> element("button[phx-click=replay_plan][phx-value-run_id='#{run_id}']")
      |> render_click()

      assert has_element?(view, "h2", "Plan Review")
      assert has_element?(view, "[id^=step-cfg-1]")
      assert has_element?(view, "[id^=step-cfg-2]")
    end

    test "run without plan shows error flash", %{conn: conn} do
      run_id = "no_plan_#{System.unique_integer([:positive])}"

      RunStore.put(%{
        id: run_id,
        task: "No plan task",
        status: :done,
        plan: nil,
        steps: [],
        answer: "ans",
        error: nil
      })

      {:ok, view, _html} = live(conn, "/")

      # The replay button only shows if plan != nil, so we push the event directly
      render_hook(view, "replay_plan", %{"run_id" => run_id})

      assert has_element?(view, "[role=alert]")
    end
  end

  describe "MCP server selector in step config" do
    test "connected MCP servers appear as checkboxes in step config", %{conn: conn} do
      {:ok, srv} =
        McpServerStore.save(%{name: "My MCP", url: "http://tools/mcp"})

      McpServerStore.update_status(srv.id, :connected, [%{"name" => "search"}], nil)

      {:ok, entry} = PlanStore.save("With MCP", "task", @sample_plan)
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button[phx-click=load_saved_plan][phx-value-id='#{entry.id}']")
      |> render_click()

      assert has_element?(view, "input[phx-click=toggle_step_mcp_server]")

      McpServerStore.delete(srv.id)
      PlanStore.delete(entry.id)
    end
  end
end
