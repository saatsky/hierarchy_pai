defmodule HierarchyPai.Agents.Executor do
  @moduledoc """
  The Executor agent processes a single plan step, streaming tokens to PubSub
  as they arrive from the LLM. Returns `{:ok, output_string}` or `{:error, reason}`.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  alias HierarchyPai.Agents.AgentRegistry

  @spec execute(map(), list(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(step, completed_results, provider_config, pubsub_topic) do
    model = HierarchyPai.LLMProvider.build(Map.put(provider_config, :stream, true))

    step_id = step["id"]
    agent_type = step["agent_type"] || "executor"
    system_prompt = AgentRegistry.system_prompt(agent_type)

    callback_handler = %{
      on_llm_new_delta: fn _chain, deltas ->
        Enum.each(deltas, fn delta ->
          token = extract_token(delta)

          if token && token != "" do
            Phoenix.PubSub.broadcast(
              HierarchyPai.PubSub,
              pubsub_topic,
              {:orchestrator, {:step_token, step_id, token}}
            )
          end
        end)
      end
    }

    user_message = build_user_message(step, completed_results)

    chain =
      LLMChain.new!(%{
        llm: model,
        verbose: false,
        max_retry_count: Map.get(provider_config, :max_retries, 0)
      })
      |> LLMChain.add_callback(callback_handler)
      |> LLMChain.add_messages([
        Message.new_system!(system_prompt),
        Message.new_user!(user_message)
      ])

    case safe_run(chain) do
      {:ok, updated_chain} ->
        {:ok, extract_content(updated_chain.last_message.content)}

      {:error, reason} ->
        {:error, "Executor LLM error: #{reason}"}
    end
  end

  defp safe_run(chain) do
    case LLMChain.run(chain, mode: :while_needs_response) do
      {:ok, updated_chain} -> {:ok, updated_chain}
      {:ok, updated_chain, _} -> {:ok, updated_chain}
      {:error, _chain, %{message: msg}} -> {:error, msg}
      {:error, _chain, reason} -> {:error, inspect(reason)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp extract_content(content) when is_binary(content), do: content

  defp extract_content(parts) when is_list(parts) do
    parts
    |> Enum.filter(&match?(%{type: :text}, &1))
    |> Enum.map_join("", & &1.content)
  end

  defp extract_content(_), do: ""

  defp build_user_message(step, []) do
    """
    ## Step to Execute
    **Title:** #{step["title"]}
    **Instruction:** #{step["instruction"]}
    **Expected output:** #{step["expected_output"]}

    No previous steps have been completed yet. Please execute this step.
    """
  end

  defp build_user_message(step, completed_results) do
    context =
      Enum.map_join(completed_results, "\n\n", fn r ->
        "### Step #{r["step_id"]}: #{r["title"]}\n#{r["output"]}"
      end)

    """
    ## Step to Execute
    **Title:** #{step["title"]}
    **Instruction:** #{step["instruction"]}
    **Expected output:** #{step["expected_output"]}

    ## Context from Completed Steps
    #{context}

    Please execute the step above, referencing prior context where helpful.
    """
  end

  defp extract_token(%{content: content}) when is_binary(content), do: content
  defp extract_token(_), do: nil
end
