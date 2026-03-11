defmodule HierarchyPai.Agents.ErrorHelper do
  @moduledoc """
  Shared helper for mapping raw LLM/API error messages to human-readable strings.

  Used by Planner, Executor, and Aggregator agents so rate-limit responses and
  other common API errors are surfaced clearly in both the UI and MCP tool results.
  """

  @doc """
  Maps known API/LLM error patterns to actionable messages.
  Accepts any term; non-binary values are converted via `inspect/1` first.
  """
  @spec friendly_error(any()) :: String.t()
  def friendly_error(msg) when is_binary(msg) do
    cond do
      String.contains?(msg, "Too many requests") or String.contains?(msg, "429") ->
        "Rate limited by provider (HTTP 429). Reduce concurrent steps or switch to a higher-tier model."

      String.contains?(msg, "tokens_limit_reached") or String.contains?(msg, "too large") ->
        "Request too large for model. Context was truncated but still exceeded the limit."

      String.contains?(msg, "context_length_exceeded") ->
        "Request exceeds the model's context window. Shorten the task description or reduce step count."

      String.contains?(msg, "unauthorized") or String.contains?(msg, "401") ->
        "Provider authentication failed (HTTP 401). Check your API key configuration."

      String.contains?(msg, "timeout") or String.contains?(msg, "Timeout") ->
        "LLM request timed out. The model may be overloaded — try again or switch providers."

      true ->
        msg
    end
  end

  def friendly_error(other), do: inspect(other)
end
