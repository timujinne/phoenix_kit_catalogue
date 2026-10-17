defmodule PhoenixKitCatalogue.Test.QueryHook do
  @moduledoc """
  Test helpers that watch the repo queries of the calling process.

  `after_query/3` runs a function once, right after the first query that matches a
  pattern, so a test can change the world in the window between two steps of one call
  (an item trashed after it was planned, a category re-homed before the move).
  `queries/1` records the SQL of every query a function runs.
  """

  import ExUnit.Assertions

  @event [:phoenix_kit_catalogue, :test, :repo, :query]

  @doc """
  Runs `body`; the first time one of its queries matches `pattern` (a string or regex),
  `hook` runs in the same process, right after that query. Fails the test when the hook
  never ran (or raised). Returns what `body` returns.
  """
  @spec after_query(String.t() | Regex.t(), (-> any()), (-> result)) :: result when result: var
  def after_query(pattern, hook, body) do
    test_pid = self()
    handler = "query-hook-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      @event,
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and String.match?(metadata.query, to_regex(pattern)) do
          :telemetry.detach(handler)
          hook.()
          send(test_pid, {:query_hook_ran, handler})
        end
      end,
      nil
    )

    try do
      result = body.()
      assert_received {:query_hook_ran, ^handler}
      result
    after
      :telemetry.detach(handler)
    end
  end

  @doc "`{result, [sql]}`: every statement `body` ran in this process, in order."
  @spec queries((-> result)) :: {result, [String.t()]} when result: var
  def queries(body) do
    test_pid = self()
    handler = "query-record-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      @event,
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:recorded_query, handler, metadata.query})
      end,
      nil
    )

    try do
      result = body.()
      {result, drain(handler, [])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, acc) do
    receive do
      {:recorded_query, ^handler, query} -> drain(handler, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp to_regex(%Regex{} = regex), do: regex
  defp to_regex(string), do: Regex.compile!(Regex.escape(string))
end
