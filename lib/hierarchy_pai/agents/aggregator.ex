defmodule HierarchyPai.Agents.Aggregator do
  @moduledoc """
  The Aggregator agent synthesizes all step outputs into a final polished answer,
  streaming tokens to PubSub as they arrive. Returns `{:ok, answer}` or `{:error, reason}`.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  @system_prompt """
  You are an Aggregator Agent.
  Your job is to synthesize the outputs of multiple reasoning steps into one
  final, well-structured response to the original task.

  Guidelines:
  - Be clear, practical, and comprehensive.
  - Use markdown: headers (##), bullet points, numbered lists as appropriate.
  - If the task asks for an action plan, include clear next steps.
  - Do not repeat step labels — integrate the content naturally.
  """

  @spec aggregate(String.t(), list(), map(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def aggregate(goal, step_results, provider_config, pubsub_topic) do
    model = HierarchyPai.LLMProvider.build(Map.put(provider_config, :stream, true))

    callback_handler = %{
      on_llm_new_delta: fn _chain, deltas ->
        Enum.each(deltas, fn delta ->
          token = extract_token(delta)

          if token && token != "" do
            Phoenix.PubSub.broadcast(
              HierarchyPai.PubSub,
              pubsub_topic,
              {:orchestrator, {:final_token, token}}
            )
          end
        end)
      end
    }

    results_text =
      Enum.map_join(step_results, "\n\n", fn r ->
        "### Step #{r["step_id"]}: #{r["title"]}\n#{r["output"]}"
      end)

    user_message = """
    # Original Goal
    #{goal}

    # Step-by-Step Outputs
    #{results_text}

    Please synthesize the above into a comprehensive, well-structured final response to the original goal.
    """

    chain =
      LLMChain.new!(%{
        llm: model,
        verbose: false,
        max_retry_count: Map.get(provider_config, :max_retries, 0)
      })
      |> LLMChain.add_callback(callback_handler)
      |> LLMChain.add_messages([
        Message.new_system!(@system_prompt),
        Message.new_user!(user_message)
      ])

    case safe_run(chain) do
      {:ok, updated_chain} ->
        {:ok, extract_content(updated_chain.last_message.content)}

      {:error, reason} ->
        {:error, "Aggregator LLM error: #{reason}"}
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

  defp extract_token(%{content: content}) when is_binary(content), do: content
  defp extract_token(_), do: nil
end
