defmodule HierarchyPai.PlanStoreTest do
  use ExUnit.Case, async: false

  alias HierarchyPai.PlanStore

  @sample_plan %{
    "goal" => "Test the planner",
    "steps" => [
      %{
        "id" => 1,
        "title" => "Step 1",
        "instruction" => "Do A",
        "agent_type" => "executor",
        "expected_output" => "Output A",
        "depends_on" => []
      },
      %{
        "id" => 2,
        "title" => "Step 2",
        "instruction" => "Do B",
        "agent_type" => "executor",
        "expected_output" => "Output B",
        "depends_on" => [1]
      }
    ]
  }

  describe "save/get/list/delete" do
    test "saves a plan and retrieves it by id" do
      {:ok, entry} = PlanStore.save("My Plan", "test task", @sample_plan)

      assert entry.id != nil
      assert entry.name == "My Plan"
      assert entry.task == "test task"
      assert entry.plan == @sample_plan
      assert %DateTime{} = entry.saved_at

      found = PlanStore.get(entry.id)
      assert found.id == entry.id
      assert found.name == "My Plan"

      PlanStore.delete(entry.id)
    end

    test "list returns all entries sorted by most recent first" do
      {:ok, first} = PlanStore.save("First", "task 1", @sample_plan)
      # Small sleep to ensure different saved_at timestamps
      Process.sleep(2)
      {:ok, second} = PlanStore.save("Second", "task 2", @sample_plan)

      listed = PlanStore.list()
      ids = Enum.map(listed, & &1.id)

      assert Enum.find_index(ids, &(&1 == second.id)) <
               Enum.find_index(ids, &(&1 == first.id))

      PlanStore.delete(first.id)
      PlanStore.delete(second.id)
    end

    test "get returns nil for unknown id" do
      assert PlanStore.get("unknown") == nil
    end

    test "delete removes the plan" do
      {:ok, entry} = PlanStore.save("Delete Me", "task", @sample_plan)
      assert PlanStore.get(entry.id) != nil
      :ok = PlanStore.delete(entry.id)
      assert PlanStore.get(entry.id) == nil
    end
  end
end
